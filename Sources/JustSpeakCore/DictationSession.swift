import Foundation

/// One dictation: buffers audio as it arrives, cuts it into chunks at pauses and starts transcribing
/// each finished chunk immediately, so by the time the hotkey is released only the tail is left.
public final class DictationSession: @unchecked Sendable {
  private let queue = DispatchQueue(label: "just-speak.session", qos: .userInitiated)
  private let transcriber: Transcriber
  private let options: DecodeOptions
  // Only touched on `queue`.
  private var samples: [Float] = []
  private var chunker: SpeechChunker?
  private var chunkTasks: [Task<String, Error>] = []
  private var chunkRanges: [Range<Int>] = []

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
    }
  }

  public struct Result: Sendable {
    /// Joined transcript; empty when no speech was detected.
    public var text: String
    public var durationMs: Int
    public var chunks: [Range<Int>]
  }

  /// Stop accepting audio and return the full transcript.
  public func finish() async throws -> Result {
    let (tasks, total, ranges) = await withCheckedContinuation { cont in
      queue.async {
        if let chunker = self.chunker {
          if let tail = chunker.finish(total: self.samples.count) { self.launch(tail) }
        } else {
          stride(from: 0, to: self.samples.count, by: Self.fallbackWindow).forEach {
            self.launch($0..<min($0 + Self.fallbackWindow, self.samples.count))
          }
        }
        let total = self.samples.count
        self.samples = []
        cont.resume(returning: (self.chunkTasks, total, self.chunkRanges))
      }
    }
    var parts: [String] = []
    for t in tasks { parts.append(try await t.value) }
    return Result(text: TranscriptJoiner.join(parts), durationMs: total * 1000 / SpeechChunker.sampleRate,
                  chunks: ranges)
  }

  private func launch(_ range: Range<Int>) {
    let slice = Array(samples[range])
    let (transcriber, options) = (self.transcriber, self.options)
    chunkRanges.append(range)
    chunkTasks.append(Task { try await transcriber.transcribe(slice, options: options) })
  }
}
