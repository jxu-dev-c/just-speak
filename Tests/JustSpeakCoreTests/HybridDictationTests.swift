import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct HybridDictationTests {
  @Test func choosesLocalUnlessALongTailOrColdModel() {
    let choose = { (ms: Int, loaded: Bool, cloud: Bool) in
      HybridDictation.choose(pendingMs: ms, modelLoaded: loaded, hasCloud: cloud, localMaxMs: 6000)
    }
    #expect(choose(0, true, true) == .local)
    #expect(choose(6000, true, true) == .local)
    #expect(choose(6001, true, true) == .race)
    #expect(choose(500, false, true) == .race)     // model still loading: ~1–3 s before any decode
    #expect(choose(20_000, false, false) == .local) // no OpenAI key: local is all there is
  }

  @Test func firstSuccessDoesNotWaitForTheSlowerOne() async throws {
    let sw = Stopwatch()
    let (winner, value) = try await HybridDictation.firstSuccess(
      ("slow", { try await Task.sleep(for: .seconds(2)); return 1 }),
      ("fast", { try await Task.sleep(for: .milliseconds(20)); return 2 }))
    #expect(winner == "fast" && value == 2)
    #expect(sw.ms < 1000)
  }

  @Test func firstSuccessSkipsAFailureAndThrowsWhenBothFail() async throws {
    struct Boom: Error {}
    let (winner, _) = try await HybridDictation.firstSuccess(
      ("fails", { () async throws -> Int in throw Boom() }),
      ("works", { try await Task.sleep(for: .milliseconds(20)); return 0 }))
    #expect(winner == "works")
    await #expect(throws: Boom.self) {
      try await HybridDictation.firstSuccess(("a", { () async throws -> Int in throw Boom() }),
                                             ("b", { () async throws -> Int in throw Boom() }))
    }
  }

  @Test func streamResamplerMatchesWholeBufferAcrossBlocks() {
    let input = (0..<4000).map { Float(sin(Double($0) * 0.05)) }
    let whole = Resample.linear(input, from: 16_000, to: 24_000)
    var r = StreamResampler(from: 16_000, to: 24_000)
    var streamed: [Float] = []
    var i = 0
    for size in [1, 2, 3, 1365, 7, 1600, 1022] where i < input.count {
      streamed += r.process(Array(input[i..<min(i + size, input.count)]))
      i += size
    }
    #expect(i >= input.count)
    #expect(abs(streamed.count - whole.count) <= 1)
    let n = min(streamed.count, whole.count) - 1
    #expect(zip(streamed[..<n], whole[..<n]).allSatisfy { abs($0 - $1) < 1e-4 })
  }
}
