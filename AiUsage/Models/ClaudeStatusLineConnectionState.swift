import Foundation

struct ClaudeStatusLineConnectionState: Sendable, Equatable {
    enum Configuration: Sendable, Equatable {
        case disconnected
        case foreignStatusLineMergeAvailable
        case managedConnected
        case managedUpdateAvailable
        case legacyDirectAiUsageConnected
        case repairRequired
        case blocked(ClaudeStatusLineConnectionBlockReason)
    }

    enum Cache: Sendable, Equatable {
        case notReceived
        case waiting
        case received
        case unsupported
    }

    let configuration: Configuration
    let cache: Cache
}

enum ClaudeStatusLineConnectionBlockReason: Sendable, Equatable {
    case invalidSettings
    case unsupportedStatusLine
    case unreadableSettings
    case unsafeTarget
}

struct ClaudeStatusLineConnectionPaths: Sendable, Equatable {
    let settingsURL: URL
    let managedDirectoryURL: URL
    let collectorScriptURL: URL
    let wrapperScriptURL: URL
    let originalCommandURL: URL
    let metadataURL: URL
    let backupsDirectoryURL: URL
    let cacheURL: URL

    init(homeDirectoryURL: URL) {
        let claudeDirectoryURL = homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
        let managedDirectoryURL = claudeDirectoryURL
            .appendingPathComponent("aiusage", isDirectory: true)

        self.init(
            settingsURL: claudeDirectoryURL
                .appendingPathComponent("settings.json", isDirectory: false),
            managedDirectoryURL: managedDirectoryURL,
            collectorScriptURL: managedDirectoryURL
                .appendingPathComponent("statusline-cache.sh", isDirectory: false),
            wrapperScriptURL: managedDirectoryURL
                .appendingPathComponent("statusline-wrapper.sh", isDirectory: false),
            originalCommandURL: managedDirectoryURL
                .appendingPathComponent("original-statusline-command", isDirectory: false),
            metadataURL: managedDirectoryURL
                .appendingPathComponent("connection.json", isDirectory: false),
            backupsDirectoryURL: managedDirectoryURL
                .appendingPathComponent("backups", isDirectory: true),
            cacheURL: claudeDirectoryURL
                .appendingPathComponent("usage-cache.json", isDirectory: false)
        )
    }

    init(
        settingsURL: URL,
        managedDirectoryURL: URL,
        collectorScriptURL: URL,
        wrapperScriptURL: URL,
        originalCommandURL: URL,
        metadataURL: URL,
        backupsDirectoryURL: URL,
        cacheURL: URL
    ) {
        self.settingsURL = settingsURL
        self.managedDirectoryURL = managedDirectoryURL
        self.collectorScriptURL = collectorScriptURL
        self.wrapperScriptURL = wrapperScriptURL
        self.originalCommandURL = originalCommandURL
        self.metadataURL = metadataURL
        self.backupsDirectoryURL = backupsDirectoryURL
        self.cacheURL = cacheURL
    }

    static var `default`: Self {
        Self(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
    }
}
