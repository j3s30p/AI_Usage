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
        XCTAssertEqual(preferences.claudeUsageMode, .statusLine)
        XCTAssertEqual(preferences.appLanguage, .system)
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
        preferences.claudeUsageMode = .oauth
        preferences.appLanguage = .english

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showCodex)
        XCTAssertTrue(reloaded.showClaude)
        XCTAssertFalse(reloaded.showPercentage)
        XCTAssertEqual(reloaded.providerDisplayMode, .logo)
        XCTAssertEqual(reloaded.refreshInterval, .fifteenMinutes)
        XCTAssertEqual(reloaded.claudeUsageMode, .oauth)
        XCTAssertEqual(reloaded.appLanguage, .english)
        XCTAssertEqual(reloaded.enabledProviders, [.claude])
    }

    func testInvalidClaudeUsageModeFallsBackToStatusLine() throws {
        let suiteName = "AppPreferencesTests.invalidClaudeMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unsupported", forKey: "claudeUsageMode")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.claudeUsageMode, .statusLine)
    }

    func testLegacyCLIUsageModeMigratesToStatusLine() throws {
        let suiteName = "AppPreferencesTests.legacyCLIUsageMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("cliUsage", forKey: "claudeUsageMode")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.claudeUsageMode, .statusLine)
        XCTAssertEqual(defaults.string(forKey: "claudeUsageMode"), "statusLine")
    }

    func testEveryClaudeUsageModePersists() throws {
        let suiteName = "AppPreferencesTests.claudeModes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in ClaudeUsageMode.allCases {
            let preferences = AppPreferences(defaults: defaults)
            preferences.claudeUsageMode = mode

            XCTAssertEqual(
                AppPreferences(defaults: defaults).claudeUsageMode,
                mode
            )
        }
    }

    func testClaudeUsageModesExposeDisplayNames() {
        XCTAssertTrue(
            ClaudeUsageMode.allCases.allSatisfy { !$0.displayName.isEmpty }
        )
    }

    func testEveryAppLanguagePersists() throws {
        let suiteName = "AppPreferencesTests.systemLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for language in AppLanguage.allCases {
            let preferences = AppPreferences(defaults: defaults)
            preferences.appLanguage = language

            XCTAssertEqual(
                AppPreferences(defaults: defaults).appLanguage,
                language
            )
        }
    }

    func testRefreshIntervalsExposeExpectedDurations() {
        XCTAssertEqual(UsageRefreshInterval.allCases.map(\.seconds), [60, 180, 300, 900, 1_800])
        XCTAssertEqual(
            UsageRefreshInterval.allCases.map(\.maximumExpectedSnapshotAge),
            [900, 900, 900, 1_020, 1_920]
        )
    }
}
