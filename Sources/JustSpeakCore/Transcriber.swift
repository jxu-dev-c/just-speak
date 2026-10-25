import CSherpaOnnx
import Darwin
import Foundation

public enum TranscriberError: Error, CustomStringConvertible {
  case missingModelFile(String)
  case createFailed

  public var description: String {
    switch self {
    case .missingModelFile(let p): return "model file not found: \(p) (run scripts/fetch-deps.sh)"
    case .createFailed: return "sherpa-onnx failed to create the Fun-ASR-Nano recognizer"
    }
  }
}

public struct DecodeOptions: Equatable, Sendable {
  public var hotwords: [String] = []
  public var language = ""
  public var itn = true

  public init(hotwords: [String] = [], language: String = "", itn: Bool = true) {
    self.hotwords = hotwords
    self.language = language
    self.itn = itn
  }

  /// sherpa-onnx splits hotwords on , ; and newlines, so strip those from each entry.
  var hotwordsCSV: String {
    hotwords
      .map { $0.components(separatedBy: CharacterSet(charactersIn: ",;，；\n\r\t")).joined(separator: " ") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: ",")
  }
}

/// Thin owner of a sherpa-onnx Fun-ASR-Nano offline recognizer. Not thread-safe; see `Transcriber`.
public final class FunASRNano {
  private let recognizer: OpaquePointer

  /// `provider` is an onnxruntime execution provider. CoreML measured ~10x slower than CPU for
  /// this model (and 5+ GB footprint), so the app always uses cpu; the CLI exposes it for experiments.
  public init(modelDir: URL, numThreads: Int, provider: String = "cpu") throws {
    let files = [
      "encoder_adaptor.int8.onnx", "llm.int8.onnx", "embedding.int8.onnx", "Qwen3-0.6B/tokenizer.json",
    ].map { modelDir.appendingPathComponent($0).path }
    for f in files where !FileManager.default.fileExists(atPath: f) {
      throw TranscriberError.missingModelFile(f)
    }

    // C strings must outlive SherpaOnnxCreateOfflineRecognizer; free them right after.
    var owned: [UnsafeMutablePointer<CChar>] = []
    defer { owned.forEach { free($0) } }
    func c(_ s: String) -> UnsafePointer<CChar> {
      let p = strdup(s)!
      owned.append(p)
      return UnsafePointer(p)
    }

    // Zeroed fields take sherpa-onnx defaults (16 kHz/80-dim features, greedy search, prompts).
    var cfg = SherpaOnnxOfflineRecognizerConfig()
    cfg.decoding_method = c("greedy_search")
    cfg.model_config.num_threads = Int32(numThreads)
    cfg.model_config.provider = c(provider)
    cfg.model_config.funasr_nano.encoder_adaptor = c(files[0])
    cfg.model_config.funasr_nano.llm = c(files[1])
    cfg.model_config.funasr_nano.embedding = c(files[2])
    cfg.model_config.funasr_nano.tokenizer = c(modelDir.appendingPathComponent("Qwen3-0.6B").path)
    cfg.model_config.funasr_nano.itn = 1

    guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { throw TranscriberError.createFailed }
    recognizer = r
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizer(recognizer)
  }

  /// Decode 16 kHz mono samples in [-1, 1]. Blocks for the duration of inference.
  public func transcribe(_ samples: [Float], sampleRate: Int = 16_000, options: DecodeOptions) -> String {
    guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
    defer { SherpaOnnxDestroyOfflineStream(stream) }

    // Per-stream options: hotwords/language/itn change without reloading the model.
    SherpaOnnxOfflineStreamSetOption(stream, "hotwords", options.hotwordsCSV)
    SherpaOnnxOfflineStreamSetOption(stream, "language", options.language)
    SherpaOnnxOfflineStreamSetOption(stream, "itn", options.itn ? "1" : "0")

    samples.withUnsafeBufferPointer {
      SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
    }
    SherpaOnnxDecodeOfflineStream(recognizer, stream)

    guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
    defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
    guard let text = result.pointee.text else { return "" }
    return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Owns the recognizer lifecycle: lazy load, serialized decoding, idle unload.
/// All model work runs on one serial queue, so a decode requested mid-load simply waits for it.
public final class Transcriber: @unchecked Sendable {
  public struct ModelSpec: Equatable, Sendable {
    public var dir: URL
    public var numThreads: Int
    public init(dir: URL, numThreads: Int) {
      self.dir = dir
      self.numThreads = numThreads
    }
  }

  private let queue = DispatchQueue(label: "just-speak.asr", qos: .userInitiated)
  // Everything below is only touched on `queue`.
  private var model: FunASRNano?
  private var loadedSpec: ModelSpec?
  private var spec: ModelSpec
  private var idleMinutes: Int
  private var unloadWork: DispatchWorkItem?

  public init(spec: ModelSpec, unloadAfterIdleMinutes: Int) {
    self.spec = spec
    self.idleMinutes = unloadAfterIdleMinutes
  }

  /// Apply new settings; a changed model spec drops the loaded model so the next use reloads it.
  public func update(spec: ModelSpec, unloadAfterIdleMinutes: Int) {
    queue.async {
      self.spec = spec
      self.idleMinutes = unloadAfterIdleMinutes
      if self.loadedSpec != spec { self.unloadLocked(reason: "config changed") }
    }
  }

  /// Start loading in the background (called on hotkey-down so loading overlaps speech).
  public func preload() {
    queue.async {
      guard (try? self.ensureLoadedLocked()) != nil else { return }
      // Arm the idle timer here too: a preload may never be followed by a decode
      // (dictation cancelled, or no speech detected), and the model must not stay resident.
      self.scheduleUnloadLocked()
    }
  }

  public func transcribe(_ samples: [Float], options: DecodeOptions) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        do {
          let model = try self.ensureLoadedLocked()
          let sw = Stopwatch()
          let text = model.transcribe(samples, options: options)
          Log.info("asr decode \(sw.ms)ms audio=\(samples.count / 16)ms chars=\(text.count)")
          self.scheduleUnloadLocked()
          cont.resume(returning: text)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  public func unload() {
    queue.async { self.unloadLocked(reason: "requested") }
  }

  private func ensureLoadedLocked() throws -> FunASRNano {
    unloadWork?.cancel()
    if let model, loadedSpec == spec { return model }
    unloadLocked(reason: "reload")
    let sw = Stopwatch()
    let m = try FunASRNano(modelDir: spec.dir, numThreads: spec.numThreads)
    malloc_zone_pressure_relief(nil, 0)  // drop transient load buffers
    Log.info("asr model loaded in \(sw.ms)ms threads=\(spec.numThreads)")
    model = m
    loadedSpec = spec
    return m
  }

  private func scheduleUnloadLocked() {
    unloadWork?.cancel()
    guard idleMinutes > 0 else { return }
    let work = DispatchWorkItem { [weak self] in self?.unloadLocked(reason: "idle") }
    unloadWork = work
    queue.asyncAfter(deadline: .now() + .seconds(idleMinutes * 60), execute: work)
  }

  private func unloadLocked(reason: String) {
    unloadWork?.cancel()
    guard model != nil else { return }
    model = nil
    loadedSpec = nil
    // Hand freed pages back to the OS so RSS actually drops.
    malloc_zone_pressure_relief(nil, 0)
    Log.info("asr model unloaded (\(reason))")
  }
}
