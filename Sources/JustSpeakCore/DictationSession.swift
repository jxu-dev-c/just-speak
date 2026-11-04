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
/// release, that result is used as is.
public final class DictationSession: Dictation, @unchecked Sendable {
  private let queue = DispatchQueue(label: "just-speak.session", qos: .userInitiated)
  private let transcriber: Transcriber
  private let options: DecodeOptions
  // Only touched on `queue`.
  private var samples: [Float] = []
  private var chunker: SpeechChunker?
  private var chunkTasks: [Task<String, Error>] = []
  private var chunkRanges: [Range<Int>] = []
  private var speculative: (range: Range<Int>, task: Task<String, Error>)?
  /// Samples per decode still running or queued, by decode id: the backlog a new decode waits behind.
  private var inFlight: [Int: Int] = [:]
  private var nextDecodeID = 0

  /// Without a VAD, fall back to fixed windows that fit the model's context.
  static let fallbackWindow = 18 * SpeechChunker.sampleRate

  public init(transcriber: Transcriber, vadModel: URL, options: DecodeOptions) {
    self.transcriber = transcriber
    self.options = options
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
        self.speculative = (tail, self.decode(tail))
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

    public var logDetail: String { "chunks=\(chunks.count) tail=\(tailMs)ms spec=\(tailReused ? "hit" : "miss")" }
  }

  /// A released recording whose decodes may still be running.
  public struct Pending: Sendable {
    fileprivate let tasks: [Task<String, Error>]
    public let durationMs: Int
    public let chunks: [Range<Int>]
    public let tailMs: Int
    public let tailReused: Bool
    /// Audio still being decoded (or queued) at release, in ms, including chunks cut shortly before it.
    public let pendingMs: Int

    public func result() async throws -> Result {
      var parts: [String] = []
      for t in tasks { parts.append(try await t.value) }
      return Result(text: TranscriptJoiner.join(parts), durationMs: durationMs, chunks: chunks, tailMs: tailMs,
                    tailReused: tailReused)
    }
  }

  /// Chunks already handed to the ASR queue finish and are discarded.
  public func cancel() {}

  public func finish() async throws -> DictationResult {
    let r = try await finishWithChunks()
    return DictationResult(text: r.text, durationMs: r.durationMs, logDetail: r.logDetail)
  }

  /// Stop accepting audio and return the full transcript, with how it was cut into chunks.
  public func finishWithChunks() async throws -> Result {
    try await release().result()
  }

  /// Stop accepting audio and start decoding what is left, without waiting for it.
  public func release() async -> Pending {
    await withCheckedContinuation { cont in
      queue.async {
        var tailMs = 0
        var reused = false
        if let chunker = self.chunker {
          if let tail = chunker.finish(total: self.samples.count) {
            if let spec = self.speculative, chunker.isSameSpeech(spec.range, as: tail) {
              self.chunkRanges.append(tail)
              self.chunkTasks.append(spec.task)
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
          tailMs = self.samples.count * 1000 / SpeechChunker.sampleRate
        }
        let total = self.samples.count
        self.samples = []
        self.speculative = nil
        cont.resume(returning: Pending(
          tasks: self.chunkTasks, durationMs: total * 1000 / SpeechChunker.sampleRate, chunks: self.chunkRanges,
          tailMs: tailMs, tailReused: reused,
          pendingMs: self.inFlight.values.reduce(0, +) * 1000 / SpeechChunker.sampleRate))
      }
    }
  }

  private func launch(_ range: Range<Int>) {
    chunkRanges.append(range)
    chunkTasks.append(decode(range))
  }

  private func decode(_ range: Range<Int>) -> Task<String, Error> {
    let slice = Array(samples[range])
    let (transcriber, options) = (self.transcriber, self.options)
    let id = nextDecodeID
    nextDecodeID += 1
    inFlight[id] = range.count
    return Task {
      defer { self.queue.async { self.inFlight[id] = nil } }
      return try await transcriber.transcribe(slice, options: options)
    }
  }
}
