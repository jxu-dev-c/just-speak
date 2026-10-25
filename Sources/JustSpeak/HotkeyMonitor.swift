import AppKit
import JustSpeakCore

/// Watches a single modifier key through an NSEvent global monitor. That needs only the
/// Accessibility permission (already required for typing), never delays or swallows events,
/// and costs nothing while idle.
@MainActor
final class HotkeyMonitor {
  enum Event { case pressed, released, cancelled }

  /// keycode + device-specific modifier bit (IOKit's NX_DEVICE*KEYMASK) for each supported key.
  private static let keys: [String: (keyCode: UInt16, mask: UInt)] = [
    "rightOption": (61, 0x40),
    "leftOption": (58, 0x20),
    "rightCommand": (54, 0x10),
    "rightControl": (62, 0x2000),
    "rightShift": (60, 0x04),
    "fn": (63, 0x80_0000),
  ]
  private static let escapeKeyCode: UInt16 = 53

  var onEvent: ((Event) -> Void)?
  private var target: (keyCode: UInt16, mask: UInt)
  private var isDown = false
  private var monitor: Any?
  private var loggedFirstEvent = false

  init(key: String) {
    target = Self.keys[key] ?? Self.keys["rightOption"]!
    if Self.keys[key] == nil { Log.info("unknown hotkey.key \(key), using rightOption") }
  }

  func setKey(_ key: String) {
    target = Self.keys[key] ?? Self.keys["rightOption"]!
    isDown = false
  }

  var isActive: Bool { monitor != nil }

  /// Global monitors silently receive nothing until Accessibility is granted, so callers should
  /// only start once `Inserter.hasAccessibility` is true.
  @discardableResult
  func start() -> Bool {
    guard monitor == nil else { return true }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
    }
    return monitor != nil
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isDown = false
  }

  private func handle(_ event: NSEvent) {
    if !loggedFirstEvent {
      loggedFirstEvent = true
      Log.info("hotkey monitor receiving events")
    }
    switch event.type {
    case .flagsChanged:
      guard event.keyCode == target.keyCode else { return }
      let down = event.modifierFlags.rawValue & target.mask != 0
      guard down != isDown else { return }
      isDown = down
      onEvent?(down ? .pressed : .released)
    case .keyDown:
      // Esc cancels; any other key while the hotkey is held means it's being used as a modifier
      // (e.g. ⌥← word jump), so that press isn't a dictation.
      if event.keyCode == Self.escapeKeyCode || isDown {
        onEvent?(.cancelled)
      }
    default:
      break
    }
  }
}
