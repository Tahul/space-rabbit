#!/usr/bin/env swift
// Generates AppIcon.icns from the SF Symbol "hare.fill".
// Usage: swift create_icon.swift
// Output: AppIcon.icns (AppIcon.iconset/ is removed when done)

import AppKit

// NSApplication must be initialized for SF Symbols to load in a script context.
_ = NSApplication.shared

// MARK: - Config

let symbolName = "hare.fill"

// MARK: - Iconset slot definitions

struct Slot {
    let logical: Int   // logical size in points
    let scale:   Int   // 1x or 2x
    var pixels:  Int  { logical * scale }
    var filename: String {
        scale > 1
            ? "icon_\(logical)x\(logical)@\(scale)x.png"
            : "icon_\(logical)x\(logical).png"
    }
}

let slots: [Slot] = [
    Slot(logical: 16,  scale: 1), Slot(logical: 16,  scale: 2),
    Slot(logical: 32,  scale: 1), Slot(logical: 32,  scale: 2),
    Slot(logical: 128, scale: 1), Slot(logical: 128, scale: 2),
    Slot(logical: 256, scale: 1), Slot(logical: 256, scale: 2),
    Slot(logical: 512, scale: 1), Slot(logical: 512, scale: 2),
]

// MARK: - Space background helpers

struct Nebula {
    let cx, cy: CGFloat   // center as fraction of icon size
    let radius: CGFloat   // radius as fraction of icon size
    let r, g, b: CGFloat
    let alpha: CGFloat
}

// Radial glows inspired by deep blue / purple / crimson / warm-gold palette
let nebulae: [Nebula] = [
    // rich cobalt blue, upper half
    Nebula(cx: 0.50, cy: 0.72, radius: 0.68, r: 0.12, g: 0.22, b: 0.82, alpha: 0.85),
    // deep purple/violet, right side
    Nebula(cx: 0.75, cy: 0.38, radius: 0.58, r: 0.48, g: 0.08, b: 0.72, alpha: 0.80),
    // crimson red, lower-left
    Nebula(cx: 0.18, cy: 0.22, radius: 0.55, r: 0.72, g: 0.08, b: 0.12, alpha: 0.75),
]

// MARK: - Rendering

func renderIcon(pixels px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    defer { img.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let cs = CGColorSpaceCreateDeviceRGB()

    // Clip to rounded-rect (macOS app-icon corner ≈ 22% of size)
    let radius = s * 0.22
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // ── 1. Deep space background ──────────────────────────────────────────
    ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.10, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // ── 2. Nebula radial glows (screen blend for additive light feel) ─────
    for neb in nebulae {
        let center = CGPoint(x: neb.cx * s, y: neb.cy * s)
        let rad    = neb.radius * s
        let inner  = CGColor(red: neb.r, green: neb.g, blue: neb.b, alpha: neb.alpha)
        let outer  = CGColor(red: neb.r, green: neb.g, blue: neb.b, alpha: 0)
        guard let grad = CGGradient(colorsSpace: cs,
                                    colors: [inner, outer] as CFArray,
                                    locations: [0, 1]) else { continue }
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(grad,
                               startCenter: center, startRadius: 0,
                               endCenter:   center, endRadius:   rad,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // ── 3. SF Symbol with volume ──────────────────────────────────────────
    ctx.setBlendMode(.normal)
    let symPt = s * 0.45
    let cfg = NSImage.SymbolConfiguration(pointSize: symPt, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Space Rabbit")?
                     .withSymbolConfiguration(cfg),
       let cgSym = sym.cgImage(forProposedRect: nil, context: nil, hints: nil) {

        let symW = sym.size.width
        let symH = sym.size.height
        let symX = (s - symW) / 2
        let symY = (s - symH) / 2
        let symRect = CGRect(x: symX, y: symY, width: symW, height: symH)

        // Transparency layer so the drop shadow is cast from the whole shape, not each fill call
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: s * 0.006, height: -s * 0.012),
                      blur:   s * 0.022,
                      color:  CGColor(red: 0.0, green: 0.0, blue: 0.20, alpha: 0.40))
        ctx.beginTransparencyLayer(in: symRect, auxiliaryInfo: nil)

        // Clip drawing to the symbol's alpha footprint
        ctx.clip(to: symRect, mask: cgSym)

        // Primary gradient: bright white at top → cool periwinkle at bottom
        // Simulates overhead light hitting the rabbit's back/ears
        let gTop  = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)  // pure highlight
        let gMid  = CGColor(red: 0.88, green: 0.93, blue: 1.00, alpha: 1.0)  // soft blue-white
        let gBot  = CGColor(red: 0.60, green: 0.76, blue: 1.00, alpha: 1.0)  // periwinkle shadow
        if let grad = CGGradient(colorsSpace: cs,
                                 colors: [gTop, gMid, gBot] as CFArray,
                                 locations: [0.0, 0.45, 1.0]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: symX + symW / 2, y: symY + symH),
                                   end:   CGPoint(x: symX + symW / 2, y: symY),
                                   options: [])
        }

        // Specular rim: a second radial glow from upper-left corner of the symbol
        // gives the impression of a convex 3-D surface catching light
        let rimCenter = CGPoint(x: symX + symW * 0.30, y: symY + symH * 0.82)
        let rimInner  = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.55)
        let rimOuter  = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
        if let rimGrad = CGGradient(colorsSpace: cs,
                                    colors: [rimInner, rimOuter] as CFArray,
                                    locations: [0, 1]) {
            ctx.drawRadialGradient(rimGrad,
                                   startCenter: rimCenter, startRadius: 0,
                                   endCenter:   rimCenter, endRadius:   symW * 0.55,
                                   options: [.drawsAfterEndLocation])
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    return img
}

// MARK: - PNG export

func savePNG(_ img: NSImage, to path: String) throws {
    guard let tiff   = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png    = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "create_icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG export failed: \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

do {
    let iconset = "AppIcon.iconset"
    let fm = FileManager.default
    try? fm.removeItem(atPath: iconset)
    try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

    for slot in slots {
        let path = "\(iconset)/\(slot.filename)"
        try savePNG(renderIcon(pixels: slot.pixels), to: path)
        print("  \(slot.filename)  (\(slot.pixels)px)")
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        fputs("iconutil failed\n", stderr)
        exit(1)
    }

    try? fm.removeItem(atPath: iconset)
    print("Created AppIcon.icns")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
