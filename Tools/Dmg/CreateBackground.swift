#!/usr/bin/env swift
// Generates the DMG installer window background.
// Usage: swift Tools/Dmg/CreateBackground.swift [source.png]
// Output: Background.tiff (multi-representation 1x + 2x, via tiffutil)
//
// With no argument the placeholder art below is drawn programmatically. Pass a
// PNG to use custom artwork instead: it must be 1400x920 px (@2x, preferred) or
// 700x460 px (@1x); the other scale is resampled from it and nothing is drawn on
// top — the artwork is expected to carry its own arrow and wording.
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
let appSlot  = CGPoint(x: 185, y: 250)   // (DMG_APP_X,  DMG_APP_Y)
let dropSlot = CGPoint(x: 515, y: 250)   // (DMG_DROP_X, DMG_DROP_Y)

// MARK: - Palette

// Dark canvas, matching the shipped artwork. Note that Finder renders the icon
// labels in the *system* appearance, so they are near-black (and hard to read)
// for light-mode users — a deliberate trade for the brand look.
let bgTop    = CGColor(red: 0.043, green: 0.043, blue: 0.063, alpha: 1)
let bgBottom = CGColor(red: 0.075, green: 0.067, blue: 0.106, alpha: 1)

// The overlay (subtitle + drag arrow) is drawn over both the placeholder art and
// any custom PNG, so it stays plain white to read against a dark canvas.
let overlayWhite = NSColor.white

// Finder draws the icon labels in the *system* text color — near-black for
// light-mode users, and there is no Finder property to override it. A translucent
// plate is drawn behind each label so it stays legible on dark artwork.
//
// Finder owns the actual label layout, so the plate is positioned to match what it
// renders: `labelFontSize` mirrors the `text size` set in Layout.applescript, and
// `labelBaselineGap` (icon bottom edge → text baseline) was measured off a real
// mount. The plate then centers on the text's *optical* center — the midpoint of
// the cap-height band, half a cap above the baseline — rather than on the font's
// full line box, which would hang the plate low by reserving descender space that
// most of the glyphs do not use.
let plateFill = NSColor(calibratedWhite: 1, alpha: 0.90)
let labelFontSize: CGFloat    = 13
let labelBaselineGap: CGFloat = 24
let platePadX: CGFloat     = 10   // horizontal breathing room around the text
let platePadY: CGFloat     = 4
let plateRadius: CGFloat   = 7

// The label text is what Finder shows under each slot — the app bundle's display
// name and the drop target's — and it sets the plate widths.
let appLabel  = "Space Rabbit"
let dropLabel = "Applications"

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

    drawOverlay(ctx)
    return rep
}

/// Draws the subtitle and the drag arrow — the parts that must appear regardless
/// of whether the canvas is the placeholder art or a custom PNG.
///
/// The app name is deliberately NOT drawn: the shipped artwork bakes its own
/// title in, and a second one would collide with it.
///
/// - Parameter ctx: a context already scaled to logical points.
func drawOverlay(_ ctx: CGContext) {
    // ── Plates behind the icon labels ─────────────────────────────────────
    let labelFont = NSFont.systemFont(ofSize: labelFontSize)
    for (slot, label) in [(appSlot, appLabel), (dropSlot, dropLabel)] {
        let text = NSAttributedString(string: label, attributes: [.font: labelFont])
        let size = text.size()
        let baseline = slot.y + iconSize / 2 + labelBaselineGap
        let centerY = flipY(baseline - labelFont.capHeight / 2)
        let rect = CGRect(x: slot.x - size.width / 2 - platePadX,
                          y: centerY - size.height / 2 - platePadY,
                          width: size.width + platePadX * 2,
                          height: size.height + platePadY * 2)

        ctx.saveGState()
        ctx.setFillColor(plateFill.cgColor)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: plateRadius, cornerHeight: plateRadius,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // ── Drag arrow, spanning the gap between the two icon slots ───────────
    let gapLeft  = appSlot.x  + iconSize / 2
    let gapRight = dropSlot.x - iconSize / 2
    let inset: CGFloat = 34                       // breathing room around the icons
    let x0 = gapLeft + inset
    let x1 = gapRight - inset
    let y  = flipY((appSlot.y + dropSlot.y) / 2)

    ctx.saveGState()
    ctx.setStrokeColor(overlayWhite.cgColor)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let headLength: CGFloat = 20
    let headSpread: CGFloat = 15

    // Shaft and chevron are one continuous stroke: the shaft runs all the way to
    // the tip and the chevron pivots on that same point, so the round join welds
    // them into a single shape instead of leaving a notch between the two.
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - headLength, y: y + headSpread))
    ctx.move(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - headLength, y: y - headSpread))
    ctx.strokePath()
    ctx.restoreGState()

    // ── Subtitle, sitting under the title baked into the artwork ──────────
    drawCentered("Drag the app onto the Applications folder to install:",
                 font: .systemFont(ofSize: 15, weight: .regular),
                 color: overlayWhite,
                 topY: 102)
}

// MARK: - Custom artwork

/// Loads a custom background PNG and checks it matches the installer window.
///
/// - Parameter path: path to the source PNG.
/// - Returns: the loaded bitmap, guaranteed to be @1x or @2x of `W` x `H`.
func loadArtwork(_ path: String) throws -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else {
        throw NSError(domain: "create_background", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot read PNG: \(path)"])
    }

    // pixelsWide/High is the real pixel count; `size` carries the PNG's dpi tag,
    // which authoring tools set inconsistently and which we do not care about.
    let expected = [(Int(W * 2), Int(H * 2)), (Int(W), Int(H))]
    guard expected.contains(where: { $0 == (rep.pixelsWide, rep.pixelsHigh) }) else {
        let want = expected.map { "\($0.0)x\($0.1)" }.joined(separator: " or ")
        throw NSError(domain: "create_background", code: 3, userInfo: [
            NSLocalizedDescriptionKey:
                "\(path) is \(rep.pixelsWide)x\(rep.pixelsHigh) px, expected \(want) px",
        ])
    }
    return rep
}

/// Resamples `artwork` into a bitmap of exactly `W*scale` x `H*scale` pixels.
///
/// - Note: a same-scale source is still redrawn — that normalizes the color space
///   and dpi tag so both representations pair cleanly in the HiDPI TIFF.
func renderArtwork(_ artwork: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(W * scale)
    let pxH = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pxW, pixelsHigh: pxH,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pxW, height: pxH)   // 72 dpi; tiffutil tags the pairing

    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    gctx.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pxW, height: pxH),
                 from: .zero, operation: .copy, fraction: 1,
                 respectFlipped: true, hints: nil)

    // The overlay is drawn on top rather than baked into the source PNG, so the
    // arrow keeps tracking the icon slots if the layout constants ever move.
    gctx.cgContext.scaleBy(x: scale, y: scale)
    drawOverlay(gctx.cgContext)
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
    // Scratch scale representations, fed to tiffutil and deleted right after.
    // Deliberately not named Background*.png: running from Tools/Dmg would then
    // clobber the BaseBackground.png source sitting next to them.
    let one = "_scale1x.png"
    let two = "_scale2x.png"

    // A source PNG replaces the drawn placeholder entirely.
    let source = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
    let artwork = try source.map(loadArtwork)

    try savePNG(artwork.map { renderArtwork($0, scale: 1) } ?? renderBackground(scale: 1), to: one)
    try savePNG(artwork.map { renderArtwork($0, scale: 2) } ?? renderBackground(scale: 2), to: two)

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
    let origin = source.map { "from \($0)" } ?? "placeholder art"
    print("Created Background.tiff (\(Int(W))x\(Int(H)) @1x + @2x, \(origin))")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
