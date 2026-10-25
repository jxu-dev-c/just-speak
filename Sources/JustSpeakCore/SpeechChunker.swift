import CSherpaOnnx
import Foundation

/// Splits a growing recording into ASR-sized chunks at natural pauses, using Silero VAD.
///
/// Fun-ASR-Nano (as exported for sherpa-onnx) has a 512-token context shared by the prompt, the audio
/// (~17 tokens/s) and the output, so past ~20 s the transcript is truncated. A chunk is cut at the first
/// pause after `eagerCutSeconds` of speech, so dictation is transcribed piecewise while the user keeps
/// talking and only the speech since the last pause is left at release. Speech without such a pause is
/// cut at its latest pause (or forcibly) before it grows past `maxChunkSeconds`.
/// Leading/trailing silence is trimmed, and audio with no detected speech yields no chunk at all.
///
/// Not thread-safe: drive it from one queue.
public final class SpeechChunker {
  public struct Params: Sendable {
    /// A chunk is cut before it grows past this (leaves room for prompt, hotwords and output tokens).
    public var maxChunkSeconds = 18.0
    /// Pauses earlier than this into a chunk aren't used as cut points; a forced cut is preferred
    /// over a sliver of a chunk.
    public var minChunkSeconds = 6.0
    /// Once a chunk holds this much speech, it is cut at the next pause instead of waiting for
    /// `maxChunkSeconds`. Shorter pieces cost a little cross-sentence context, so not every pause cuts.
    public var eagerCutSeconds = 6.0
    /// Audio kept on each side of detected speech so word onsets/endings aren't clipped.
    public var padSeconds = 0.5
    public init() {}
  }

  public static let sampleRate = 16_000

  private let vad: OpaquePointer
  private let minChunk: Int
  private let maxChunk: Int
  private let pad: Int
  private let eagerCut: Int
  /// Silence after a segment (beyond the pad) before its pause counts as settled: the VAD reports new
  /// speech only after `min_speech_duration`, so speech starting inside the pad is detected by then.
  private let settle: Int

  private var fed = 0                       // absolute samples fed so far
  private var cut = 0                       // start of the region not yet handed out as a chunk
  private var segments: [Range<Int>] = []   // completed speech segments inside [cut, fed)

  public init(vadModel: URL, params: Params = Params()) throws {
    guard FileManager.default.fileExists(atPath: vadModel.path) else {
      throw TranscriberError.missingModelFile(vadModel.path)
    }
    minChunk = Int(params.minChunkSeconds * Double(Self.sampleRate))
    maxChunk = Int(params.maxChunkSeconds * Double(Self.sampleRate))
    pad = Int(params.padSeconds * Double(Self.sampleRate))
    eagerCut = Int(params.eagerCutSeconds * Double(Self.sampleRate))
    settle = pad + Int(0.25 * Double(Self.sampleRate))

    let modelPath = strdup(vadModel.path)!
    let provider = strdup("cpu")!
    defer {
      free(modelPath)
      free(provider)
    }
    var cfg = SherpaOnnxVadModelConfig()
    cfg.silero_vad.model = UnsafePointer(modelPath)
    cfg.silero_vad.threshold = 0.5
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.min_speech_duration = 0.2
    // Long unbroken speech gets split with a stricter threshold, which yields extra cut candidates.
    cfg.silero_vad.max_speech_duration = Float(params.maxChunkSeconds) * 0.8
    cfg.silero_vad.window_size = 512
    cfg.sample_rate = Int32(Self.sampleRate)
    cfg.num_threads = 1
    cfg.provider = UnsafePointer(provider)
    guard let v = SherpaOnnxCreateVoiceActivityDetector(&cfg, 60) else { throw TranscriberError.createFailed }
    vad = v
  }

  deinit {
    SherpaOnnxDestroyVoiceActivityDetector(vad)
  }

  /// Feed the next samples. Returns chunks (absolute sample ranges) that are now final.
  public func accept(_ samples: UnsafeBufferPointer<Float>) -> [Range<Int>] {
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples.baseAddress, Int32(samples.count))
    fed += samples.count
    drainSegments()
    var chunks: [Range<Int>] = []
    while fed - cut >= maxChunk {
      // Cut in the pause after the latest finished segment that keeps the chunk within bounds.
      let pause = segments.last { $0.upperBound + pad - cut <= maxChunk && $0.upperBound - cut >= minChunk }
      let at = pause.map { min($0.upperBound + pad, fed) } ?? (cut + maxChunk)
      if let c = closeChunk(at: at, speechContinues: pause == nil) { chunks.append(c) }
    }
    if let first = segments.first, let last = settledPause, last.upperBound - first.lowerBound >= eagerCut,
       let c = closeChunk(at: last.upperBound + pad, speechContinues: false) {
      chunks.append(c)
    }
    return chunks
  }

  /// The speech still pending, as soon as the VAD has closed its latest segment; nil while speaking or
  /// with nothing pending. Lets the caller decode the tail before release: see `isSameSpeech`.
  public func pendingTail() -> Range<Int>? {
    guard !isSpeaking, let first = segments.first, let last = segments.last else { return nil }
    return max(cut, first.lowerBound - pad)..<last.upperBound
  }

  /// Whether `finish`'s chunk holds the same speech as an earlier `pendingTail`, differing at most by
  /// trailing padding. Any later segment ends after the old one, so it would push `final` past the pad.
  public func isSameSpeech(_ tail: Range<Int>, as final: Range<Int>) -> Bool {
    final.lowerBound == tail.lowerBound && final.upperBound <= tail.upperBound + pad
  }

  /// The last finished segment, if the VAD has heard nothing since it for at least `settle` samples.
  private var settledPause: Range<Int>? {
    guard !isSpeaking, let last = segments.last, fed - last.upperBound >= settle else { return nil }
    return last
  }

  /// Call once recording stops (`total` = samples recorded). Returns the final chunk, if it has speech.
  public func finish(total: Int) -> Range<Int>? {
    SherpaOnnxVoiceActivityDetectorFlush(vad)
    drainSegments()
    return closeChunk(at: total, speechContinues: false)
  }

  /// Hand out [cut, end) trimmed to the speech inside it; nil (region dropped) if there is none.
  /// `speechContinues`: a forced cut through unfinished speech, so don't trim the end.
  private func closeChunk(at end: Int, speechContinues: Bool) -> Range<Int>? {
    let inside = segments.filter { $0.lowerBound < end }
    segments.removeAll { $0.upperBound <= end }
    // A segment straddling the cut continues into the next chunk.
    segments = segments.map { max($0.lowerBound, end)..<$0.upperBound }
    defer { cut = end }

    let speaking = speechContinues && isSpeaking
    guard let first = inside.first ?? (speaking ? cut..<end : nil) else { return nil }
    let lo = max(cut, first.lowerBound - pad)
    let hi = speaking ? end : min(end, (inside.last?.upperBound ?? end) + pad)
    return lo < hi ? lo..<hi : nil
  }

  private var isSpeaking: Bool { SherpaOnnxVoiceActivityDetectorDetected(vad) != 0 }

  private func drainSegments() {
    while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
      guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
      let start = Int(seg.pointee.start)
      let end = start + Int(seg.pointee.n)
      SherpaOnnxDestroySpeechSegment(seg)
      SherpaOnnxVoiceActivityDetectorPop(vad)
      // A segment that began before a forced cut only contributes its part after the cut.
      if end > cut { segments.append(max(start, cut)..<end) }
    }
  }
}

/// Join per-chunk transcripts: no space next to CJK text, a single space between other scripts.
public enum TranscriptJoiner {
  public static func join(_ parts: [String]) -> String {
    var out = ""
    for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
      if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
         !isCJK(last), !isCJK(first) {
        out += " "
      }
      out += part
    }
    return out
  }

  static func isCJK(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3000...0x303F,  // CJK punctuation
         0x3040...0x30FF,  // kana
         0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // ideographs
         0xAC00...0xD7AF,  // hangul
         0xFF00...0xFFEF:  // full-width forms (，。！？)
      return true
    default:
      return false
    }
  }
}
