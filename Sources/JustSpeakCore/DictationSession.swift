import Foundation

/// One dictation: buffers audio as it arrives, cuts it into chunks at pauses and starts transcribing
/// each finished chunk immediately, so by the time the hotkey is released only the tail is left.
/// The tail itself is decoded speculatively whenever the speaker pauses; if nothing is said before
/// release, that result is used as is.
public final class DictationSession: @unchecked Sendable {
  private let queue = DispatchQueue(label: "just-speak.session", qos: .userInitiated)
  private let transcriber: Transcriber
  private let options: DecodeOptions
  // Only touched on `queue`.
  private var samples: [Float] = []
  private var chunker: SpeechChunker?
  private var chunkTasks: [Task<String, Error>] = []
  private var chunkRanges: [Range<Int>] = []
  private var speculative: (range: Range<Int>, task: Task<String, Error>)?

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
  }

  /// Stop accepting audio and return the full transcript.
  public func finish() async throws -> Result {
    let (tasks, total, ranges, tailMs, reused) = await withCheckedContinuation { cont in
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
    chunkRanges.append(range)
    chunkTasks.append(decode(range))
  }

  private func decode(_ range: Range<Int>) -> Task<String, Error> {
    let slice = Array(samples[range])
    let (transcriber, options) = (self.transcriber, self.options)
    return Task { try await transcriber.transcribe(slice, options: options) }
  }
}
