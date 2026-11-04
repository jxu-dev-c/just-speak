import Foundation
import os

/// One dictation on both providers: audio feeds the local session and streams to OpenAI uncommitted.
/// At release it picks whichever should be faster:
/// - little left to decode locally, with the model loaded: local alone, and the OpenAI turn is never committed
///   (no transcript is requested);
/// - otherwise (a long stretch of speech without a pause, or the model still loading): OpenAI is committed and
///   raced against the local decode, and the first transcript wins.
/// OpenAI's final transcript arrives ~0.5–0.8 s after commit however long the recording, while local decoding
/// takes ~75 ms per second of audio left, so local wins most dictations. Without an OpenAI key, this is local only.
public final class HybridDictation: Dictation, @unchecked Sendable {
  public enum Choice: String, Sendable { case local, race }

  private let local: DictationSession
  private let cloud: CloudDictation?
  private let transcriber: Transcriber
  private let localMaxMs: Int
  private let queue = DispatchQueue(label: "just-speak.hybrid", qos: .userInitiated)
  private var resampler = StreamResampler(from: SpeechChunker.sampleRate, to: RealtimeProtocol.sampleRate)  // on `queue`

  public init(local: DictationSession, cloud: CloudDictation?, transcriber: Transcriber, localMaxMs: Int) {
    self.local = local
    self.cloud = cloud
    self.transcriber = transcriber
    self.localMaxMs = localMaxMs
  }

  public var sampleRate: Int { local.sampleRate }

  public func feed(_ chunk: [Float]) {
    local.feed(chunk)
    guard let cloud else { return }
    queue.async { cloud.feed(self.resampler.process(chunk)) }
  }

  public func cancel() {
    local.cancel()
    cloud?.cancel()
  }

  public static func choose(pendingMs: Int, modelLoaded: Bool, hasCloud: Bool, localMaxMs: Int) -> Choice {
    hasCloud && (!modelLoaded || pendingMs > localMaxMs) ? .race : .local
  }

  public func finish() async throws -> DictationResult {
    let pending = await local.release()
    let choice = Self.choose(pendingMs: pending.pendingMs, modelLoaded: transcriber.isLoaded,
                             hasCloud: cloud != nil, localMaxMs: localMaxMs)
    let detail = "pick=\(choice.rawValue) pending=\(pending.pendingMs)ms"
    let decodeLocal: @Sendable () async throws -> DictationResult = {
      let r = try await pending.result()
      return DictationResult(text: r.text, durationMs: r.durationMs, logDetail: r.logDetail)
    }
    guard let cloud else {
      let r = try await decodeLocal()
      return DictationResult(text: r.text, durationMs: r.durationMs, logDetail: "\(detail) cloud=none \(r.logDetail)")
    }
    // every resampled block must reach the socket before the turn is committed
    await withCheckedContinuation { cont in queue.async { cont.resume() } }

    switch choice {
    case .local:
      do {
        let r = try await decodeLocal()
        cloud.cancel()
        return DictationResult(text: r.text, durationMs: r.durationMs, logDetail: "\(detail) \(r.logDetail)")
      } catch {
        Log.info("hybrid: local failed (\(error)); using OpenAI")
        let r = try await cloud.finish()
        return DictationResult(text: r.text, durationMs: r.durationMs,
                               logDetail: "\(detail) won=openai(local failed) \(r.logDetail)")
      }
    case .race:
      let (winner, r) = try await Self.firstSuccess(("local", decodeLocal), ("openai", { try await cloud.finish() }))
      if winner == "local" { cloud.cancel() }
      return DictationResult(text: r.text, durationMs: r.durationMs, logDetail: "\(detail) won=\(winner) \(r.logDetail)")
    }
  }

  /// The first of two operations to succeed, without waiting for the other; if both fail, the last error.
  static func firstSuccess<T: Sendable>(
    _ a: (String, @Sendable () async throws -> T), _ b: (String, @Sendable () async throws -> T)
  ) async throws -> (String, T) {
    try await withCheckedThrowingContinuation { cont in
      let state = OSAllocatedUnfairLock(initialState: (resumed: false, failures: 0))
      for (name, op) in [a, b] {
        Task {
          do {
            let value = try await op()
            let first = state.withLock { s in
              defer { s.resumed = true }
              return !s.resumed
            }
            if first { cont.resume(returning: (name, value)) }
          } catch {
            let last = state.withLock { s in
              s.failures += 1
              return s.failures == 2
            }
            if last { cont.resume(throwing: error) }
          }
        }
      }
    }
  }
}
