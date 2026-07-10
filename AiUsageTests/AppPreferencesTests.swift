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
        preferences.claudeUsageMode = .cliUsage

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showCodex)
        XCTAssertTrue(reloaded.showClaude)
        XCTAssertFalse(reloaded.showPercentage)
        XCTAssertEqual(reloaded.providerDisplayMode, .logo)
        XCTAssertEqual(reloaded.refreshInterval, .fifteenMinutes)
        XCTAssertEqual(reloaded.claudeUsageMode, .cliUsage)
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

    func testClaudeUsageModesExposeOnlyTheirOwnExperimentalCapability() {
        XCTAssertFalse(ClaudeUsageMode.statusLine.allowsOAuthUsage)
        XCTAssertFalse(ClaudeUsageMode.statusLine.allowsCLIUsage)
        XCTAssertTrue(ClaudeUsageMode.oauth.allowsOAuthUsage)
        XCTAssertFalse(ClaudeUsageMode.oauth.allowsCLIUsage)
        XCTAssertFalse(ClaudeUsageMode.cliUsage.allowsOAuthUsage)
        XCTAssertTrue(ClaudeUsageMode.cliUsage.allowsCLIUsage)
    }

    func testClaudeUsageModesExposeExpectedDisplayNames() {
        XCTAssertEqual(
            ClaudeUsageMode.allCases.map(\.displayName),
            [
                "statusLine 캐시 (권장)",
                "OAuth Keychain (실험적)",
                "CLI /usage (실험적)",
            ]
        )
    }

    func testRefreshIntervalsExposeExpectedDurations() {
        XCTAssertEqual(UsageRefreshInterval.allCases.map(\.seconds), [60, 180, 300, 900, 1_800])
        XCTAssertEqual(
            UsageRefreshInterval.allCases.map(\.maximumExpectedSnapshotAge),
            [900, 900, 900, 1_020, 1_920]
        )
    }
}
