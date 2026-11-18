@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import JustSpeakCore

/// Captures the selected (or system default) input device as mono Float32 at the requested rate and streams it to a callback.
/// The engine runs only while recording, so the mic indicator is off and no audio thread is alive between dictations.
final class AudioRecorder: @unchecked Sendable {
  private var engine = AVAudioEngine()
  private var configObserver: NSObjectProtocol?
  private var needsRebuild = false
  var preferredDevice = ""
  private var boundDeviceID: AudioDeviceID?

  init() {
    observeConfigurationChanges()
  }

  static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

  static func requestPermission() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  /// `sampleRate`: 16 kHz for the local model, 24 kHz for OpenAI.
  func start(sampleRate: Int, preferredDevice: String? = nil, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
    if needsRebuild { rebuildEngine() }
    configureInputDevice(preferredDevice ?? self.preferredDevice)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
      throw NSError(domain: "just-speak", code: 1, userInfo: [NSLocalizedDescriptionKey: "no usable input device"])
    }
    let ratio = target.sampleRate / format.sampleRate
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
    boundDeviceID = nil
    needsRebuild = false
    observeConfigurationChanges()
  }

  private func configureInputDevice(_ preferred: String) {
    let available = Self.inputDevices()
    guard let match = AudioInputDevice.resolve(preferred: preferred, available: available) else {
      if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Log.info("audio: preferred input device '\(preferred)' unavailable; using system default")
      }
      if boundDeviceID != nil { rebuildEngine() }
      return
    }
    let targetID = AudioDeviceID(match.id)
    guard boundDeviceID != targetID else { return }
    if boundDeviceID != nil { rebuildEngine() }
    guard let unit = engine.inputNode.audioUnit else { return }
    var deviceID = targetID
    let status = AudioUnitSetProperty(
      unit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status == noErr {
      boundDeviceID = targetID
      Log.info("audio: bound input device '\(match.name)' (\(match.uid))")
    } else {
      Log.info("audio: failed to bind input device '\(match.name)' (status \(status)); using system default")
      rebuildEngine()
    }
  }

  static func inputDevices() -> [AudioInputDevice] {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids.compactMap { id -> AudioInputDevice? in
      guard hasInputChannels(id),
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, selector: kAudioObjectPropertyName)
      else { return nil }
      return AudioInputDevice(id: id, uid: uid, name: name)
    }
  }

  private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else {
      return false
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }

  private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
          let cf = value?.takeUnretainedValue()
    else { return nil }
    return cf as String
  }
}
