import Foundation

/// How text is broken into synthetic key events for `output.method = type`.
public enum TypingPlan {
  public enum Step: Equatable, Sendable {
    /// At most `maxUnits` UTF-16 code units, never splitting a grapheme cluster.
    case text([UInt16])
    /// A line break, sent as a Return key press (with or without Shift).
    case newline
  }

  /// Apps reliably accept up to 20 UTF-16 units per CGEventKeyboardSetUnicodeString call.
  public static let maxUnits = 20

  public static func steps(for text: String, newlines: Config.Output.Newlines) -> [Step] {
    var steps: [Step] = []
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() {
      if i > 0 {
        if newlines == .space { appendText(" ", to: &steps) } else { steps.append(.newline) }
      }
      appendText(String(line), to: &steps)
    }
    return steps
  }

  private static func appendText(_ s: String, to steps: inout [Step]) {
    var chunk: [UInt16] = []
    for ch in s {  // Character = grapheme cluster, so emoji/CJK never split
      let units = Array(String(ch).utf16)
      if !chunk.isEmpty && chunk.count + units.count > maxUnits {
        steps.append(.text(chunk))
        chunk = []
      }
      chunk += units
    }
    if !chunk.isEmpty { steps.append(.text(chunk)) }
  }
}
