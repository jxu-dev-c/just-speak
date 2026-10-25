import AppKit

/// just-speak's accent: a rose red that reads as "live" and stays clear of the orange used for warnings.
/// The app icon (scripts/make-icon.swift) spans the same hue as a coral → deep rose gradient.
enum Brand {
  static let accent = NSColor(name: "JustSpeakAccent") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 1.00, green: 0.42, blue: 0.50, alpha: 1)  // #FF6B80, lifted for dark backgrounds
      : NSColor(srgbRed: 0.91, green: 0.19, blue: 0.36, alpha: 1)  // #E8305C
  }
}
