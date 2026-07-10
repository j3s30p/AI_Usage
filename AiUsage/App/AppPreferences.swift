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
    }
}
