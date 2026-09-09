import AppKit
import Testing
@testable import Notchy

/// Tests for the menu-bar icon and its update badge.
///
/// Two things here are easy to break without noticing. The imageset must ship
/// a 2x rendition — drop it and the icon silently goes back to being an
/// upscaled 16px blur on every Retina display. And the badge must stay in the
/// top-right corner: it's punched out of the artwork with a `.clear` blend, so
/// a wrong radius or centre quietly erases part of the face instead of sitting
/// beside it.
@MainActor
@Suite("Status item icon")
struct StatusItemIconTests {

    /// Alpha channel of `image` rasterised at `side`×`side`. Only alpha is
    /// compared: these are template images, so AppKit throws the colour away.
    private func alpha(of image: NSImage, side: Int) -> [UInt8] {
        var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return []
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    @Test("The imageset ships both scales macOS uses")
    func menuIconHasEveryScale() throws {
        let base = try #require(NSImage(named: "menuIcon"))
        // 1x and 2x only. A 3x slot is an iOS notion; actool strips it from a
        // macOS catalog, so asserting on one would fail no matter what ships.
        let widths = Set(base.representations.map(\.pixelsWide))
        #expect(widths == [16, 32])
    }

    @Test("Both variants are template images")
    func bothVariantsAreTemplates() throws {
        // Non-template would mean hand-managing light/dark and the inverted
        // highlight while the menu is open.
        #expect(try #require(AppDelegate.statusIcon(badged: false)).isTemplate)
        #expect(try #require(AppDelegate.statusIcon(badged: true)).isTemplate)
    }

    @Test("Badging doesn't change the icon's size")
    func badgingPreservesSize() throws {
        let plain = try #require(AppDelegate.statusIcon(badged: false))
        let badged = try #require(AppDelegate.statusIcon(badged: true))
        #expect(plain.size == badged.size)
    }

    @Test("The badge marks the top-right corner and leaves the face alone")
    func badgeIsConfinedToTopRight() throws {
        // Sampled at 3× the point size — not an asset scale, just enough
        // resolution to place the badge's fractional geometry precisely.
        let side = 48
        let plain = alpha(of: try #require(AppDelegate.statusIcon(badged: false)), side: side)
        let badged = alpha(of: try #require(AppDelegate.statusIcon(badged: true)), side: side)
        try #require(plain.count == side * side)
        try #require(badged.count == side * side)

        // Row 0 is the top of the image. The badge is centred at design unit
        // (14.2, 12.8) measured from the bottom-left, i.e. the top-right corner.
        var changedInTopRight = 0
        var changedElsewhere = 0
        for row in 0..<side {
            for col in 0..<side {
                guard plain[row * side + col] != badged[row * side + col] else { continue }
                let isTopRight = row < side / 2 && col >= side / 2
                if isTopRight { changedInTopRight += 1 } else { changedElsewhere += 1 }
            }
        }
        #expect(changedInTopRight > 0, "the badge didn't draw anything")
        #expect(changedElsewhere == 0, "the badge spilled outside the top-right corner")
    }
}
