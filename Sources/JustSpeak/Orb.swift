import AppKit
import SwiftUI

/// A small glass orb floating near the bottom of the screen: a band of light that swells with the voice
/// while recording and narrows and breathes while processing. It springs in, and dissolves when done
/// (the light goes out first, then the glass sinks away). No words, except a caption for errors. It never
/// takes focus or intercepts clicks, so typing into the target app is unaffected.
@MainActor
final class Orb {
  private enum Metrics {
    /// Fixed and transparent: room for the glow, the entrance overshoot and an error caption above.
    static let canvas = NSSize(width: 460, height: 160)
    /// From the bottom of the visible frame to the bottom of the canvas.
    static let bottomOffset: CGFloat = 36
    static let exitDuration = 0.5
  }

  private let model = OrbModel()
  private lazy var panel: NSPanel = makePanel()
  private var hideWork: DispatchWorkItem?

  func showListening() {
    set(mode: .listening, caption: nil)
    model.dynamics.resetLevel()
    present()
  }

  func setLevel(_ level: Float) {
    model.dynamics.push(level)
  }

  func showProcessing() {
    set(mode: .processing, caption: nil)
    present()
  }

  func showMessage(_ text: String, color: NSColor = .systemOrange, seconds: Double = 2.5) {
    model.dynamics.tint = color
    set(mode: .message, caption: text.replacingOccurrences(of: "\n", with: " "))
    present()
    hide(after: seconds)
  }

  /// A small "no" shake, then gone: the recording had no speech in it.
  func shakeOff() {
    set(mode: .listening, caption: nil)
    present()
    model.dynamics.shake(at: Self.now)
    hide(after: 0.6)
  }

  func hide(after seconds: Double = 0) {
    cancelHide()
    let exit = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.model.dynamics.exit(at: Self.now)
      withAnimation(.easeIn(duration: 0.25)) { self.model.caption = nil }
      let orderOut = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.panel.orderOut(nil)
        self.model.running = false
      }
      self.hideWork = orderOut
      DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.exitDuration, execute: orderOut)
    }
    hideWork = exit
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: exit)
  }

  // MARK: - Presentation

  /// The clock TimelineView dates are on.
  private static var now: Double { Date().timeIntervalSinceReferenceDate }

  private func cancelHide() {
    hideWork?.cancel()
    hideWork = nil
  }

  private func set(mode: OrbDynamics.Mode, caption: String?) {
    cancelHide()
    model.dynamics.mode = mode
    if caption != model.caption {
      withAnimation(.spring(duration: 0.4, bounce: 0.2)) { model.caption = caption }
    }
  }

  private func present() {
    if !panel.isVisible {
      // The screen with the mouse pointer, which is where the user is looking.
      let mouse = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
      let visible = screen?.visibleFrame ?? .zero
      panel.setFrameOrigin(NSPoint(x: (visible.midX - Metrics.canvas.width / 2).rounded(),
                                   y: visible.minY + Metrics.bottomOffset))
      panel.orderFrontRegardless()
    }
    if !model.dynamics.isPresent { model.dynamics.enter(at: Self.now) }
    model.running = true
  }

  private func makePanel() -> NSPanel {
    let p = NonActivatingPanel(
      contentRect: NSRect(origin: .zero, size: Metrics.canvas),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false  // the orb draws its own; a window shadow would trace the empty canvas
    p.level = .statusBar
    p.ignoresMouseEvents = true
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let host = NSHostingView(rootView: OrbScene(model: model))
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: Metrics.canvas)
    p.contentView = host
    return p
  }

  // MARK: - Snapshot

  /// Renders the orb mid-sentence centered on a gradient backdrop at 2x, for the README
  /// (`just-speak render-orb`).
  static func renderSnapshot(backdrop: (NSColor, NSColor), canvas: NSSize, level: Double) -> NSBitmapImageRep? {
    var frame = OrbFrame()
    frame.level = level
    frame.time = 0.4
    frame.spin = 0.3
    let scene = ZStack {
      LinearGradient(colors: [Color(nsColor: backdrop.0), Color(nsColor: backdrop.1)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
      OrbFace(frame: frame)
    }
    .frame(width: canvas.width, height: canvas.height)
    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    return renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
  }
}

private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - Motion

/// What the view needs to draw one frame.
struct OrbFrame {
  /// 0 gone … 1 shown; springs a little past 1 on the way in.
  var presence = 1.0
  /// Smoothed voice level, 0…1.
  var level = 0.0
  /// 0 listening … 1 processing, eased so the light morphs between the two.
  var thinking = 0.0
  /// Rim rotation in radians, integrated so a change of speed never makes it jump.
  var spin = 0.0
  var time = 0.0
  /// Horizontal offset of the "no speech" shake, in points.
  var shake = 0.0
  var bandColor = Color.white
  /// 1 for the white light; fades the warm and cool fringes out under a tint.
  var fringe = 1.0
}

/// Owns every moving value and advances it per display frame. Doing this by hand rather than with
/// SwiftUI animations keeps mode changes continuous: a new target is eased toward from wherever things are.
@MainActor
final class OrbDynamics {
  enum Mode { case listening, processing, message }

  var mode = Mode.listening
  var tint = NSColor.systemOrange
  private var targetLevel = 0.0
  private var current = OrbFrame(presence: 0)
  private var last: Double?
  private var enterAt: Double?, enterFrom = 0.0
  private var exitAt: Double?, exitFrom = 0.0
  private var shakeAt: Double?
  private var tintAmount = 0.0

  /// Shown, or on its way in; false once an exit has started.
  var isPresent: Bool { enterAt != nil && exitAt == nil }

  func enter(at t: Double) {
    enterFrom = exitAt == nil ? 0 : current.presence
    enterAt = t
    exitAt = nil
    if enterFrom < 0.05 {
      // Coming from nothing: start in the new mode's look instead of morphing from the last one.
      current.thinking = mode == .processing ? 1 : 0
      tintAmount = mode == .message ? 1 : 0
    }
  }

  func exit(at t: Double) {
    guard exitAt == nil else { return }
    exitFrom = current.presence
    exitAt = t
    enterAt = nil
  }

  func shake(at t: Double) { shakeAt = t }

  func resetLevel() {
    targetLevel = 0
    current.level = 0
  }

  /// `rms` is the raw RMS of the latest audio buffer (0…1).
  func push(_ rms: Float) {
    // Speech RMS is roughly 0.005–0.2; map to 0…1 on a log scale.
    let db = 20 * log10(max(Double(rms), 1e-5))
    targetLevel = min(1, max(0, (db + 50) / 40))
  }

  func step(to t: Double) -> OrbFrame {
    let dt = min(max(t - (last ?? t), 0), 1.0 / 20)
    last = t
    var f = current
    f.time = t

    if let enterAt {
      // An underdamped spring's step response: overshoots about 10% and settles in half a second.
      let tau = t - enterAt, zeta = 0.55, omega = 14.0
      let wd = omega * (1 - zeta * zeta).squareRoot()
      let s = 1 - exp(-zeta * omega * tau) * (cos(wd * tau) + zeta * omega / wd * sin(wd * tau))
      f.presence = enterFrom + (1 - enterFrom) * s
    } else if let exitAt {
      f.presence = exitFrom * (1 - smoothstep(0, 0.45, t - exitAt))
    }

    // Rise quickly with the voice, fall away slowly.
    let level = mode == .listening ? targetLevel : 0
    f.level += (level - f.level) * (1 - exp(-dt * (level > f.level ? 28 : 7)))
    f.thinking += ((mode == .processing ? 1 : 0) - f.thinking) * (1 - exp(-dt * 5))
    tintAmount += ((mode == .message ? 1 : 0) - tintAmount) * (1 - exp(-dt * 6))
    f.spin += dt * (0.5 + 2.6 * f.thinking + 1.2 * f.level)

    if let shakeAt, t - shakeAt < 0.8 {
      let tau = t - shakeAt
      f.shake = sin(tau * 36) * 6 * exp(-tau * 6)
    } else {
      f.shake = 0
    }

    let band = NSColor.white.blended(withFraction: tintAmount * 0.85, of: tint) ?? .white
    f.bandColor = Color(nsColor: band)
    f.fringe = 1 - tintAmount
    current = f
    return f
  }
}

@MainActor @Observable
final class OrbModel {
  /// Drives the display-rate timeline; false while the panel is off screen.
  var running = false
  var caption: String?
  @ObservationIgnored let dynamics = OrbDynamics()
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
  let u = min(1, max(0, (x - a) / (b - a)))
  return u * u * (3 - 2 * u)
}

// MARK: - Views

private struct OrbScene: View {
  let model: OrbModel

  var body: some View {
    TimelineView(.animation(paused: !model.running)) { timeline in
      let frame = model.dynamics.step(to: timeline.date.timeIntervalSinceReferenceDate)
      VStack(spacing: 2) {
        if let caption = model.caption {
          Text(caption)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.06).opacity(0.86)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .opacity(min(1, frame.presence))
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        }
        OrbFace(frame: frame)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
  }
}

/// The orb itself: dark glass, a band of light across the middle with warm and cool fringes, and an
/// iridescent rim that slowly turns.
struct OrbFace: View {
  static let diameter: CGFloat = 46
  let frame: OrbFrame

  private static let warm = Color(red: 1.0, green: 0.80, blue: 0.62)
  private static let cool = Color(red: 0.52, green: 0.72, blue: 1.0)
  private static let rim = Gradient(stops: [
    .init(color: warm.opacity(0.95), location: 0),
    .init(color: .white.opacity(0.5), location: 0.08),
    .init(color: .clear, location: 0.2),
    .init(color: .clear, location: 0.3),
    .init(color: cool.opacity(0.95), location: 0.42),
    .init(color: .white.opacity(0.85), location: 0.5),
    .init(color: Color(red: 0.62, green: 1.0, blue: 0.82).opacity(0.6), location: 0.58),
    .init(color: .clear, location: 0.7),
    .init(color: .clear, location: 0.86),
    .init(color: warm.opacity(0.95), location: 1),
  ])

  var body: some View {
    let d = Self.diameter
    let f = frame
    let t = f.time
    let p = f.presence
    // The light comes on after the glass appears and goes out before it leaves.
    let light = smoothstep(0.35, 1, p)
    let voice = f.level
    let breathe = 0.5 + 0.5 * sin(t * 4.2)
    let flicker = voice * (0.05 * sin(t * 13.7) + 0.035 * sin(t * 22.3))
    // A thin streak at rest that stretches toward the rim and brightens with the voice; while thinking it
    // narrows and breathes.
    let bandWidth = d * (0.7 + 0.24 * voice + flicker) * (1 - f.thinking * (0.42 - 0.22 * breathe))
      * (0.15 + 0.85 * light)
    let bandHeight = d * (0.06 + 0.05 * voice) * (1 + 0.6 * f.thinking * breathe)
    let tilt = -5 + 3 * sin(t * 1.1) + 16 * f.thinking * sin(t * 1.9)
    let glow = min(1, 0.35 + 0.65 * voice + f.thinking * (0.25 + 0.3 * breathe)) * light
    let scale = (0.3 + 0.7 * p) * (1 + 0.05 * voice)

    ZStack {
      // Halo, and a soft shadow so the orb holds up on light backgrounds.
      Circle()
        .fill(RadialGradient(colors: [f.bandColor.opacity(0.22), .clear], center: .center,
                             startRadius: d * 0.3, endRadius: d * 1.05))
        .frame(width: d * 2.1, height: d * 2.1)
        .opacity(glow)
      Circle()
        .fill(.black.opacity(0.4))
        .frame(width: d, height: d)
        .blur(radius: 8)
        .offset(y: 4)

      ZStack {
        RadialGradient(colors: [Color(white: 0.2), Color(white: 0.07), Color(white: 0.03)],
                       center: UnitPoint(x: 0.5, y: 0.85), startRadius: 0, endRadius: d * 0.8)
        // Haze the light spreads into the glass.
        Ellipse()
          .fill(f.bandColor.opacity(0.06 + 0.2 * glow))
          .frame(width: d * 0.95, height: d * (0.32 + 0.14 * voice))
          .blur(radius: d * 0.12)
        band(width: bandWidth, height: bandHeight, glow: glow)
          .rotationEffect(.degrees(tilt))
          .opacity(light)
        // Refraction just inside the edge.
        Circle()
          .strokeBorder(.white.opacity(0.1), lineWidth: 2.5)
          .blur(radius: 1.5)
      }
      .frame(width: d, height: d)
      .clipShape(Circle())

      // Iridescent rim with a little bloom, plus a glint along the top.
      let rim = AngularGradient(gradient: Self.rim, center: .center, angle: .radians(f.spin))
      Circle()
        .strokeBorder(rim, lineWidth: 2.4)
        .blur(radius: 2)
        .opacity(0.35 + 0.5 * glow)
        .blendMode(.plusLighter)
        .frame(width: d, height: d)
      Circle()
        .strokeBorder(rim, lineWidth: 1)
        .opacity(0.55 + 0.45 * glow)
        .frame(width: d, height: d)
      Circle()
        .trim(from: 0.62, to: 0.88)
        .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        .frame(width: d - 3, height: d - 3)
        .blur(radius: 0.4)
    }
    .frame(width: d * 2.2, height: d * 2.2)
    .scaleEffect(scale)
    .blur(radius: (1 - min(p, 1)) * 6)
    .opacity(smoothstep(0, 0.5, p))
    .offset(x: f.shake, y: (1 - min(p, 1)) * 14)
  }

  /// A lens-shaped streak: warm above, cool below, a white-hot core, all fading out toward the ends.
  private func band(width w: CGFloat, height h: CGFloat, glow: Double) -> some View {
    let fade = { (color: Color) in
      LinearGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.5),
                             .init(color: color.opacity(0), location: 1)],
                     startPoint: .leading, endPoint: .trailing)
    }
    return ZStack {
      Ellipse()
        .fill(fade(Self.warm))
        .frame(width: w * 0.85, height: h * 1.2)
        .offset(x: -w * 0.06, y: -h * 0.45)
        .blur(radius: h * 0.45)
        .opacity(frame.fringe * 0.9)
      Ellipse()
        .fill(fade(Self.cool))
        .frame(width: w * 0.85, height: h * 1.2)
        .offset(x: w * 0.06, y: h * 0.45)
        .blur(radius: h * 0.45)
        .opacity(frame.fringe * 0.9)
      Ellipse()
        .fill(fade(frame.bandColor))
        .frame(width: w * 1.05, height: h * 1.7)
        .blur(radius: h * 0.7)
        .opacity(0.3 + 0.35 * glow)
      Ellipse()
        .fill(fade(frame.bandColor))
        .frame(width: w, height: h * 0.55)
        .blur(radius: h * 0.15)
    }
    .compositingGroup()
    .blendMode(.plusLighter)
  }
}
