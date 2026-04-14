#!/usr/bin/env swift
import AppKit
import Foundation

// Generates the StartMenu app icon as a 2x2 grid of white squares on a dark
// graphite gradient, matching the Start button glyph in the taskbar.

struct IconSize {
    let base: Int
    let scale: Int
    var pixelSize: Int { base * scale }
    var filename: String { "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png" }
}

let sizes: [IconSize] = [
    .init(base: 16, scale: 1), .init(base: 16, scale: 2),
    .init(base: 32, scale: 1), .init(base: 32, scale: 2),
    .init(base: 128, scale: 1), .init(base: 128, scale: 2),
    .init(base: 256, scale: 1), .init(base: 256, scale: 2),
    .init(base: 512, scale: 1), .init(base: 512, scale: 2),
]

let repoRoot = FileManager.default.currentDirectoryPath
let outputDir = "\(repoRoot)/StartMenu/Resources/Assets.xcassets/AppIcon.appiconset"

func drawIcon(pixelSize: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let size = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.22
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    let top = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.30, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
    let gradient = NSGradient(starting: top, ending: bottom)
    gradient?.draw(in: bgPath, angle: -90)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    bgPath.lineWidth = max(1, size * 0.005)
    bgPath.stroke()

    let padding = size * 0.24
    let gap = size * 0.07
    let squareSize = (size - 2 * padding - gap) / 2
    let squareCorner = squareSize * 0.22

    NSColor.white.setFill()
    for row in 0..<2 {
        for col in 0..<2 {
            let x = padding + CGFloat(col) * (squareSize + gap)
            let y = padding + CGFloat(row) * (squareSize + gap)
            let cellRect = NSRect(x: x, y: y, width: squareSize, height: squareSize)
            let cellPath = NSBezierPath(roundedRect: cellRect, xRadius: squareCorner, yRadius: squareCorner)
            cellPath.fill()
        }
    }

    return bitmap.representation(using: .png, properties: [:])
}

let contents: [String: Any] = [
    "images": sizes.map { s in
        [
            "idiom": "mac",
            "scale": "\(s.scale)x",
            "size": "\(s.base)x\(s.base)",
            "filename": s.filename,
        ]
    },
    "info": ["author": "xcode", "version": 1],
]

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for s in sizes {
    guard let data = drawIcon(pixelSize: s.pixelSize) else {
        print("failed \(s.filename)")
        continue
    }
    let path = "\(outputDir)/\(s.filename)"
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(s.filename) (\(s.pixelSize)x\(s.pixelSize))")
}

let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("wrote Contents.json")
