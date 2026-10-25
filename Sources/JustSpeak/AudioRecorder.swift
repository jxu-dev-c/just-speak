@preconcurrency import AVFoundation
import JustSpeakCore

/// Captures the default input device as 16 kHz mono Float32 and streams it to a callback. The engine
/// runs only while recording, so the mic indicator is off and no audio thread is alive between dictations.
final class AudioRecorder: @unchecked Sendable {
  static let sampleRate = 16_000.0

  private var engine = AVAudioEngine()
  private let target = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
  private var configObserver: NSObjectProtocol?
  private var needsRebuild = false

  init() {
    observeConfigurationChanges()
  }

  static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

  static func requestPermission() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
    if needsRebuild { rebuildEngine() }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
      throw NSError(domain: "just-speak", code: 1, userInfo: [NSLocalizedDescriptionKey: "no usable input device"])
    }
    let ratio = target.sampleRate / format.sampleRate
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
      // the input block is invoked synchronously within convert(), never concurrently
      nonisolated(unsafe) var fed = false
      var error: NSError?
      converter.convert(to: out, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
      onSamples(Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength))))
    }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }

  /// Default input device changed (headset plugged in, AirPods connected): rebuild the engine so
  /// the next recording uses the new device and format.
  private func observeConfigurationChanges() {
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.needsRebuild = true
      Log.info("audio configuration changed")
    }
  }

  private func rebuildEngine() {
    engine = AVAudioEngine()
    needsRebuild = false
    observeConfigurationChanges()
  }
}
