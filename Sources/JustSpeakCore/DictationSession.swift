import Foundation

/// One recording, from hotkey-down to transcript: local (`DictationSession`) or cloud (`CloudDictation`).
public protocol Dictation: AnyObject, Sendable {
  /// Rate `feed` expects, in Hz (mono Float32 in [-1, 1]).
  var sampleRate: Int { get }
  /// Append samples. Safe to call from the audio thread.
  func feed(_ chunk: [Float])
  /// Stop accepting audio and return the full transcript.
  func finish() async throws -> DictationResult
  /// Abandon the dictation; `finish` must not be called afterwards.
  func cancel()
}

public struct DictationResult: Sendable {
  /// Joined transcript; empty when no speech was detected.
  public var text: String
  public var durationMs: Int
  /// Provider-specific timing details for the log.
  public var logDetail: String

  public init(text: String, durationMs: Int, logDetail: String) {
    self.text = text
    self.durationMs = durationMs
    self.logDetail = logDetail
  }
}

/// One local dictation: buffers audio as it arrives, cuts it into chunks at pauses and starts transcribing
/// each finished chunk immediately, so by the time the hotkey is released only the tail is left.
/// The tail itself is decoded speculatively whenever the speaker pauses; if nothing is said before
/// release, that result is used as is. Those decodes also feed `onPartial` (live typing), so text shows
/// up a phrase at a time, at the speaker's pauses.
public final class DictationSession: Dictation, @unchecked Sendable {
  private let queue = DispatchQueue(label: "just-speak.session", qos: .userInitiated)
  private let transcriber: Transcriber
  private let options: DecodeOptions
  private let onPartial: (@Sendable (String) -> Void)?
  // Only touched on `queue`.
  private var samples: [Float] = []
  private var chunker: SpeechChunker?
  private var chunkTasks: [Task<String, Error>] = []
  private var chunkRanges: [Range<Int>] = []
  private var speculative: (range: Range<Int>, task: Task<String, Error>, id: Int)?
  private var nextDecodeID = 0
  private var partial = PartialTranscript()
  private var lastPartial = ""
  private var cancelled = false

  /// Without a VAD, fall back to fixed windows that fit the model's context.
  static let fallbackWindow = 18 * SpeechChunker.sampleRate

  /// `onPartial` gets the transcript so far after each decode during speech, on a background queue.
  public init(transcriber: Transcriber, vadModel: URL, options: DecodeOptions,
              onPartial: (@Sendable (String) -> Void)? = nil) {
    self.transcriber = transcriber
    self.options = options
    self.onPartial = onPartial
    queue.async {
      self.samples.reserveCapacity(SpeechChunker.sampleRate * 30)
      do {
        self.chunker = try SpeechChunker(vadModel: vadModel)
      } catch {
        Log.info("vad unavailable (\(error)); using fixed windows")
      }
    }
  }

  public var sampleRate: Int { SpeechChunker.sampleRate }

  /// Append 16 kHz mono samples. Safe to call from the audio thread; work happens on the session queue.
  public func feed(_ chunk: [Float]) {
    queue.async {
      let base = self.samples.count
      self.samples.append(contentsOf: chunk)
      guard let chunker = self.chunker else { return }
      let ranges = self.samples.withUnsafeBufferPointer {
        chunker.accept(UnsafeBufferPointer(rebasing: $0[base...]))
      }
      ranges.forEach(self.launch)
      if let tail = chunker.pendingTail(), tail != self.speculative?.range {
        let (id, task) = self.decode(tail)
        self.speculative = (tail, task, id)
        self.partial.setTail(id)
      }
    }
  }

  public struct Result: Sendable {
    /// Joined transcript; empty when no speech was detected.
    public var text: String
    public var durationMs: Int
    public var chunks: [Range<Int>]
    /// Audio left to decode at release, in ms; 0 when the tail had already been decoded speculatively.
    public var tailMs: Int
    public var tailReused: Bool
  }

  /// Chunks already handed to the ASR queue finish and are discarded.
  public func cancel() {
    queue.async { self.cancelled = true }
  }

  public func finish() async throws -> DictationResult {
    let r = try await finishWithChunks()
    return DictationResult(text: r.text, durationMs: r.durationMs,
                           logDetail: "chunks=\(r.chunks.count) tail=\(r.tailMs)ms spec=\(r.tailReused ? "hit" : "miss")")
  }

  /// Stop accepting audio and return the full transcript, with how it was cut into chunks.
  public func finishWithChunks() async throws -> Result {
    let (tasks, total, ranges, tailMs, reused) = await withCheckedContinuation { cont in
      queue.async {
        var tailMs = 0
        var reused = false
        if let chunker = self.chunker {
          if let tail = chunker.finish(total: self.samples.count) {
            if let spec = self.speculative, chunker.isSameSpeech(spec.range, as: tail) {
              self.chunkRanges.append(tail)
              self.chunkTasks.append(spec.task)
              self.partial.addChunk(spec.id)
              reused = true
            } else {
              self.launch(tail)
              tailMs = tail.count * 1000 / SpeechChunker.sampleRate
            }
          }
        } else {
          stride(from: 0, to: self.samples.count, by: Self.fallbackWindow).forEach {
            self.launch($0..<min($0 + Self.fallbackWindow, self.samples.count))
          }
        }
        let total = self.samples.count
        self.samples = []
        self.speculative = nil
        cont.resume(returning: (self.chunkTasks, total, self.chunkRanges, tailMs, reused))
      }
    }
    var parts: [String] = []
    for t in tasks { parts.append(try await t.value) }
    return Result(text: TranscriptJoiner.join(parts), durationMs: total * 1000 / SpeechChunker.sampleRate,
                  chunks: ranges, tailMs: tailMs, tailReused: reused)
  }

  private func launch(_ range: Range<Int>) {
    let (id, task) = decode(range)
    chunkRanges.append(range)
    chunkTasks.append(task)
    partial.addChunk(id)
  }

  private func decode(_ range: Range<Int>) -> (id: Int, task: Task<String, Error>) {
    let slice = Array(samples[range])
    let (transcriber, options) = (self.transcriber, self.options)
    let id = nextDecodeID
    nextDecodeID += 1
    guard onPartial != nil else {
      return (id, Task { try await transcriber.transcribe(slice, options: options) })
    }
    return (id, Task {
      let text = try await transcriber.transcribe(slice, options: options)
      self.queue.async { self.decoded(id, text) }
      return text
    })
  }

  private func decoded(_ id: Int, _ text: String) {
    partial.finished(id, text: text)
    guard !cancelled, let onPartial, let t = partial.text, !t.isEmpty, t != lastPartial else { return }
    lastPartial = t
    onPartial(t)
  }
}

/// What live typing shows for a local dictation: the chunks cut so far, in order, then the latest decode of
/// the speech since the last cut. `text` is nil while any of those decodes is still running, so the shown
/// text never shrinks back just because newer work hasn't finished yet.
struct PartialTranscript {
  private var chunks: [Int] = []
  private var tail: Int?
  private var texts: [Int: String] = [:]
  /// A chunk is usually cut at the pause that just started a tail decode of the same speech, so until the
  /// chunk's own decode finishes, that tail decode stands in for it (instead of waiting for both).
  private var standIn: [Int: Int] = [:]

  /// A chunk was cut (or, at release, the tail decode became one): it covers any earlier tail decode.
  mutating func addChunk(_ id: Int) {
    chunks.append(id)
    if let tail, tail != id { standIn[id] = tail }
    tail = nil
  }

  /// A newer decode of the speech since the last cut, started at a pause.
  mutating func setTail(_ id: Int) {
    tail = id
  }

  mutating func finished(_ id: Int, text: String) {
    texts[id] = text
  }

  var text: String? {
    var parts: [String] = []
    for id in chunks + (tail.map { [$0] } ?? []) {
      guard let t = texts[id] ?? standIn[id].flatMap({ texts[$0] }) else { return nil }
      parts.append(t)
    }
    return TranscriptJoiner.join(parts)
  }
}
