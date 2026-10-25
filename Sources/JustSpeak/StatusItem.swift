import AppKit

/// Menu-bar icon reflecting pipeline state. The menu is rebuilt on open so it is always current.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
  enum Phase { case idle, loading, recording, processing, warning }

  struct Actions {
    var openConfig: () -> Void
    var revealHistory: () -> Void
    var copyLast: () -> Void
    var unloadModel: () -> Void
    var toggleLaunchAtLogin: () -> Void
    var launchAtLogin: () -> Bool
    var requestPermissions: () -> Void
    var missingPermissions: () -> [String]
  }

  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let actions: Actions
  private(set) var phase = Phase.idle
  var message: String?   // last warning, shown at the top of the menu
  var lastSummary: String?

  init(actions: Actions) {
    self.actions = actions
    super.init()
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    set(.idle)
  }

  func set(_ phase: Phase, message: String? = nil) {
    self.phase = phase
    if phase == .warning { self.message = message }
    let (symbol, tint): (String, NSColor?) = switch phase {
    case .idle: ("mic", nil)
    case .loading: ("mic.badge.plus", nil)
    case .recording: ("mic.fill", Brand.accent)
    case .processing: ("ellipsis.circle", nil)
    case .warning: ("exclamationmark.triangle", .systemOrange)
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "just-speak")
    if let tint {
      item.button?.image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
    } else {
      image?.isTemplate = true
      item.button?.image = image
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let missing = actions.missingPermissions()
    if !missing.isEmpty {
      menu.addItem(withTitle: "Grant permissions: \(missing.joined(separator: ", "))…",
                   action: #selector(requestPermissions), keyEquivalent: "").target = self
      menu.addItem(.separator())
    }
    if let message {
      menu.addItem(disabled("⚠︎ \(message)"))
    }
    if let lastSummary {
      menu.addItem(disabled(lastSummary))
    }
    if message != nil || lastSummary != nil { menu.addItem(.separator()) }

    menu.addItem(withTitle: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",").target = self
    menu.addItem(withTitle: "Reveal History Folder", action: #selector(revealHistory), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Unload Model", action: #selector(unloadModel), keyEquivalent: "").target = self
    let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    login.target = self
    login.state = actions.launchAtLogin() ? .on : .off
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit just-speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  func menuDidClose(_ menu: NSMenu) {
    // Opening the menu acknowledges the warning.
    if phase == .warning { set(.idle) }
    message = nil
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
  }

  @objc private func openConfig() { actions.openConfig() }
  @objc private func revealHistory() { actions.revealHistory() }
  @objc private func copyLast() { actions.copyLast() }
  @objc private func unloadModel() { actions.unloadModel() }
  @objc private func toggleLogin() { actions.toggleLaunchAtLogin() }
  @objc private func requestPermissions() { actions.requestPermissions() }
}
