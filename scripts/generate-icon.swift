#!/usr/bin/env swift

import AppKit
import Foundation

// Draws the tinyClicker app icon at every macOS-required pixel size,
// then packages them into Resources/icon.icns via `iconutil`.

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high
    gctx.shouldAntialias = true

    let s = CGFloat(pixels)
    let bgRect = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.225 // macOS squircle approximation

    // ── Background ──────────────────────────────────────────────────────
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    bgPath.addClip()

    // Apple-style indigo → purple, diagonal
    let topColor = NSColor(srgbRed: 88/255,  green: 86/255,  blue: 214/255, alpha: 1.0) // systemIndigo
    let botColor = NSColor(srgbRed: 175/255, green: 82/255,  blue: 222/255, alpha: 1.0) // systemPurple
    if let gradient = NSGradient(starting: topColor, ending: botColor) {
        gradient.draw(in: bgRect, angle: 135)
    }

    // Soft top highlight for depth
    if let sheen = NSGradient(
        colors: [
            NSColor(white: 1.0, alpha: 0.18),
            NSColor(white: 1.0, alpha: 0.0),
        ]
    ) {
        sheen.draw(in: bgRect, angle: 270)
    }
    NSGraphicsContext.restoreGraphicsState()

    // ── Cursor tip anchor (Cocoa coords — origin bottom-left) ──────────
    let tipX = s * 0.36
    let tipY = s * 0.72

    // ── Ripples (sonar pings emanating from the click point) ───────────
    // Skip ripples below 32px — too small to render cleanly.
    if pixels >= 32 {
        let ripples: [(radius: CGFloat, alpha: CGFloat, lineWidth: CGFloat)] = [
            (s * 0.18, 0.55, s * 0.022),
            (s * 0.28, 0.32, s * 0.020),
            (s * 0.38, 0.16, s * 0.018),
        ]
        for ring in ripples {
            let rect = NSRect(
                x: tipX - ring.radius,
                y: tipY - ring.radius,
                width: ring.radius * 2,
                height: ring.radius * 2
            )
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = max(0.75, ring.lineWidth)
            NSColor(white: 1.0, alpha: ring.alpha).setStroke()
            path.stroke()
        }
    }

    // ── Cursor arrow ───────────────────────────────────────────────────
    // Defined in cursor-local coords with tip at (0,0), growing down-right.
    // Cocoa Y goes UP, so the draw maps p.y → tipY - p.y * scale.
    // Bigger cursor at tiny sizes so it's recognizable in the menu bar.
    let cursorUnit: CGFloat
    if pixels >= 128 { cursorUnit = 0.022 }
    else if pixels >= 32 { cursorUnit = 0.026 }
    else { cursorUnit = 0.034 }
    let cursorScale = s * cursorUnit
    let pts: [CGPoint] = [
        CGPoint(x:  0.0, y:  0.0),  // tip
        CGPoint(x:  0.0, y: 19.0),  // bottom of left edge
        CGPoint(x:  5.5, y: 14.5),  // notch inward
        CGPoint(x:  8.5, y: 21.5),  // tail bottom-left
        CGPoint(x: 11.0, y: 20.5),  // tail bottom-right
        CGPoint(x:  8.0, y: 13.5),  // back up
        CGPoint(x: 14.0, y: 13.5),  // right side of arrow head
    ]
    let cursorPath = NSBezierPath()
    for (i, p) in pts.enumerated() {
        let xx = tipX + p.x * cursorScale
        let yy = tipY - p.y * cursorScale
        if i == 0 {
            cursorPath.move(to: NSPoint(x: xx, y: yy))
        } else {
            cursorPath.line(to: NSPoint(x: xx, y: yy))
        }
    }
    cursorPath.close()
    cursorPath.lineJoinStyle = .round
    cursorPath.lineCapStyle = .round

    // Drop shadow under the cursor (skip on tiny sizes for clarity).
    if pixels >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.32)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        cursorPath.fill()
        NSGraphicsContext.restoreGraphicsState()
    } else {
        NSColor.white.setFill()
        cursorPath.fill()
    }

    // Dark stroke for definition (skip on tiny sizes — adds noise, not clarity)
    if pixels >= 32 {
        NSColor(white: 0.10, alpha: 0.95).setStroke()
        cursorPath.lineWidth = max(0.75, s * 0.012)
        cursorPath.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetDir = projectRoot
    .appendingPathComponent("build")
    .appendingPathComponent("icon.iconset")
let outputIcns = projectRoot
    .appendingPathComponent("Resources")
    .appendingPathComponent("icon.icns")

let fm = FileManager.default
try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for spec in sizes {
    let rep = drawIcon(pixels: spec.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("error: PNG encoding failed for \(spec.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = iconsetDir.appendingPathComponent("\(spec.name).png")
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(spec.pixels)×\(spec.pixels))")
}

try fm.createDirectory(at: outputIcns.deletingLastPathComponent(), withIntermediateDirectories: true)
try? fm.removeItem(at: outputIcns)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outputIcns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    FileHandle.standardError.write("error: iconutil exited \(proc.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}

print("==> \(outputIcns.path)")
