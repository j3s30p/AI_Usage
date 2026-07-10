import AppKit
import XCTest
@testable import AiUsage

@MainActor
final class MenuBarStatusImageRendererTests: XCTestCase {
    func testRendererReservesTheFullWidthForBothProviders() {
        let codexOnly = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Codex",
                remainingFraction: 0.23,
                percentageText: "23%"
            ),
        ])
        let bothProviders = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Codex",
                remainingFraction: 0.23,
                percentageText: "23%"
            ),
            MenuBarStatusSegment(
                name: "Claude",
                remainingFraction: 0.48,
                percentageText: "48%"
            ),
        ])

        XCTAssertGreaterThan(bothProviders.size.width, codexOnly.size.width * 1.8)
        XCTAssertEqual(bothProviders.size.height, 18)
        XCTAssertTrue(bothProviders.isTemplate)
    }

    func testPercentageToggleChangesRenderedWidth() {
        let withPercentage = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Codex",
                remainingFraction: 0.5,
                percentageText: "50%"
            ),
        ])
        let withoutPercentage = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Codex",
                remainingFraction: 0.5,
                percentageText: nil
            ),
        ])

        XCTAssertGreaterThan(withPercentage.size.width, withoutPercentage.size.width)
    }

    func testRendererReportsOnlyZeroRemainingRingForRedOverlay() {
        let rendering = MenuBarStatusImageRenderer.makeRendering(segments: [
            MenuBarStatusSegment(
                name: "Codex",
                remainingFraction: 0,
                percentageText: "0%"
            ),
            MenuBarStatusSegment(
                name: "Claude",
                remainingFraction: 0.48,
                percentageText: "48%"
            ),
        ])

        XCTAssertEqual(rendering.zeroRemainingRingCenters.count, 1)
        XCTAssertTrue(rendering.image.isTemplate)
    }

    func testRendererUsesDisplayedZeroForRedOverlay() {
        let zero = MenuBarStatusImageRenderer.makeRendering(segments: [
            MenuBarStatusSegment(
                name: "Claude",
                remainingFraction: 0.004,
                percentageText: "0%"
            ),
        ])
        let one = MenuBarStatusImageRenderer.makeRendering(segments: [
            MenuBarStatusSegment(
                name: "Claude",
                remainingFraction: 0.005,
                percentageText: "1%"
            ),
        ])

        XCTAssertEqual(zero.zeroRemainingRingCenters.count, 1)
        XCTAssertTrue(one.zeroRemainingRingCenters.isEmpty)
    }

    func testOfficialLogoModeUsesBundledVectorAssetAndLessWidth() throws {
        XCTAssertNotNil(NSImage(named: NSImage.Name("CodexLogo")))
        XCTAssertNotNil(NSImage(named: NSImage.Name("ClaudeLogo")))

        let nameMode = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Claude",
                remainingFraction: 0.48,
                percentageText: "48%"
            ),
        ])
        let logoMode = MenuBarStatusImageRenderer.makeImage(segments: [
            MenuBarStatusSegment(
                name: "Claude",
                logoAssetName: "ClaudeLogo",
                remainingFraction: 0.48,
                percentageText: "48%"
            ),
        ])

        XCTAssertLessThan(logoMode.size.width, nameMode.size.width)
    }
}
