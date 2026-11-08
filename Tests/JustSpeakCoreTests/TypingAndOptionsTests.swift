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

@Suite struct LiveEditTests {
  func apply(_ typed: String, _ target: String) -> String {
    let e = TypingPlan.edit(from: typed, to: target)
    return String(typed.dropLast(e.delete)) + e.insert
  }

  @Test func appendingTypesOnlyTheNewText() {
    #expect(TypingPlan.edit(from: "hello", to: "hello world") == .init(delete: 0, insert: " world"))
    #expect(TypingPlan.edit(from: "", to: "hi") == .init(delete: 0, insert: "hi"))
    #expect(TypingPlan.edit(from: "same", to: "same") == .init(delete: 0, insert: ""))
  }

  @Test func revisionsRetypeFromTheFirstDifference() {
    #expect(TypingPlan.edit(from: "um so hello", to: "So, hello.") == .init(delete: 11, insert: "So, hello."))
    #expect(TypingPlan.edit(from: "ship it on Monday", to: "ship it on Tuesday.") == .init(delete: 6, insert: "Tuesday."))
    #expect(TypingPlan.edit(from: "erase me", to: "") == .init(delete: 8, insert: ""))
    for (a, b) in [("abc", "abd"), ("我明天要去开会", "我后天要去开会。"), ("", ""), ("x", "")] {
      #expect(apply(a, b) == b)
    }
  }

  @Test func countsGraphemeClusters() {
    #expect(TypingPlan.edit(from: "ok 👨‍👩‍👧‍👦", to: "ok") == .init(delete: 2, insert: ""))
    #expect(TypingPlan.edit(from: "嗯那个", to: "那个") == .init(delete: 3, insert: "那个"))
  }

  @Test func renderedNewlines() {
    #expect(TypingPlan.rendered("a\r\nb\nc", newlines: .shiftReturn) == "a\nb\nc")
    #expect(TypingPlan.rendered("a\r\nb\nc", newlines: .keep) == "a\nb\nc")
    #expect(TypingPlan.rendered("a\r\nb\nc", newlines: .space) == "a b c")
    // "\r\n" is one Character: render before diffing so one Delete per typed line break is counted
    #expect(TypingPlan.edit(from: TypingPlan.rendered("a\r\n", newlines: .keep), to: "a") == .init(delete: 1, insert: ""))
  }
}
