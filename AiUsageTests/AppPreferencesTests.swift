import Foundation
import XCTest
@testable import AiUsage

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testPreferencesDefaultToBothProvidersAndPercentageVisible() throws {
        let suiteName = "AppPreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.showCodex)
        XCTAssertTrue(preferences.showClaude)
        XCTAssertTrue(preferences.showPercentage)
        XCTAssertEqual(preferences.providerDisplayMode, .name)
        XCTAssertEqual(preferences.refreshInterval, .threeMinutes)
        XCTAssertEqual(preferences.enabledProviders, Set(UsageProvider.allCases))
    }

    func testPreferencesPersistSelectionAndPercentage() throws {
        let suiteName = "AppPreferencesTests.persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showCodex = false
        preferences.showClaude = true
        preferences.showPercentage = false
        preferences.providerDisplayMode = .logo
        preferences.refreshInterval = .fifteenMinutes

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showCodex)
        XCTAssertTrue(reloaded.showClaude)
        XCTAssertFalse(reloaded.showPercentage)
        XCTAssertEqual(reloaded.providerDisplayMode, .logo)
        XCTAssertEqual(reloaded.refreshInterval, .fifteenMinutes)
        XCTAssertEqual(reloaded.enabledProviders, [.claude])
    }

    func testRefreshIntervalsExposeExpectedDurations() {
        XCTAssertEqual(UsageRefreshInterval.allCases.map(\.seconds), [60, 180, 300, 900, 1_800])
        XCTAssertEqual(
            UsageRefreshInterval.allCases.map(\.maximumExpectedSnapshotAge),
            [900, 900, 900, 1_020, 1_920]
        )
    }
}
