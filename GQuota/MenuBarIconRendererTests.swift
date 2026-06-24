import AppKit
import XCTest
import GQuotaKit
@testable import GQuota

final class MenuBarIconRendererTests: XCTestCase {
    func testBarHeightsMapSeverity() {
        let bars = MenuBarIconRenderer.bars(for: [0.2, 0.95])
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].heightFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(bars[1].tier, .danger)
    }

    func testClampBarHeightsAndTier() {
        let bars = MenuBarIconRenderer.bars(for: [-0.2, 1.2])
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].heightFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(bars[1].heightFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(bars[1].tier, .danger)
    }

    func testEmptyProducesNoBars() {
        let severities: [Double] = []
        let bars = MenuBarIconRenderer.bars(for: severities)
        XCTAssertTrue(bars.isEmpty)
    }

    func testSegmentsCanRepresentNeutralMissingProviderWithoutGreenSeverity() {
        let bars = MenuBarIconRenderer.bars(forSegments: [.usage(0.80), .neutral])

        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].heightFraction, 0.80, accuracy: 1e-9)
        XCTAssertFalse(bars[0].isNeutral)
        XCTAssertTrue(bars[1].isNeutral)
    }

    func testEmptyImageDrawsVisibleNonTemplatePlaceholder() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let image = MenuBarIconRenderer.image(
            for: [],
            appearance: appearance
        )

        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size.width, 8, accuracy: 1e-9)
        XCTAssertEqual(image.size.height, 16, accuracy: 1e-9)
        XCTAssertTrue(try image.hasNonTransparentPixel())
    }

    func testEmptyPlaceholderUsesAppearanceContrast() throws {
        let lightImage = MenuBarIconRenderer.image(
            for: [],
            appearance: try XCTUnwrap(NSAppearance(named: .aqua))
        )
        let darkImage = MenuBarIconRenderer.image(
            for: [],
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
        )

        XCTAssertLessThan(
            try lightImage.averageNonTransparentLuminance(),
            try darkImage.averageNonTransparentLuminance()
        )
    }

    func testBarLayoutUsesThreePixelSegmentWidth() {
        let rects = MenuBarIconRenderer.barRects(for: [1])

        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].width, 3, accuracy: 1e-9)
        XCTAssertEqual(rects[0].maxY, 15, accuracy: 1e-9)
    }
}

private extension NSImage {
    func hasNonTransparentPixel() throws -> Bool {
        try nonTransparentLuminances().isEmpty == false
    }

    func averageNonTransparentLuminance() throws -> CGFloat {
        let luminances = try nonTransparentLuminances()
        guard luminances.isEmpty == false else { return 0 }
        return luminances.reduce(0, +) / CGFloat(luminances.count)
    }

    private func nonTransparentLuminances() throws -> [CGFloat] {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            XCTFail("Expected bitmap representation")
            return []
        }

        var luminances: [CGFloat] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 else {
                    continue
                }

                let rgb = color.usingColorSpace(.deviceRGB) ?? color
                luminances.append(
                    0.2126 * rgb.redComponent +
                    0.7152 * rgb.greenComponent +
                    0.0722 * rgb.blueComponent
                )
            }
        }

        return luminances
    }
}
