#!/usr/bin/env swift

// Renders Notchy/Assets.xcassets/menuIcon.imageset at 1x and 2x.
//
// Only those two: 3x is an iOS concept, and actool drops a 3x slot from a
// macOS asset catalog, so shipping one just leaves a dead file in the repo.
//
// The icon is face.imageset — the same face — flattened onto the alpha channel
// and wrapped in a rounded border. In the source art the background is white,
// the eyes and mouth are black, and the cheeks are pink; collapsing colour by
// luminance (`alpha = (1 - luma) * 255`) turns white transparent, keeps the
// features solid, and leaves the cheeks at 29%. rgb(255,148,154) works out to
// alpha 74, which is exactly what the original 16px icon carries.
//
// That grey matters. Rendered in pure black and white the face loses the soft
// edges that let it read at 16px, and the cheeks stop being cheeks.
//
// Geometry is a 16-unit design grid. The features are axis-aligned rectangles
// rather than a downscale of the source art: at 16px the source would have to
// shrink 30:1, which smears the eyes into grey mush. A few edges sit on
// deliberate fractional coordinates so antialiasing reproduces the original's
// softer boundaries — the mouth's bar, in particular, runs 5.8...10.2 so its
// ends fade instead of snapping to full pixels.
//
//     swift scripts/gen_menu_icon.swift
//
// The figure occupies units 2...14 vertically; the gaps top and bottom are
// deliberate breathing room for the menu bar.

import AppKit

let unitsPerSide = 16.0

/// Cheeks, as a fraction of full black. See the luminance note above.
let cheekAlpha = 74.0 / 255.0

/// Border: 1 unit thick, stroked on a path inset by half of that, so the ink
/// lands on units 0...16 across and 2...14 up.
let borderRect = CGRect(x: 0.5, y: 2.5, width: 15, height: 11)
let borderRadius = 2.0
let borderWidth = 1.0

/// Features, in design units with the origin bottom-left.
let solidFeatures = [
    CGRect(x: 4, y: 9, width: 2, height: 2),          // left eye
    CGRect(x: 10, y: 9, width: 2, height: 2),         // right eye
    CGRect(x: 5, y: 7, width: 1, height: 1),          // left corner of the mouth
    CGRect(x: 10, y: 7, width: 1, height: 1),         // right corner of the mouth
    CGRect(x: 5.8, y: 6, width: 4.4, height: 1),      // the mouth's bar
]
// Stopping at exactly 8 keeps the cheeks out of the blank row above them; the
// fractional bottom is what makes them fade over the mouth's row, as in the
// original.
let cheeks = [
    CGRect(x: 2, y: 6.2, width: 2, height: 1.8),      // left
    CGRect(x: 12, y: 6.2, width: 2, height: 1.8),     // right
]

func render(scale: Int) -> Data {
    let px = Int(unitsPerSide) * scale
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create render context") }

    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    ctx.setStrokeColor(black)
    ctx.setLineWidth(borderWidth)
    ctx.addPath(CGPath(
        roundedRect: borderRect,
        cornerWidth: borderRadius,
        cornerHeight: borderRadius,
        transform: nil
    ))
    ctx.strokePath()

    ctx.setFillColor(black)
    for rect in solidFeatures { ctx.fill(rect) }

    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: cheekAlpha))
    for rect in cheeks { ctx.fill(rect) }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let imageset = root
    .appendingPathComponent("Notchy/Assets.xcassets/menuIcon.imageset")

for (scale, name) in [(1, "menuIcon.png"), (2, "menuIcon@2x.png")] {
    let data = render(scale: scale)
    try data.write(to: imageset.appendingPathComponent(name))
    print("\(name)\t\(Int(unitsPerSide) * scale)×\(Int(unitsPerSide) * scale)\t\(data.count) bytes")
}
