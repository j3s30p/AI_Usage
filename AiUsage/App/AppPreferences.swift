import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: Keys.showCodex) }
    }

    var showClaude: Bool {
        didSet { defaults.set(showClaude, forKey: Keys.showClaude) }
    }

    var showPercentage: Bool {
        didSet { defaults.set(showPercentage, forKey: Keys.showPercentage) }
    }

    var colorUsageRings: Bool {
        didSet { defaults.set(colorUsageRings, forKey: Keys.colorUsageRings) }
    }

    var providerDisplayMode: ProviderDisplayMode {
        didSet { defaults.set(providerDisplayMode.rawValue, forKey: Keys.providerDisplayMode) }
    }

    var refreshInterval: UsageRefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    var claudeUsageMode: ClaudeUsageMode {
        didSet { defaults.set(claudeUsageMode.rawValue, forKey: Keys.claudeUsageMode) }
    }

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            if let languages = appLanguage.appleLanguages {
                defaults.set(languages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showCodex = Self.storedBool(
            forKey: Keys.showCodex,
            defaultValue: true,
            defaults: defaults
        )
        showClaude = Self.storedBool(
            forKey: Keys.showClaude,
            defaultValue: true,
            defaults: defaults
        )
        showPercentage = Self.storedBool(
            forKey: Keys.showPercentage,
            defaultValue: true,
            defaults: defaults
        )
        colorUsageRings = Self.storedBool(
            forKey: Keys.colorUsageRings,
            defaultValue: false,
            defaults: defaults
        )
        providerDisplayMode = defaults.string(forKey: Keys.providerDisplayMode)
            .flatMap(ProviderDisplayMode.init(rawValue:))
            ?? .name
        refreshInterval = defaults.string(forKey: Keys.refreshInterval)
            .flatMap(UsageRefreshInterval.init(rawValue:))
            ?? .threeMinutes
        let storedClaudeUsageMode = defaults.string(forKey: Keys.claudeUsageMode)
        claudeUsageMode = storedClaudeUsageMode
            .flatMap(ClaudeUsageMode.init(rawValue:))
            ?? .statusLine
        appLanguage = defaults.string(forKey: Keys.appLanguage)
            .flatMap(AppLanguage.init(rawValue:))
            ?? .system
        if storedClaudeUsageMode == "cliUsage" {
            defaults.set(
                ClaudeUsageMode.statusLine.rawValue,
                forKey: Keys.claudeUsageMode
            )
        }
    }

    var enabledProviders: Set<UsageProvider> {
        var providers: Set<UsageProvider> = []
        if showCodex { providers.insert(.codex) }
        if showClaude { providers.insert(.claude) }
        return providers
    }

    private static func storedBool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private enum Keys {
        static let showCodex = "showCodex"
        static let showClaude = "showClaude"
        static let showPercentage = "showPercentage"
        static let colorUsageRings = "colorUsageRings"
        static let providerDisplayMode = "providerDisplayMode"
        static let refreshInterval = "refreshInterval"
        static let claudeUsageMode = "claudeUsageMode"
        static let appLanguage = "appLanguage"
    }
}
