import AppKit
import Carbon.HIToolbox
import JustSpeakCore

/// Types the transcript into the focused field while the user is still speaking, then swaps in the final
/// (rewritten) text at release. It assumes the field still ends with exactly what it typed: each update
/// presses Delete for the characters after the common prefix and types the rest (`TypingPlan.edit`).
/// Edits the user makes in between aren't merged. One per dictation.
@MainActor
final class LiveTyper {
  private let config: Config.Output
  /// Frontmost app when the first text was typed: from then on, never type anywhere else.
  private var pid: pid_t?
  /// What we have put in the field, as `TypingPlan.rendered`.
  private var typed = ""
  private var pending: String?
  private var worker: Task<Void, Never>?
  /// Set once the press is confirmed as a dictation (after `hotkey.minHoldMs`), so a stray tap types nothing.
  private var armed = false
  private var finishing = false
  private var detached = false
  private var began = false
  private var restoreSource: TISInputSource?

  private(set) var partials = 0
  private(set) var deleted = 0

  init(config: Config.Output) {
    self.config = config
  }

  /// The transcript so far (from `CloudDictation`'s `onPartial`).
  func show(_ partial: String) {
    guard !finishing else { return }
    pending = partial
    if armed { drain() }
  }

  func arm() {
    armed = true
    if pending != nil { drain() }
  }

  /// Replace what was typed with `text` and restore the input source. False if the focused app changed
  /// after text was typed: then nothing is touched and the caller should point at Copy Last Dictation.
  func finish(_ text: String) async -> Bool {
    finishing = true
    pending = nil
    await worker?.value
    await apply(text)
    await end()
    return !detached
  }

  /// Stop typing and leave whatever is in the field (cancel, failed transcription).
  func stop() async {
    finishing = true
    pending = nil
    await worker?.value
    await end()
  }

  private func drain() {
    guard worker == nil else { return }
    worker = Task {
      while let next = pending {
        pending = nil
        partials += 1
        await apply(next)
      }
      worker = nil
    }
  }

  private func apply(_ text: String) async {
    guard !detached else { return }
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if typed.isEmpty {
      pid = frontmost
    } else if frontmost != pid {
      detached = true
      Log.info("live typing: focus moved to another app; leaving the field as is")
      return
    }
    let target = TypingPlan.rendered(text, newlines: config.newlines)
    let edit = TypingPlan.edit(from: typed, to: target)
    guard edit.delete > 0 || !edit.insert.isEmpty else { return }
    if !began {
      began = true
      restoreSource = await Inserter.beginTyping(config)
    }
    await Inserter.deleteBackward(edit.delete)
    await Inserter.postText(edit.insert, newlines: config.newlines)
    deleted += edit.delete
    typed = target
  }

  private func end() async {
    guard began else { return }
    began = false
    await Inserter.endTyping(restoreSource)
    restoreSource = nil
  }
}
