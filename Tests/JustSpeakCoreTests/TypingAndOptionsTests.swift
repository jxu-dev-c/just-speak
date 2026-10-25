import Testing
@testable import JustSpeakCore

@Suite struct TypingPlanTests {
  func text(_ steps: [TypingPlan.Step]) -> String {
    steps.map {
      switch $0 {
      case .text(let u): String(decoding: u, as: UTF16.self)
      case .newline: "⏎"
      }
    }.joined()
  }

  @Test func chunksAtMostTwentyUnits() {
    let s = String(repeating: "汉字abc", count: 20)
    let steps = TypingPlan.steps(for: s, newlines: .shiftReturn)
    #expect(text(steps) == s)
    for case .text(let u) in steps { #expect(u.count <= TypingPlan.maxUnits) }
  }

  @Test func neverSplitsEmojiOrSurrogatePairs() {
    let s = String(repeating: "a👨‍👩‍👧‍👦", count: 10)  // family emoji = 11 UTF-16 units
    for case .text(let u) in TypingPlan.steps(for: s, newlines: .keep) {
      #expect(String(utf16CodeUnits: u, count: u.count).unicodeScalars.allSatisfy { $0.value != 0xFFFD })
    }
    #expect(text(TypingPlan.steps(for: s, newlines: .keep)) == s)
  }

  @Test func newlineHandling() {
    #expect(text(TypingPlan.steps(for: "a\nb\r\nc", newlines: .shiftReturn)) == "a⏎b⏎c")
    #expect(text(TypingPlan.steps(for: "a\nb", newlines: .space)) == "a b")
    #expect(TypingPlan.steps(for: "", newlines: .keep).isEmpty)
  }
}

@Suite struct DecodeOptionsTests {
  @Test func hotwordsCSVStripsSeparatorsInsideEntries() {
    let o = DecodeOptions(hotwords: ["Mercury", " sherpa-onnx ", "a,b", "甲，乙", ""])
    #expect(o.hotwordsCSV == "Mercury,sherpa-onnx,a b,甲 乙")
  }
}
