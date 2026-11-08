import AppKit
import ApplicationServices
import Carbon.HIToolbox
import JustSpeakCore

/// Puts text into the focused app. The default (`type`) never touches the clipboard.
@MainActor
enum Inserter {
  static var hasAccessibility: Bool { AXIsProcessTrusted() }

  static func requestAccessibility() {
    // literal value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe in Swift 6)
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
  }

  static func insert(_ text: String, config: Config.Output) async {
    switch config.method {
    case .ax:
      if insertViaAccessibility(text) { return }
      await type(text, config: config)
    case .type:
      await type(text, config: config)
    case .paste:
      await paste(text)
    }
  }

  // MARK: type

  /// Stamped on every key event we post (`eventSourceUserData`), so the hotkey monitor can tell
  /// them from the user's own keys. "JSPK".
  static let marker: Int64 = 0x4A53_504B

  /// Synthetic key events carrying the text as Unicode, ≤20 UTF-16 units each.
  static func type(_ text: String, config: Config.Output) async {
    let restoreSource = await beginTyping(config)
    await postText(text, newlines: config.newlines)
    await endTyping(restoreSource)
  }

  /// If an input method is active, switch to its ASCII layout; pass the result to `endTyping`.
  static func beginTyping(_ config: Config.Output) async -> TISInputSource? {
    let restoreSource = config.switchToAsciiInputSource ? switchToASCIILayoutIfNeeded() : nil
    if restoreSource != nil { try? await Task.sleep(for: .milliseconds(40)) }  // let the switch land
    return restoreSource
  }

  static func endTyping(_ restoreSource: TISInputSource?) async {
    guard let restoreSource else { return }
    try? await Task.sleep(for: .milliseconds(40))
    TISSelectInputSource(restoreSource)
  }

  /// Type `text` as is, without touching the input source.
  static func postText(_ text: String, newlines: Config.Output.Newlines) async {
    let src = CGEventSource(stateID: .hidSystemState)
    for step in TypingPlan.steps(for: text, newlines: newlines) {
      switch step {
      case .text(var units):
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        for e in [down, up] {
          e.flags = []  // the hotkey modifier may still be physically held (hold mode while streaming, toggle mode)
          e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
          e.setIntegerValueField(.eventSourceUserData, value: marker)
          e.post(tap: .cghidEventTap)
        }
      case .newline:
        postKey(CGKeyCode(kVK_Return), flags: newlines == .shiftReturn ? .maskShift : [], source: src)
      }
      // A short gap keeps busy apps (Electron, terminals) from dropping events.
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  /// Deletes posted back to back before a short pause, so slow apps (Electron) can keep up.
  static let deleteBurst = 50

  /// Press Delete `count` times (no modifiers, so a held ⌥ doesn't turn it into delete-word), in bursts:
  /// the app handles them in a redraw or two, so the old text vanishes at once instead of visibly erasing.
  static func deleteBackward(_ count: Int) async {
    guard count > 0 else { return }
    let src = CGEventSource(stateID: .hidSystemState)
    for i in 1...count {
      postKey(CGKeyCode(kVK_Delete), flags: [], source: src)
      if i % deleteBurst == 0 && i < count { try? await Task.sleep(for: .milliseconds(2)) }
    }
  }

  private static func postKey(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
    for isDown in [true, false] {
      guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
      e.flags = flags
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)
    }
  }

  /// If an input method (Pinyin, Kotoeri, …) is active it may treat synthetic events as keystrokes
  /// to compose; switch to the matching ASCII layout and return the source to restore afterwards.
  private static func switchToASCIILayoutIfNeeded() -> TISInputSource? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    let type = property(current, kTISPropertyInputSourceType) as String?
    guard type != (kTISTypeKeyboardLayout as String) else { return nil }
    guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    TISSelectInputSource(ascii)
    return current
  }

  private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
  }

  // MARK: ax

  /// Replace the focused element's selection. Instant, but only native Cocoa text views honor it.
  private static func insertViaAccessibility(_ text: String) -> Bool {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
    let el = element as! AXUIElement
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
          settable.boolValue else { return false }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
  }

  // MARK: paste (opt-in fallback)

  /// ⌘V via a temporary pasteboard entry marked transient/concealed so clipboard managers skip it,
  /// then put the previous contents back.
  private static func paste(_ text: String) async {
    let pb = NSPasteboard.general
    let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
      return copy
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

    postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: CGEventSource(stateID: .hidSystemState))
    try? await Task.sleep(for: .milliseconds(250))  // the target app reads the pasteboard asynchronously

    pb.clearContents()
    if !saved.isEmpty { pb.writeObjects(saved) }
  }
}
