import AppKit

/// Floating capsule near the bottom of the screen: level meter + "Listening…" while recording,
/// a spinner while processing. Transcript text is never shown. It never takes focus or intercepts
/// clicks, so typing into the target app is unaffected.
@MainActor
final class Pill {
  private enum Metrics {
    static let height: CGFloat = 36
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 420
    static let inset: CGFloat = 14
    static let iconWidth: CGFloat = 26
    static let gap: CGFloat = 8
    static let bottomOffset: CGFloat = 72
  }

  private lazy var panel: NSPanel = makePanel()
  private let meter = LevelMeter()
  private let spinner = NSProgressIndicator()
  private let checkmark = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private var hideWork: DispatchWorkItem?

  func showListening() {
    cancelHide()
    setIcon(meter)
    meter.reset()
    setText("Listening…", dim: false)
    present()
  }

  func setLevel(_ level: Float) {
    meter.push(level)
  }

  func showProcessing() {
    cancelHide()
    setIcon(spinner)
    spinner.startAnimation(nil)
    setText("Transcribing…", dim: true)
    present()
  }

  func showMessage(_ text: String, symbol: String = "exclamationmark.triangle.fill", color: NSColor = .systemOrange,
                   seconds: Double = 2.5) {
    setIcon(checkmark)
    checkmark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(paletteColors: [color]))
    setText(text, dim: false)
    present()
    hide(after: seconds)
  }

  func hide(after seconds: Double = 0) {
    cancelHide()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.spinner.stopAnimation(nil)
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.18
        self.panel.animator().alphaValue = 0
      }, completionHandler: {
        MainActor.assumeIsolated { if self.panel.alphaValue == 0 { self.panel.orderOut(nil) } }
      })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  // MARK: - Layout

  private func cancelHide() {
    hideWork?.cancel()
    hideWork = nil
  }

  private func setText(_ text: String, dim: Bool) {
    label.stringValue = text.replacingOccurrences(of: "\n", with: " ")
    label.textColor = dim ? .secondaryLabelColor : .labelColor
    layout()
  }

  private func setIcon(_ view: NSView) {
    for v in [meter, spinner, checkmark] as [NSView] { v.isHidden = v !== view }
    if view !== spinner { spinner.stopAnimation(nil) }
  }

  private func present() {
    layout()
    if !panel.isVisible || panel.alphaValue < 1 {
      panel.alphaValue = 1
      panel.orderFrontRegardless()
    }
  }

  private func layout() {
    let textWidth = min(label.intrinsicContentSize.width,
                        Metrics.maxWidth - 2 * Metrics.inset - Metrics.iconWidth - Metrics.gap)
    let width = max(Metrics.minWidth, ceil(textWidth) + 2 * Metrics.inset + Metrics.iconWidth + Metrics.gap)
    let h = Metrics.height
    // The screen with the mouse pointer, which is where the user is looking.
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + Metrics.bottomOffset, width: width, height: h)
    panel.setFrame(frame, display: true)

    let iconFrame = NSRect(x: Metrics.inset, y: (h - 18) / 2, width: Metrics.iconWidth, height: 18)
    meter.frame = iconFrame
    checkmark.frame = iconFrame.insetBy(dx: 4, dy: 0)
    spinner.frame = iconFrame.insetBy(dx: 4, dy: 0)
    let x = Metrics.inset + Metrics.iconWidth + Metrics.gap
    let labelHeight = label.intrinsicContentSize.height
    label.frame = NSRect(x: x, y: (h - labelHeight) / 2, width: width - x - Metrics.inset, height: labelHeight)
  }

  private func makePanel() -> NSPanel {
    let p = NonActivatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: Metrics.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .statusBar
    p.ignoresMouseEvents = true
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let bg = NSVisualEffectView()
    bg.material = .hudWindow
    bg.blendingMode = .behindWindow
    bg.state = .active
    bg.wantsLayer = true
    bg.layer?.cornerRadius = Metrics.height / 2
    bg.layer?.masksToBounds = true
    p.contentView = bg

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    checkmark.imageScaling = .scaleProportionallyUpOrDown
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    for v in [meter, spinner, checkmark, label] as [NSView] { bg.addSubview(v) }
    return p
  }
}

private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Five bars driven by the mic level, drawn with plain layers (no per-frame allocation).
@MainActor
private final class LevelMeter: NSView {
  private let bars = (0..<5).map { _ in CALayer() }
  private var level: CGFloat = 0
  // Fixed per-bar weights give the bars a voice-like shape instead of moving in lockstep.
  private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.5]

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for b in bars {
      b.backgroundColor = NSColor.systemRed.cgColor
      b.cornerRadius = 1.5
      layer?.addSublayer(b)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  func reset() {
    level = 0
    redraw()
  }

  /// `rms` is the raw RMS of the latest audio buffer (0…1).
  func push(_ rms: Float) {
    // Speech RMS is roughly 0.005–0.2; map to 0…1 on a log scale, rise fast, fall slowly.
    let db = 20 * log10(max(CGFloat(rms), 1e-5))
    let target = min(1, max(0, (db + 50) / 40))
    level = target > level ? target : level * 0.8 + target * 0.2
    redraw()
  }

  override func layout() {
    super.layout()
    redraw()
  }

  private func redraw() {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.08)
    let w: CGFloat = 3, gap: CGFloat = 2.5
    let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
    var x = (bounds.width - total) / 2
    for (b, weight) in zip(bars, weights) {
      let h = max(3, bounds.height * min(1, level * weight + 0.12))
      b.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
      x += w + gap
    }
    CATransaction.commit()
  }
}
