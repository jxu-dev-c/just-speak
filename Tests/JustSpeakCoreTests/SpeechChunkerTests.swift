import Foundation
import Testing
@testable import JustSpeakCore

private let models = Paths.modelsDir
private let vad = models.appendingPathComponent("silero_vad.onnx")
private let wavs = models.appendingPathComponent("funasr-nano-int8-mmap/test_wavs")
private let haveModels = FileManager.default.fileExists(atPath: vad.path)
  && FileManager.default.fileExists(atPath: wavs.path)

/// Feed like the microphone does (100 ms blocks) and collect every chunk.
private func chunks(_ samples: [Float], params: SpeechChunker.Params = .init()) throws -> [Range<Int>] {
  let c = try SpeechChunker(vadModel: vad, params: params)
  var out: [Range<Int>] = []
  for i in stride(from: 0, to: samples.count, by: 1600) {
    let end = min(i + 1600, samples.count)
    out += samples.withUnsafeBufferPointer { c.accept(UnsafeBufferPointer(rebasing: $0[i..<end])) }
  }
  if let tail = c.finish(total: samples.count) { out.append(tail) }
  return out
}

private func wav(_ name: String) throws -> [Float] {
  try #require(Wave.read(wavs.appendingPathComponent(name).path)).samples
}

@Suite(.enabled(if: haveModels, "needs scripts/fetch-deps.sh")) struct SpeechChunkerTests {
  let maxLen = Int((SpeechChunker.Params().maxChunkSeconds + SpeechChunker.Params().padSeconds) * 16000)

  @Test func silenceYieldsNothing() throws {
    #expect(try chunks([Float](repeating: 0, count: 16000 * 5)).isEmpty)
  }

  @Test func shortUtteranceIsOneChunk() throws {
    let s = try wav("noise_en.wav")  // 10.6 s
    let c = try chunks(s)
    #expect(c.count == 1)
    #expect(c[0].count > s.count * 8 / 10)
  }

  @Test func longSpeechIsSplitWithinTheModelContext() throws {
    // ~45 s: three clips back to back with short gaps
    let gap = [Float](repeating: 0, count: 8000)
    let s = try wav("far_3.wav") + gap + wav("noise_en.wav") + gap + wav("lyrics_en_2.wav")
    let c = try chunks(s)
    #expect(c.count >= 3)
    for r in c { #expect(r.count <= maxLen, "chunk \(r) too long") }
    for (a, b) in zip(c, c.dropFirst()) { #expect(a.upperBound <= b.lowerBound, "chunks overlap") }
    let covered = c.reduce(0) { $0 + $1.count }
    #expect(covered > s.count * 8 / 10, "speech dropped")
  }

  @Test func leadingSilenceIsTrimmed() throws {
    let s = [Float](repeating: 0, count: 16000 * 3) + (try wav("noise_en.wav"))
    let c = try chunks(s)
    #expect(c.count == 1)
    #expect(c[0].lowerBound >= 16000 * 2)
  }
}

@Suite struct TranscriptJoinerTests {
  @Test func joinsScriptsSensibly() {
    #expect(TranscriptJoiner.join(["Hello there.", "How are you?"]) == "Hello there. How are you?")
    #expect(TranscriptJoiner.join(["今天天气很好。", "我们出去吧。"]) == "今天天气很好。我们出去吧。")
    #expect(TranscriptJoiner.join(["用 Swift 写的", "app"]) == "用 Swift 写的app")
    #expect(TranscriptJoiner.join(["", " a ", "", "b"]) == "a b")
  }
}
