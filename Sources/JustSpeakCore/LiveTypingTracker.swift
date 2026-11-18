import Foundation

/// Tracks target process focus and incremental field edits for a single live-typed dictation session.
/// Captures `targetPID` eagerly when recording starts so focus changes before the first partial (or after
/// a partial is erased back to `""`) detach immediately instead of binding to the new app.
@MainActor
public final class LiveTypingTracker {
  public let config: Config.Output
  public let targetPID: pid_t?
  private let frontmostPID: () -> pid_t?
  public private(set) var typed = ""
  public private(set) var detached = false
  public private(set) var deleted = 0

  public init(config: Config.Output, targetPID: pid_t?, frontmostPID: @escaping () -> pid_t?) {
    self.config = config
    self.targetPID = targetPID
    self.frontmostPID = frontmostPID
  }

  /// Computes the next edit to type for `text`, or returns `nil` if detached or no keystrokes are needed.
  public func nextEdit(for text: String) -> TypingPlan.Edit? {
    guard !detached else { return nil }
    if frontmostPID() != targetPID {
      detached = true
      Log.info("live typing: focus moved to another app; leaving the field as is")
      return nil
    }
    let target = TypingPlan.rendered(text, newlines: config.newlines)
    let edit = TypingPlan.edit(from: typed, to: target)
    guard edit.delete > 0 || !edit.insert.isEmpty else { return nil }
    deleted += edit.delete
    typed = target
    return edit
  }
}
