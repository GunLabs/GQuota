import AppKit
import GQuotaKit

enum MenuBarIconSegment: Equatable {
    case usage(Double)
    case neutral
}

enum MenuBarIconRenderer {
    private static let barStride: CGFloat = 6
    private static let barWidth: CGFloat = 3
    private static let imageHeight: CGFloat = 16

    struct Bar {
        let heightFraction: Double
        let tier: SeverityTier
        let isNeutral: Bool
    }

    /// Pure function: severity values -> per-bar height and color tier.
    static func bars(for severities: [Double]) -> [Bar] {
        bars(forSegments: severities.map(MenuBarIconSegment.usage))
    }

    static func bars(forSegments segments: [MenuBarIconSegment]) -> [Bar] {
        segments.map { segment in
            switch segment {
            case .usage(let severity):
                return Bar(
                    heightFraction: min(1, max(0, severity)),
                    tier: Severity.tier(for: severity),
                    isNeutral: false
                )
            case .neutral:
                return Bar(heightFraction: 0.45, tier: .ok, isNeutral: true)
            }
        }
    }

    static func barRects(for severities: [Double]) -> [NSRect] {
        barRects(for: bars(for: severities), imageHeight: imageHeight)
    }

    /// Colored non-template image: one bar per provider.
    static func image(for severities: [Double], appearance: NSAppearance) -> NSImage {
        image(forSegments: severities.map(MenuBarIconSegment.usage), appearance: appearance)
    }

    /// Colored/non-template image with neutral provider placeholders.
    static func image(forSegments segments: [MenuBarIconSegment], appearance: NSAppearance) -> NSImage {
        let bars = bars(forSegments: segments)
        let barRects = barRects(for: bars, imageHeight: imageHeight)
        let width = max(8, CGFloat(bars.count) * barStride)
        let height = imageHeight
        let image = NSImage(size: NSSize(width: width, height: height))
        image.isTemplate = false

        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            if bars.isEmpty {
                drawPlaceholder(in: NSRect(x: 1.25, y: 4.25, width: 5.5, height: 7.5), appearance: appearance)
            } else {
                for (bar, rect) in zip(bars, barRects) {
                    if bar.isNeutral {
                        neutralFillColor(for: appearance).setFill()
                    } else {
                        let (r, g, b) = bar.tier.colorRGB
                        NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
                            .setFill()
                    }
                    let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                    path.fill()
                    outlineColor(for: appearance).setStroke()
                    path.lineWidth = 0.5
                    path.stroke()
                }
            }
        }
        image.unlockFocus()

        return image
    }

    private static func barRects(for bars: [Bar], imageHeight: CGFloat) -> [NSRect] {
        bars.enumerated().map { index, bar in
            let x = CGFloat(index) * barStride + 1
            let barHeight = max(2, CGFloat(bar.heightFraction) * (imageHeight - 2))
            return NSRect(x: x, y: 1, width: barWidth, height: barHeight)
        }
    }

    private static func drawPlaceholder(in rect: NSRect, appearance: NSAppearance) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        placeholderFillColor(for: appearance).setFill()
        path.fill()
        outlineColor(for: appearance).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private static func outlineColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.42)
        }

        return NSColor.black.withAlphaComponent(0.30)
    }

    private static func placeholderFillColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.12)
        }

        return NSColor.black.withAlphaComponent(0.08)
    }

    private static func neutralFillColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.28)
        }

        return NSColor.black.withAlphaComponent(0.22)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
