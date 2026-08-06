#!/usr/bin/env swift
// Generates the DMG installer window background (placeholder art).
// Usage: swift Dmg/CreateBackground.swift
// Output: Background.tiff (multi-representation 1x + 2x, via tiffutil)
//
// The geometry constants below MUST stay in sync with the `dmg` target in the
// Makefile: the window content size, the icon slot centers and the icon size
// are what make the drawn arrow line up between the two Finder icons.

import AppKit

// NSApplication must be initialized for font/symbol rendering in a script context.
_ = NSApplication.shared

// MARK: - Geometry (keep in sync with the Makefile `dmg` target)

let W: CGFloat = 700          // window content width  (DMG_WIN_W)
let H: CGFloat = 460          // window content height (DMG_WIN_H)
let iconSize: CGFloat = 128   // Finder icon size      (DMG_ICON_SIZE)

// Icon centers, expressed in Finder coordinates (origin top-left, y downward).
let appSlot  = CGPoint(x: 185, y: 215)   // (DMG_APP_X,  DMG_APP_Y)
let dropSlot = CGPoint(x: 515, y: 215)   // (DMG_DROP_X, DMG_DROP_Y)

// MARK: - Palette

// Light background: Finder renders icon labels in the *system* appearance, so a
// light canvas keeps them legible in the common (light) case. Swap this whole
// file — or point DMG_BACKGROUND at your own artwork — for custom branding.
let bgTop    = CGColor(red: 0.972, green: 0.976, blue: 0.992, alpha: 1)
let bgBottom = CGColor(red: 0.914, green: 0.925, blue: 0.960, alpha: 1)
let arrowGray = NSColor(calibratedRed: 0.58, green: 0.61, blue: 0.70, alpha: 1)
let titleGray = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1)
let hintGray  = NSColor(calibratedRed: 0.45, green: 0.48, blue: 0.56, alpha: 1)

// Brand glows, echoing the app icon's cobalt / violet nebulae.
struct Glow {
    let cx, cy: CGFloat   // center, fraction of canvas
    let radius: CGFloat   // radius, fraction of width
    let r, g, b, alpha: CGFloat
}

let glows: [Glow] = [
    Glow(cx: 0.16, cy: 0.78, radius: 0.55, r: 0.12, g: 0.22, b: 0.82, alpha: 0.10),
    Glow(cx: 0.86, cy: 0.24, radius: 0.50, r: 0.48, g: 0.08, b: 0.72, alpha: 0.08),
]

// MARK: - Helpers

/// Converts a Finder-style y (origin top-left) into Core Graphics y (origin bottom-left).
func flipY(_ y: CGFloat) -> CGFloat { H - y }

/// Draws a centered string at a Finder-style y baseline.
func drawCentered(_ text: String, font: NSFont, color: NSColor, topY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: (W - size.width) / 2, y: flipY(topY) - size.height))
}

// MARK: - Rendering

/// Renders the background into a bitmap of exactly `W*scale` x `H*scale` pixels.
///
/// - Note: an explicit `NSBitmapImageRep` is used rather than `NSImage.lockFocus`,
///   which would silently render at the current display's backing scale factor
///   and produce double-sized PNGs on a Retina machine.
func renderBackground(scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(W * scale)
    let pxH = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pxW, pixelsHigh: pxH,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pxW, height: pxH)   // 72 dpi; tiffutil tags the HiDPI pairing

    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let ctx = gctx.cgContext
    let cs = CGColorSpaceCreateDeviceRGB()

    // Work in logical points from here on; the scale factor handles @2x.
    ctx.scaleBy(x: scale, y: scale)

    // ── 1. Base vertical gradient ─────────────────────────────────────────
    if let grad = CGGradient(colorsSpace: cs,
                             colors: [bgTop, bgBottom] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: H),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])
    }

    // ── 2. Soft brand glows ───────────────────────────────────────────────
    for glow in glows {
        let center = CGPoint(x: glow.cx * W, y: glow.cy * H)
        let inner  = CGColor(red: glow.r, green: glow.g, blue: glow.b, alpha: glow.alpha)
        let outer  = CGColor(red: glow.r, green: glow.g, blue: glow.b, alpha: 0)
        guard let grad = CGGradient(colorsSpace: cs,
                                    colors: [inner, outer] as CFArray,
                                    locations: [0, 1]) else { continue }
        ctx.drawRadialGradient(grad,
                               startCenter: center, startRadius: 0,
                               endCenter:   center, endRadius:   glow.radius * W,
                               options: [])
    }

    // ── 3. Drag arrow, spanning the gap between the two icon slots ────────
    let gapLeft  = appSlot.x  + iconSize / 2
    let gapRight = dropSlot.x - iconSize / 2
    let inset: CGFloat = 34                       // breathing room around the icons
    let x0 = gapLeft + inset
    let x1 = gapRight - inset
    let y  = flipY((appSlot.y + dropSlot.y) / 2)

    ctx.saveGState()
    ctx.setStrokeColor(arrowGray.cgColor)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let headLength: CGFloat = 20
    let headSpread: CGFloat = 15

    // Shaft (stops short of the head so the round cap does not thicken the tip)
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1 - headLength * 0.5, y: y))
    ctx.strokePath()

    // Head
    ctx.move(to: CGPoint(x: x1 - headLength, y: y + headSpread))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - headLength, y: y - headSpread))
    ctx.strokePath()
    ctx.restoreGState()

    // ── 4. Title and hint ─────────────────────────────────────────────────
    drawCentered("Space Rabbit",
                 font: .systemFont(ofSize: 26, weight: .semibold),
                 color: titleGray,
                 topY: 46)

    drawCentered("Drag the app onto the Applications folder to install",
                 font: .systemFont(ofSize: 13, weight: .regular),
                 color: hintGray,
                 topY: 84)

    return rep
}

// MARK: - PNG export

func savePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "create_background", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG export failed: \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

do {
    let fm = FileManager.default
    let one = "Background.png"
    let two = "Background@2x.png"

    try savePNG(renderBackground(scale: 1), to: one)
    try savePNG(renderBackground(scale: 2), to: two)

    // tiffutil packs both scales into a single HiDPI-aware TIFF that Finder
    // resolves per-display — same trick Xcode uses for @2x assets.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
    proc.arguments = ["-cathidpicheck", one, two, "-out", "Background.tiff"]
    proc.standardOutput = FileHandle.nullDevice
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        fputs("tiffutil failed\n", stderr)
        exit(1)
    }

    try? fm.removeItem(atPath: one)
    try? fm.removeItem(atPath: two)
    print("Created Background.tiff (\(Int(W))x\(Int(H)) @1x + @2x)")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
