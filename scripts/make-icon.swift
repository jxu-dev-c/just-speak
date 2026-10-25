// Renders the app icon: a white waveform running into a text caret, on the brand gradient.
// Writes <out>/AppIcon.icns (bundled by build-app.sh) and <out>/icon.png (README).
//
//   swift scripts/make-icon.swift Resources
//
// Colors match Sources/JustSpeak/Brand.swift; keep the two in sync.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let gradientTop = rgb(0xFF6B5A)     // coral
let gradientBottom = rgb(0xD81E5B)  // deep rose
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Glyph geometry in 1024-grid units.
struct Glyph {
  var weights: [CGFloat], bar: CGFloat, gap: CGFloat, maxHeight: CGFloat
  var caretGap: CGFloat, stem: CGFloat, caret: CGFloat, serif: CGFloat, serifHeight: CGFloat
}

/// Draws on Apple's 1024 icon grid (824pt body, 100pt margin) scaled to `px` pixels.
func render(px: Int) -> CGImage {
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
  ctx.interpolationQuality = .high
  let detailed = px >= 64  // shadows turn to mud at menu/list sizes

  let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                    cornerWidth: 185, cornerHeight: 185, transform: nil)

  // Drop shadow under the body.
  ctx.saveGState()
  if detailed { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3)) }
  ctx.addPath(body)
  ctx.setFillColor(gradientBottom)
  ctx.fillPath()
  ctx.restoreGState()

  // Body: diagonal gradient plus a soft light from the top.
  ctx.saveGState()
  ctx.addPath(body)
  ctx.clip()
  let fill = CGGradient(colorsSpace: space, colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(fill, start: CGPoint(x: 220, y: 924), end: CGPoint(x: 804, y: 100), options: [])
  let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                        locations: [0, 1])!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 980), endRadius: 640, options: [])
  ctx.restoreGState()

  // Glyph: a voice waveform running into a text caret (speech becomes text where the cursor is).
  // Small sizes get fewer, chunkier strokes so the caret survives at 16 px.
  let g = px <= 32
    ? Glyph(weights: [0.5, 1.0], bar: 150, gap: 90, maxHeight: 520, caretGap: 120, stem: 84, caret: 560,
            serif: 230, serifHeight: 84)
    : Glyph(weights: [0.45, 0.8, 1.0, 0.65], bar: 72, gap: 42, maxHeight: 430, caretGap: 64, stem: 34, caret: 480,
            serif: 104, serifHeight: 34)
  let total = CGFloat(g.weights.count) * (g.bar + g.gap) - g.gap + g.caretGap + g.serif
  ctx.saveGState()
  if detailed { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x7A0A2E, 0.35)) }
  ctx.setFillColor(rgb(0xFFFFFF))
  func capsule(_ r: CGRect) {
    let radius = min(r.width, r.height) / 2
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
  }
  var x = 512 - total / 2
  for w in g.weights {
    let h = g.maxHeight * w
    capsule(CGRect(x: x, y: 512 - h / 2, width: g.bar, height: h))
    x += g.bar + g.gap
  }
  x += g.caretGap - g.gap
  capsule(CGRect(x: x + (g.serif - g.stem) / 2, y: 512 - g.caret / 2, width: g.stem, height: g.caret))
  capsule(CGRect(x: x, y: 512 + g.caret / 2 - g.serifHeight, width: g.serif, height: g.serifHeight))
  capsule(CGRect(x: x, y: 512 - g.caret / 2, width: g.serif, height: g.serifHeight))
  ctx.fillPath()
  ctx.restoreGState()

  return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for pt in [16, 32, 128, 256, 512] {
  writePNG(render(px: pt), to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
  writePNG(render(px: pt * 2), to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
writePNG(render(px: 512), to: out.appendingPathComponent("icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)/AppIcon.icns and icon.png")
