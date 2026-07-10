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
}
