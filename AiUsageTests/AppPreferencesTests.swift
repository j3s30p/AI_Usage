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

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showCodex)
        XCTAssertTrue(reloaded.showClaude)
        XCTAssertFalse(reloaded.showPercentage)
        XCTAssertEqual(reloaded.enabledProviders, [.claude])
    }
}
