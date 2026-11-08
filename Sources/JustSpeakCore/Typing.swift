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

  /// What typing `text` leaves in a text field: line breaks become one "\n" each, or a space with `.space`.
  public static func rendered(_ text: String, newlines: Config.Output.Newlines) -> String {
    let t = text.replacingOccurrences(of: "\r\n", with: "\n")
    return newlines == .space ? t.replacingOccurrences(of: "\n", with: " ") : t
  }

  /// How to turn a field that ends with `typed` into one that ends with `target` (both `rendered`):
  /// press Delete `delete` times, then type `insert`. Counted in Characters, since one Delete removes one
  /// grapheme cluster (an emoji or CJK character as much as a letter). Text after the common prefix is retyped.
  public struct Edit: Equatable, Sendable {
    public var delete: Int
    public var insert: String
    public init(delete: Int, insert: String) {
      self.delete = delete
      self.insert = insert
    }
  }

  public static func edit(from typed: String, to target: String) -> Edit {
    var a = typed.startIndex
    var b = target.startIndex
    while a < typed.endIndex, b < target.endIndex, typed[a] == target[b] {
      a = typed.index(after: a)
      b = target.index(after: b)
    }
    return Edit(delete: typed[a...].count, insert: String(target[b...]))
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
