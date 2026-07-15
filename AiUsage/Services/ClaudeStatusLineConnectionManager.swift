import CryptoKit
import Darwin
import Foundation

protocol ClaudeStatusLineConnectionManaging: Sendable {
    func inspect() async -> ClaudeStatusLineConnectionState
    @discardableResult
    func connect() async throws -> ClaudeStatusLineConnectionState
    @discardableResult
    func disconnect() async throws -> ClaudeStatusLineConnectionState
}

enum ClaudeStatusLineConnectionError: LocalizedError, Sendable, Equatable {
    case helperUnavailable
    case invalidSettings
    case unsupportedStatusLine
    case unsafeTarget
    case managedFilesConflict
    case settingsChangedExternally
    case repairUnavailable
    case notManaged
    case fileOperationFailed

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            String(localized: "AiUsage statusLine 도우미를 불러오지 못했습니다.")
        case .invalidSettings:
            String(localized: "Claude 설정 파일이 올바른 JSON 객체가 아닙니다.")
        case .unsupportedStatusLine:
            String(localized: "현재 Claude statusLine 설정은 자동 연결을 지원하지 않습니다.")
        case .unsafeTarget:
            String(localized: "연결 대상이 심볼릭 링크이거나 현재 사용자 소유가 아닙니다.")
        case .managedFilesConflict:
            String(localized: "AiUsage 연결 파일과 충돌하는 기존 파일이 있습니다.")
        case .settingsChangedExternally:
            String(localized: "Claude 설정이 외부에서 변경되어 작업을 중단했습니다.")
        case .repairUnavailable:
            String(localized: "기존 연결 정보가 없어 안전하게 복구할 수 없습니다.")
        case .notManaged:
            String(localized: "AiUsage가 관리하는 statusLine 연결이 아닙니다.")
        case .fileOperationFailed:
            String(localized: "statusLine 연결 파일을 안전하게 변경하지 못했습니다.")
        }
    }
}

actor ClaudeStatusLineConnectionManager: ClaudeStatusLineConnectionManaging {
    typealias HelperLoader = @Sendable () throws -> Data

    static let managedCommand = #""$HOME/.claude/aiusage/statusline-wrapper.sh""#
    static let legacyCommand = "~/.claude/statusline-aiusage.sh"

    private static let metadataVersion = 1
    private static let privateDirectoryPermissions = 0o700
    private static let scriptPermissions = 0o700
    private static let privateFilePermissions = 0o600

    private let paths: ClaudeStatusLineConnectionPaths
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let helperLoader: HelperLoader

    init(
        paths: ClaudeStatusLineConnectionPaths = .default,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        helperLoader: @escaping HelperLoader = {
            try ClaudeStatusLineConnectionManager.loadBundledHelper()
        }
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.now = now
        self.helperLoader = helperLoader
    }

    func inspect() async -> ClaudeStatusLineConnectionState {
        let cache = inspectCache()
        let configuration: ClaudeStatusLineConnectionState.Configuration
        do {
            configuration = try inspectConfiguration()
        } catch SecureFileError.unsafe {
            configuration = .blocked(.unsafeTarget)
        } catch SecureFileError.changed {
            configuration = .blocked(.unreadableSettings)
        } catch InspectionError.invalidSettings {
            configuration = .blocked(.invalidSettings)
        } catch InspectionError.unsupportedStatusLine {
            configuration = .blocked(.unsupportedStatusLine)
        } catch {
            configuration = .blocked(.unreadableSettings)
        }
        return ClaudeStatusLineConnectionState(
            configuration: configuration,
            cache: cache
        )
    }

    @discardableResult
    func connect() async throws -> ClaudeStatusLineConnectionState {
        try Task.checkCancellation()
        let helperData: Data
        do {
            helperData = try helperLoader()
        } catch {
            throw ClaudeStatusLineConnectionError.helperUnavailable
        }
        guard !helperData.isEmpty else {
            throw ClaudeStatusLineConnectionError.helperUnavailable
        }

        let snapshot = try readSettingsForMutation()
        let root = try parseSettingsForMutation(snapshot.data)
        let statusLine = try supportedStatusLineForMutation(in: root)

        if case .existing(let current, let command) = statusLine,
           command == Self.managedCommand {
            return try repairManagedConnection(
                currentStatusLine: current,
                settingsSnapshot: snapshot,
                helperData: helperData
            )
        }
        if let recovered = try recoverInterruptedOperationBeforeConnect(
            root: root,
            statusLine: statusLine,
            settingsSnapshot: snapshot,
            helperData: helperData
        ) {
            return recovered
        }

        let originalStatusLine: [String: Any]?
        let originalCommand: String?
        let storesOriginalCommand: Bool
        switch statusLine {
        case .absent:
            originalStatusLine = nil
            originalCommand = nil
            storesOriginalCommand = false
        case .existing(let fragment, let command):
            originalStatusLine = fragment
            originalCommand = command
            storesOriginalCommand = command != Self.legacyCommand
        }

        var installedStatusLine = originalStatusLine ?? ["type": "command"]
        installedStatusLine["command"] = Self.managedCommand
        let helperDigest = Self.sha256(helperData)
        try prepareDirectories()
        try requireManagedTargetsAbsent()
        try removeUnreferencedBackups()
        let originalSettingsBackup = try snapshot.data.map(createBackup)
        let preparedMetadata = try makeMetadata(
            originalStatusLine: originalStatusLine,
            installedStatusLine: installedStatusLine,
            storesOriginalCommand: storesOriginalCommand,
            collectorSHA256: helperDigest,
            installedAt: now(),
            phase: .prepared,
            originalSettingsBackup: originalSettingsBackup
        )

        do {
            try writeNewManagedFile(
                try Self.encodeMetadata(preparedMetadata),
                to: paths.metadataURL,
                permissions: Self.privateFilePermissions
            )
            try writeNewManagedFile(
                helperData,
                to: paths.collectorScriptURL,
                permissions: Self.scriptPermissions
            )
            try writeNewManagedFile(
                Self.wrapperData,
                to: paths.wrapperScriptURL,
                permissions: Self.scriptPermissions
            )
            if storesOriginalCommand, let originalCommand {
                try writeNewManagedFile(
                    Data(originalCommand.utf8),
                    to: paths.originalCommandURL,
                    permissions: Self.privateFilePermissions
                )
            }
            var updatedRoot = root
            updatedRoot["statusLine"] = installedStatusLine
            let updatedSettings = try Self.encodeSettings(updatedRoot)
            try atomicWriteSettings(updatedSettings, replacing: snapshot)
            try upsertManagedFile(
                try Self.encodeMetadata(
                    Self.metadata(preparedMetadata, phase: .connected)
                ),
                to: paths.metadataURL,
                permissions: Self.privateFilePermissions
            )
        } catch {
            if let connectionError = error as? ClaudeStatusLineConnectionError {
                throw connectionError
            }
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }

        let state = await inspect()
        guard state.configuration == .managedConnected else {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        return state
    }

    @discardableResult
    func disconnect() async throws -> ClaudeStatusLineConnectionState {
        try Task.checkCancellation()
        let snapshot = try readSettingsForMutation()
        if snapshot.data == nil {
            let hasMetadata = (try? readManagedFileForMutation(
                at: paths.metadataURL
            )) != nil
            guard hasMetadata else {
                throw ClaudeStatusLineConnectionError.notManaged
            }
        }
        let root = try parseSettingsForMutation(snapshot.data)
        let decodedMetadata = try readMetadataForMutation()
        guard let metadataFile = try readManagedFileForMutation(
            at: paths.metadataURL
        ) else {
            throw ClaudeStatusLineConnectionError.repairUnavailable
        }

        if decodedMetadata.value.phase == .disconnectPrepared,
           let current = try? supportedStatusLineForMutation(in: root),
           statusLineMatchesOriginal(current, metadata: decodedMetadata) {
            guard metadataFile.permissions == Self.privateFilePermissions,
                  try directoryIsHealthy(paths.managedDirectoryURL),
                  try directoryIsHealthy(paths.backupsDirectoryURL),
                  try originalBackupIsValid(decodedMetadata)
            else {
                throw ClaudeStatusLineConnectionError.repairUnavailable
            }
            do {
                try cleanupManagedArtifacts(decodedMetadata)
                try removeUnreferencedBackups()
            } catch SecureFileError.unsafe {
                throw ClaudeStatusLineConnectionError.unsafeTarget
            } catch {
                throw ClaudeStatusLineConnectionError.fileOperationFailed
            }
            return await inspect()
        }

        guard let currentStatusLine = root["statusLine"] as? [String: Any],
              Self.jsonEqual(
                  currentStatusLine,
                  decodedMetadata.installedStatusLine
              )
        else {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        }
        guard let settingsData = snapshot.data else {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        }

        let settingsFile = SecureFile(
            data: settingsData,
            fingerprint: snapshot.fingerprint,
            permissions: snapshot.permissions
        )
        let isHealthy: Bool
        do {
            isHealthy = try managedFilesAreHealthy(
                settingsFile: settingsFile,
                metadataFile: metadataFile,
                metadata: decodedMetadata
            )
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        guard isHealthy else {
            throw ClaudeStatusLineConnectionError.repairUnavailable
        }

        try prepareDirectories()
        let disconnectPreparedMetadata = Self.metadata(
            decodedMetadata.value,
            phase: .disconnectPrepared
        )
        try upsertManagedFile(
            try Self.encodeMetadata(disconnectPreparedMetadata),
            to: paths.metadataURL,
            permissions: Self.privateFilePermissions
        )
        let disconnectBackup = try createBackup(settingsData)

        var restoredRoot = root
        if let originalStatusLine = decodedMetadata.originalStatusLine {
            restoredRoot["statusLine"] = originalStatusLine
        } else {
            restoredRoot.removeValue(forKey: "statusLine")
        }
        do {
            if decodedMetadata.value.originalSettingsBackupFileName == nil,
               restoredRoot.isEmpty {
                try removeSettingsIfUnchanged(snapshot)
            } else {
                try atomicWriteSettings(
                    try Self.encodeSettings(restoredRoot),
                    replacing: snapshot
                )
            }
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }

        do {
            try cleanupManagedArtifacts(decodedMetadata)
            let disconnectBackupURL = paths.backupsDirectoryURL
                .appendingPathComponent(
                    disconnectBackup.fileName,
                    isDirectory: false
                )
            try removeOwnedFileIfPresent(at: disconnectBackupURL)
            try removeUnreferencedBackups()
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        return await inspect()
    }

    // MARK: - Inspection

    private func inspectConfiguration()
        throws -> ClaudeStatusLineConnectionState.Configuration
    {
        guard try settingsDirectoryExistsAndIsSafe() else {
            return .disconnected
        }
        guard let settingsFile = try secureReadOwnedRegularFile(
            at: paths.settingsURL
        ) else {
            if try hasRecoverableOrphan(for: .absent) {
                return .repairRequired
            }
            return .disconnected
        }
        let root = try Self.parseSettings(settingsFile.data)
        guard let rawStatusLine = root["statusLine"] else {
            if try hasRecoverableOrphan(for: .absent) {
                return .repairRequired
            }
            return .disconnected
        }
        guard let statusLine = rawStatusLine as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.isEmpty
        else {
            throw InspectionError.unsupportedStatusLine
        }
        let supportedStatusLine = SupportedStatusLine.existing(
            statusLine,
            command: command
        )

        if command == Self.legacyCommand {
            if try hasRecoverableOrphan(for: supportedStatusLine) {
                return .repairRequired
            }
            return .legacyDirectAiUsageConnected
        }
        if command != Self.managedCommand {
            if try hasRecoverableOrphan(for: supportedStatusLine) {
                return .repairRequired
            }
            return .foreignStatusLineMergeAvailable
        }

        guard let metadataFile = try secureReadOwnedRegularFile(
            at: paths.metadataURL
        ),
              let decodedMetadata = try? decodeMetadata(metadataFile.data),
              Self.jsonEqual(
                  statusLine,
                  decodedMetadata.installedStatusLine
              ),
              decodedMetadata.value.phase == .connected
        else {
            return .repairRequired
        }

        guard try managedFilesAreHealthy(
            settingsFile: settingsFile,
            metadataFile: metadataFile,
            metadata: decodedMetadata
        ) else {
            return .repairRequired
        }
        return bundledHelperDiffers(from: decodedMetadata.value.collectorSHA256)
            ? .managedUpdateAvailable
            : .managedConnected
    }

    private func bundledHelperDiffers(from installedDigest: String) -> Bool {
        guard let helperData = try? helperLoader(), !helperData.isEmpty else {
            return false
        }
        return Self.sha256(helperData) != installedDigest
    }

    private func hasRecoverableOrphan(
        for statusLine: SupportedStatusLine
    ) throws -> Bool {
        guard let directory = try lstatInfo(at: paths.managedDirectoryURL) else {
            return false
        }
        guard directory.isDirectory,
              directory.owner == UInt32(geteuid())
        else {
            throw SecureFileError.unsafe
        }
        guard let metadataFile = try secureReadOwnedRegularFile(
            at: paths.metadataURL
        ),
              metadataFile.permissions == Self.privateFilePermissions,
              let metadata = try? decodeMetadata(metadataFile.data),
              metadata.value.phase != .connected
        else {
            return false
        }
        return statusLineMatchesOriginal(statusLine, metadata: metadata)
    }

    private func inspectCache() -> ClaudeStatusLineConnectionState.Cache {
        guard (try? settingsDirectoryExistsAndIsSafe()) == true else {
            return .notReceived
        }
        guard let file = try? secureReadOwnedRegularFile(at: paths.cacheURL),
              let object = try? JSONSerialization.jsonObject(with: file.data),
              let cache = object as? [String: Any]
        else {
            return .notReceived
        }
        guard cacheWasObservedAfterManagedConnection(cache, file: file) else {
            return .notReceived
        }

        switch cache["status"] as? String {
        case "waiting_for_first_response":
            return .waiting
        case "unsupported_account":
            return .unsupported
        case "ready":
            return .received
        default:
            return cache["rate_limits"] is [String: Any]
                ? .received
                : .notReceived
        }
    }

    private func cacheWasObservedAfterManagedConnection(
        _ cache: [String: Any],
        file: SecureFile
    ) -> Bool {
        guard let settingsFile = try? secureReadOwnedRegularFile(
            at: paths.settingsURL
        ),
              let root = try? Self.parseSettings(settingsFile.data),
              let currentStatusLine = root["statusLine"] as? [String: Any],
              currentStatusLine["command"] as? String == Self.managedCommand
        else {
            return true
        }
        guard let metadataFile = try? secureReadOwnedRegularFile(
            at: paths.metadataURL
        ),
              let metadata = try? decodeMetadata(metadataFile.data),
              metadata.value.phase == .connected,
              Self.jsonEqual(
                  currentStatusLine,
                  metadata.installedStatusLine
              )
        else {
            return false
        }
        if metadata.originalCommand == Self.legacyCommand {
            return true
        }

        let observedAt: TimeInterval?
        if let capturedAt = cache["captured_at"] as? NSNumber,
           capturedAt.doubleValue.isFinite {
            observedAt = capturedAt.doubleValue
        } else if let fingerprint = file.fingerprint {
            observedAt = TimeInterval(fingerprint.modifiedSeconds)
                + TimeInterval(fingerprint.modifiedNanoseconds) / 1_000_000_000
        } else {
            observedAt = nil
        }
        guard let observedAt else { return false }
        return observedAt >= floor(metadata.value.installedAt)
    }

    private func managedFilesAreHealthy(
        settingsFile: SecureFile,
        metadataFile: SecureFile,
        metadata: DecodedMetadata
    ) throws -> Bool {
        guard settingsFile.permissions == Self.privateFilePermissions,
              metadataFile.permissions == Self.privateFilePermissions,
              try directoryIsHealthy(paths.managedDirectoryURL),
              try directoryIsHealthy(paths.backupsDirectoryURL),
              let collector = try secureReadOwnedRegularFile(
                  at: paths.collectorScriptURL
              ),
              collector.permissions == Self.scriptPermissions,
              Self.sha256(collector.data) == metadata.value.collectorSHA256,
              let wrapper = try secureReadOwnedRegularFile(
                  at: paths.wrapperScriptURL
              ),
              wrapper.permissions == Self.scriptPermissions,
              wrapper.data == Self.wrapperData
        else {
            return false
        }

        if metadata.value.storesOriginalCommand {
            guard let originalCommand = metadata.originalCommand,
                  let originalFile = try secureReadOwnedRegularFile(
                      at: paths.originalCommandURL
                  ),
                  originalFile.permissions == Self.privateFilePermissions,
                  originalFile.data == Data(originalCommand.utf8)
            else {
                return false
            }
        } else if try secureReadOwnedRegularFile(
            at: paths.originalCommandURL
        ) != nil {
            return false
        }
        return try originalBackupIsValid(metadata)
    }

    private func originalBackupIsValid(_ metadata: DecodedMetadata) throws -> Bool {
        guard let fileName = metadata.value.originalSettingsBackupFileName,
              let expectedSHA256 = metadata.value.originalSettingsSHA256
        else {
            return metadata.value.originalSettingsBackupFileName == nil
                && metadata.value.originalSettingsSHA256 == nil
                && metadata.originalStatusLine == nil
        }
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else {
            return false
        }
        let backupURL = paths.backupsDirectoryURL
            .appendingPathComponent(fileName, isDirectory: false)
        guard let backup = try secureReadOwnedRegularFile(at: backupURL),
              backup.permissions == Self.privateFilePermissions,
              Self.sha256(backup.data) == expectedSHA256,
              let root = try? Self.parseSettings(backup.data)
        else {
            return false
        }
        if let originalStatusLine = metadata.originalStatusLine {
            guard let backedUpStatusLine = root["statusLine"] as? [String: Any]
            else {
                return false
            }
            return Self.jsonEqual(backedUpStatusLine, originalStatusLine)
        }
        return root["statusLine"] == nil
    }

    // MARK: - Connect and repair

    private func recoverInterruptedOperationBeforeConnect(
        root: [String: Any],
        statusLine: SupportedStatusLine,
        settingsSnapshot: SettingsSnapshot,
        helperData: Data
    ) throws -> ClaudeStatusLineConnectionState? {
        guard let managedDirectory = try lstatInfo(at: paths.managedDirectoryURL)
        else {
            return nil
        }
        guard managedDirectory.isDirectory,
              managedDirectory.owner == UInt32(geteuid())
        else {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        }
        guard let metadataFile = try readManagedFileForMutation(
            at: paths.metadataURL
        ) else {
            return nil
        }
        let metadata: DecodedMetadata
        do {
            metadata = try decodeMetadata(metadataFile.data)
        } catch {
            throw ClaudeStatusLineConnectionError.managedFilesConflict
        }
        guard metadataFile.permissions == Self.privateFilePermissions,
              statusLineMatchesOriginal(statusLine, metadata: metadata),
              try directoryIsHealthy(paths.managedDirectoryURL),
              try directoryIsHealthy(paths.backupsDirectoryURL),
              try originalBackupIsValid(metadata)
        else {
            throw ClaudeStatusLineConnectionError.managedFilesConflict
        }

        switch metadata.value.phase {
        case .prepared:
            try prepareDirectories()
            try validateSettingsUnchanged(settingsSnapshot)
            let helperDigest = Self.sha256(helperData)
            try upsertManagedFile(
                helperData,
                to: paths.collectorScriptURL,
                permissions: Self.scriptPermissions
            )
            try upsertManagedFile(
                Self.wrapperData,
                to: paths.wrapperScriptURL,
                permissions: Self.scriptPermissions
            )
            if metadata.value.storesOriginalCommand {
                guard let originalCommand = metadata.originalCommand else {
                    throw ClaudeStatusLineConnectionError.repairUnavailable
                }
                try upsertManagedFile(
                    Data(originalCommand.utf8),
                    to: paths.originalCommandURL,
                    permissions: Self.privateFilePermissions
                )
            } else {
                try removeOwnedFileIfPresent(at: paths.originalCommandURL)
            }
            let refreshedPrepared = Self.metadata(
                metadata.value,
                phase: .prepared,
                collectorSHA256: helperDigest
            )
            try upsertManagedFile(
                try Self.encodeMetadata(refreshedPrepared),
                to: paths.metadataURL,
                permissions: Self.privateFilePermissions
            )
            var updatedRoot = root
            updatedRoot["statusLine"] = metadata.installedStatusLine
            try atomicWriteSettings(
                try Self.encodeSettings(updatedRoot),
                replacing: settingsSnapshot
            )
            try upsertManagedFile(
                try Self.encodeMetadata(
                    Self.metadata(refreshedPrepared, phase: .connected)
                ),
                to: paths.metadataURL,
                permissions: Self.privateFilePermissions
            )
            guard try inspectConfiguration() == .managedConnected else {
                throw ClaudeStatusLineConnectionError.fileOperationFailed
            }
            return ClaudeStatusLineConnectionState(
                configuration: .managedConnected,
                cache: inspectCache()
            )
        case .disconnectPrepared:
            try cleanupManagedArtifacts(metadata)
            try removeUnreferencedBackups()
            return nil
        case .connected:
            throw ClaudeStatusLineConnectionError.managedFilesConflict
        }
    }

    private func statusLineMatchesOriginal(
        _ current: SupportedStatusLine,
        metadata: DecodedMetadata
    ) -> Bool {
        switch (current, metadata.originalStatusLine) {
        case (.absent, nil):
            return true
        case let (.existing(fragment, _), .some(original)):
            return Self.jsonEqual(fragment, original)
        default:
            return false
        }
    }

    private func repairManagedConnection(
        currentStatusLine: [String: Any],
        settingsSnapshot: SettingsSnapshot,
        helperData: Data
    ) throws -> ClaudeStatusLineConnectionState {
        guard let metadataFile = try readManagedFileForMutation(
            at: paths.metadataURL
        ) else {
            throw ClaudeStatusLineConnectionError.repairUnavailable
        }
        let decodedMetadata: DecodedMetadata
        do {
            decodedMetadata = try decodeMetadata(metadataFile.data)
        } catch {
            throw ClaudeStatusLineConnectionError.repairUnavailable
        }
        guard Self.jsonEqual(
            currentStatusLine,
            decodedMetadata.installedStatusLine
        ) else {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        }
        do {
            _ = try directoryIsHealthy(paths.managedDirectoryURL)
            _ = try directoryIsHealthy(paths.backupsDirectoryURL)
            guard try originalBackupIsValid(decodedMetadata) else {
                throw ClaudeStatusLineConnectionError.repairUnavailable
            }
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }

        let helperDigest = Self.sha256(helperData)
        let isHealthy: Bool
        do {
            let settingsFile = SecureFile(
                data: settingsSnapshot.data ?? Data(),
                fingerprint: settingsSnapshot.fingerprint,
                permissions: settingsSnapshot.permissions
            )
            isHealthy = try managedFilesAreHealthy(
                settingsFile: settingsFile,
                metadataFile: metadataFile,
                metadata: decodedMetadata
            ) && decodedMetadata.value.phase == .connected
                && decodedMetadata.value.collectorSHA256 == helperDigest
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        if isHealthy {
            return ClaudeStatusLineConnectionState(
                configuration: .managedConnected,
                cache: inspectCache()
            )
        }

        try prepareDirectories()
        try validateSettingsUnchanged(settingsSnapshot)
        do {
            try upsertManagedFile(
                helperData,
                to: paths.collectorScriptURL,
                permissions: Self.scriptPermissions
            )
            try upsertManagedFile(
                Self.wrapperData,
                to: paths.wrapperScriptURL,
                permissions: Self.scriptPermissions
            )
            if decodedMetadata.value.storesOriginalCommand {
                guard let originalCommand = decodedMetadata.originalCommand else {
                    throw ClaudeStatusLineConnectionError.repairUnavailable
                }
                try upsertManagedFile(
                    Data(originalCommand.utf8),
                    to: paths.originalCommandURL,
                    permissions: Self.privateFilePermissions
                )
            } else {
                try removeOwnedFileIfPresent(at: paths.originalCommandURL)
            }

            let updatedMetadata = Self.metadata(
                decodedMetadata.value,
                phase: .connected,
                collectorSHA256: helperDigest
            )
            try upsertManagedFile(
                try Self.encodeMetadata(updatedMetadata),
                to: paths.metadataURL,
                permissions: Self.privateFilePermissions
            )
            if settingsSnapshot.permissions != Self.privateFilePermissions,
               let settingsData = settingsSnapshot.data {
                try atomicWriteSettings(
                    settingsData,
                    replacing: settingsSnapshot
                )
            } else {
                try validateSettingsUnchanged(settingsSnapshot)
            }
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch SecureFileError.changed {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }

        let configuration = try inspectConfiguration()
        guard configuration == .managedConnected else {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        return ClaudeStatusLineConnectionState(
            configuration: configuration,
            cache: inspectCache()
        )
    }

    private func requireManagedTargetsAbsent() throws {
        for url in [
            paths.collectorScriptURL,
            paths.wrapperScriptURL,
            paths.originalCommandURL,
            paths.metadataURL,
        ] {
            do {
                if try secureReadOwnedRegularFile(at: url) != nil {
                    throw ClaudeStatusLineConnectionError.managedFilesConflict
                }
            } catch SecureFileError.unsafe {
                throw ClaudeStatusLineConnectionError.unsafeTarget
            } catch let error as ClaudeStatusLineConnectionError {
                throw error
            } catch {
                throw ClaudeStatusLineConnectionError.fileOperationFailed
            }
        }
    }

    // MARK: - Settings and metadata

    private enum SupportedStatusLine {
        case absent
        case existing([String: Any], command: String)
    }

    private func readSettingsForMutation() throws -> SettingsSnapshot {
        do {
            guard try settingsDirectoryExistsAndIsSafe() else {
                return SettingsSnapshot(
                    data: nil,
                    fingerprint: nil,
                    permissions: nil
                )
            }
            guard let file = try secureReadOwnedRegularFile(at: paths.settingsURL)
            else {
                return SettingsSnapshot(
                    data: nil,
                    fingerprint: nil,
                    permissions: nil
                )
            }
            return SettingsSnapshot(
                data: file.data,
                fingerprint: file.fingerprint,
                permissions: file.permissions
            )
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch SecureFileError.changed {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
    }

    private func parseSettingsForMutation(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            return try Self.parseSettings(data)
        } catch {
            throw ClaudeStatusLineConnectionError.invalidSettings
        }
    }

    private func supportedStatusLineForMutation(
        in root: [String: Any]
    ) throws -> SupportedStatusLine {
        guard let rawStatusLine = root["statusLine"] else {
            return .absent
        }
        guard let statusLine = rawStatusLine as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.isEmpty
        else {
            throw ClaudeStatusLineConnectionError.unsupportedStatusLine
        }
        return .existing(statusLine, command: command)
    }

    private static func parseSettings(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InspectionError.invalidSettings
        }
        guard let root = object as? [String: Any] else {
            throw InspectionError.invalidSettings
        }
        return root
    }

    private func makeMetadata(
        originalStatusLine: [String: Any]?,
        installedStatusLine: [String: Any],
        storesOriginalCommand: Bool,
        collectorSHA256: String,
        installedAt: Date,
        phase: ConnectionPhase,
        originalSettingsBackup: BackupReference?
    ) throws -> ConnectionMetadata {
        ConnectionMetadata(
            version: Self.metadataVersion,
            phase: phase,
            originalStatusLineJSONBase64: try originalStatusLine.map {
                try Self.canonicalJSON($0).base64EncodedString()
            },
            installedStatusLineJSONBase64: try Self
                .canonicalJSON(installedStatusLine)
                .base64EncodedString(),
            storesOriginalCommand: storesOriginalCommand,
            collectorSHA256: collectorSHA256,
            installedAt: installedAt.timeIntervalSince1970,
            originalSettingsBackupFileName: originalSettingsBackup?.fileName,
            originalSettingsSHA256: originalSettingsBackup?.sha256
        )
    }

    private func decodeMetadata(_ data: Data) throws -> DecodedMetadata {
        let value = try JSONDecoder().decode(ConnectionMetadata.self, from: data)
        guard value.version == Self.metadataVersion,
              (value.originalSettingsBackupFileName == nil)
                  == (value.originalSettingsSHA256 == nil),
              let installedData = Data(
                  base64Encoded: value.installedStatusLineJSONBase64
              ),
              let installed = try Self.decodeJSONObject(installedData)
        else {
            throw MetadataError.invalid
        }

        let original: [String: Any]?
        if let encodedOriginal = value.originalStatusLineJSONBase64 {
            guard let originalData = Data(base64Encoded: encodedOriginal),
                  let decodedOriginal = try Self.decodeJSONObject(originalData)
            else {
                throw MetadataError.invalid
            }
            original = decodedOriginal
        } else {
            original = nil
        }

        let originalCommand = original?["command"] as? String
        let shouldStoreOriginal = originalCommand != nil
            && originalCommand != Self.legacyCommand
        var expectedInstalled = original ?? ["type": "command"]
        expectedInstalled["command"] = Self.managedCommand
        let originalIsSupported = original == nil || (
            original?["type"] as? String == "command"
                && originalCommand?.isEmpty == false
        )
        guard installed["type"] as? String == "command",
              installed["command"] as? String == Self.managedCommand,
              originalIsSupported,
              Self.jsonEqual(installed, expectedInstalled),
              shouldStoreOriginal == value.storesOriginalCommand
        else {
            throw MetadataError.invalid
        }
        return DecodedMetadata(
            value: value,
            originalStatusLine: original,
            installedStatusLine: installed,
            originalCommand: originalCommand
        )
    }

    private func readMetadataForMutation() throws -> DecodedMetadata {
        let file: SecureFile
        do {
            guard let found = try readManagedFileForMutation(at: paths.metadataURL)
            else {
                throw ClaudeStatusLineConnectionError.repairUnavailable
            }
            file = found
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
        do {
            return try decodeMetadata(file.data)
        } catch {
            throw ClaudeStatusLineConnectionError.repairUnavailable
        }
    }

    // MARK: - Filesystem safety and atomic writes

    private func prepareDirectories() throws {
        let settingsDirectory = paths.settingsURL.deletingLastPathComponent()
        do {
            try ensureOwnedDirectory(
                settingsDirectory,
                enforcePrivatePermissions: false
            )
            try ensureOwnedDirectory(
                paths.managedDirectoryURL,
                enforcePrivatePermissions: true
            )
            try ensureOwnedDirectory(
                paths.backupsDirectoryURL,
                enforcePrivatePermissions: true
            )
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
    }

    private func settingsDirectoryExistsAndIsSafe() throws -> Bool {
        let directoryURL = paths.settingsURL.deletingLastPathComponent()
        guard let info = try lstatInfo(at: directoryURL) else { return false }
        guard info.isDirectory, info.owner == UInt32(geteuid()) else {
            throw SecureFileError.unsafe
        }
        guard info.permissions & 0o022 == 0 else {
            throw SecureFileError.unsafe
        }
        return true
    }

    private func ensureOwnedDirectory(
        _ url: URL,
        enforcePrivatePermissions: Bool
    ) throws {
        if let info = try lstatInfo(at: url) {
            guard info.isDirectory,
                  info.owner == UInt32(geteuid()),
                  info.permissions & 0o022 == 0
            else {
                throw SecureFileError.unsafe
            }
            if enforcePrivatePermissions,
               info.permissions != Self.privateDirectoryPermissions {
                try setPermissions(Self.privateDirectoryPermissions, at: url)
            }
            return
        }

        let parent = url.deletingLastPathComponent()
        guard let parentInfo = try lstatInfo(at: parent),
              parentInfo.isDirectory,
              parentInfo.owner == UInt32(geteuid()),
              parentInfo.permissions & 0o022 == 0
        else {
            throw SecureFileError.unsafe
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: Self.privateDirectoryPermissions,
            ]
        )
        guard let created = try lstatInfo(at: url),
              created.isDirectory,
              created.owner == UInt32(geteuid())
        else {
            throw SecureFileError.unsafe
        }
        try setPermissions(Self.privateDirectoryPermissions, at: url)
    }

    private func directoryIsHealthy(_ url: URL) throws -> Bool {
        guard let info = try lstatInfo(at: url) else { return false }
        guard info.isDirectory,
              info.owner == UInt32(geteuid()),
              info.permissions & 0o022 == 0
        else {
            throw SecureFileError.unsafe
        }
        return info.permissions == Self.privateDirectoryPermissions
    }

    private func createBackup(_ data: Data) throws -> BackupReference {
        let milliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let filename = "settings-\(milliseconds)-\(UUID().uuidString).json"
        let backupURL = paths.backupsDirectoryURL
            .appendingPathComponent(filename, isDirectory: false)
        try writeNewManagedFile(
            data,
            to: backupURL,
            permissions: Self.privateFilePermissions
        )
        return BackupReference(
            fileName: filename,
            sha256: Self.sha256(data)
        )
    }

    private func writeNewManagedFile(
        _ data: Data,
        to url: URL,
        permissions: Int
    ) throws {
        try atomicWrite(
            data,
            to: url,
            permissions: permissions,
            expectation: .missing,
            beforeCommit: {}
        )
    }

    private func upsertManagedFile(
        _ data: Data,
        to url: URL,
        permissions: Int
    ) throws {
        let expectation: WriteExpectation
        if let current = try readManagedFileForMutation(at: url) {
            if current.data == data, current.permissions == permissions {
                return
            }
            guard let fingerprint = current.fingerprint else {
                throw ClaudeStatusLineConnectionError.fileOperationFailed
            }
            expectation = .existing(fingerprint, current.data)
        } else {
            expectation = .missing
        }
        try atomicWrite(
            data,
            to: url,
            permissions: permissions,
            expectation: expectation,
            beforeCommit: {}
        )
    }

    private func atomicWriteSettings(
        _ data: Data,
        replacing snapshot: SettingsSnapshot
    ) throws {
        let expectation: WriteExpectation
        if let fingerprint = snapshot.fingerprint,
           let originalData = snapshot.data {
            expectation = .existing(fingerprint, originalData)
        } else {
            expectation = .missing
        }
        do {
            try atomicWrite(
                data,
                to: paths.settingsURL,
                permissions: Self.privateFilePermissions,
                expectation: expectation,
                beforeCommit: { [self] in
                    try validateSettingsUnchanged(snapshot)
                }
            )
        } catch SecureFileError.changed {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
    }

    private func atomicWrite(
        _ data: Data,
        to url: URL,
        permissions: Int,
        expectation: WriteExpectation,
        beforeCommit: () throws -> Void
    ) throws {
        let parent = url.deletingLastPathComponent()
        guard let parentInfo = try lstatInfo(at: parent),
              parentInfo.isDirectory,
              parentInfo.owner == UInt32(geteuid())
        else {
            throw SecureFileError.unsafe
        }

        let temporaryURL = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var shouldRemoveTemporary = true
        do {
            try writeExclusiveFile(
                data,
                to: temporaryURL,
                permissions: permissions
            )
            try beforeCommit()
            try validate(expectation, at: url)
            switch expectation {
            case .missing:
                guard rename(
                    temporaryURL,
                    url,
                    flags: UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw errno == EEXIST || errno == ENOTEMPTY
                        ? SecureFileError.changed
                        : SecureFileError.io
                }
            case .existing(let expectedFingerprint, let expectedData):
                guard rename(
                    temporaryURL,
                    url,
                    flags: UInt32(RENAME_SWAP)
                ) == 0 else {
                    throw errno == ENOENT
                        ? SecureFileError.changed
                        : SecureFileError.io
                }
                do {
                    guard let previous = try secureReadOwnedRegularFile(
                        at: temporaryURL
                    ),
                          previous.fingerprint == expectedFingerprint
                            && previous.data == expectedData
                    else {
                        throw SecureFileError.changed
                    }
                    try removeOwnedFileIfPresent(at: temporaryURL)
                } catch {
                    shouldRemoveTemporary = rename(
                        temporaryURL,
                        url,
                        flags: UInt32(RENAME_SWAP)
                    ) == 0
                    throw error
                }
            }
            guard let installed = try lstatInfo(at: url),
                  installed.isRegular,
                  installed.owner == UInt32(geteuid()),
                  installed.linkCount == 1,
                  installed.permissions == permissions
            else {
                throw SecureFileError.unsafe
            }
            try syncDirectory(parent)
        } catch {
            if shouldRemoveTemporary {
                try? removeOwnedFileIfPresent(at: temporaryURL)
            }
            throw error
        }
    }

    private func rename(_ source: URL, _ destination: URL, flags: UInt32) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                return Darwin.renamex_np(sourcePath, destinationPath, flags)
            }
        }
    }

    private func writeExclusiveFile(
        _ data: Data,
        to url: URL,
        permissions: Int
    ) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(permissions)
            )
        }
        guard descriptor >= 0 else { throw SecureFileError.io }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }

        let writeSucceeded = data.withUnsafeBytes { rawBuffer -> Bool in
            guard var address = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                address = address.advanced(by: written)
            }
            return true
        }
        guard writeSucceeded,
              Darwin.fchmod(descriptor, mode_t(permissions)) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.close(descriptor) == 0
        else {
            throw SecureFileError.io
        }
        shouldClose = false
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw SecureFileError.io }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == geteuid(),
              Darwin.fsync(descriptor) == 0
        else {
            throw SecureFileError.unsafe
        }
    }

    private func validateSettingsUnchanged(_ snapshot: SettingsSnapshot) throws {
        let current = try secureReadOwnedRegularFile(at: paths.settingsURL)
        switch (snapshot.data, snapshot.fingerprint, current) {
        case (nil, nil, nil):
            return
        case let (.some(expectedData), .some(expectedFingerprint), .some(file))
            where expectedData == file.data
                && expectedFingerprint == file.fingerprint:
            return
        default:
            throw SecureFileError.changed
        }
    }

    private func removeSettingsIfUnchanged(_ snapshot: SettingsSnapshot) throws {
        do {
            try validateSettingsUnchanged(snapshot)
            guard let expectedData = snapshot.data,
                  let expectedFingerprint = snapshot.fingerprint,
                  let current = try secureReadOwnedRegularFile(
                      at: paths.settingsURL
                  ),
                  current.data == expectedData,
                  current.fingerprint == expectedFingerprint
            else {
                throw SecureFileError.changed
            }
            try removeOwnedFileIfPresent(at: paths.settingsURL)
        } catch SecureFileError.changed {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch let error as ClaudeStatusLineConnectionError {
            throw error
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
    }

    private func validate(_ expectation: WriteExpectation, at url: URL) throws {
        let info = try lstatInfo(at: url)
        switch expectation {
        case .missing:
            guard info == nil else {
                if let info,
                   (!info.isRegular || info.owner != UInt32(geteuid())
                       || info.linkCount != 1) {
                    throw SecureFileError.unsafe
                }
                throw SecureFileError.changed
            }
        case .existing(let expected, _):
            guard let info,
                  info.isRegular,
                  info.owner == UInt32(geteuid()),
                  info.linkCount == 1
            else {
                throw info == nil ? SecureFileError.changed : .unsafe
            }
            guard info.fingerprint == expected else {
                throw SecureFileError.changed
            }
        }
    }

    private func secureReadOwnedRegularFile(at url: URL) throws -> SecureFile? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw SecureFileError.unsafe }
            throw SecureFileError.io
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              value.st_nlink == 1
        else {
            throw SecureFileError.unsafe
        }
        let fingerprint = FileFingerprint(value)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw SecureFileError.io
        }
        guard let pathInfo = try lstatInfo(at: url),
              pathInfo.isRegular,
              pathInfo.owner == UInt32(geteuid()),
              pathInfo.fingerprint == fingerprint
        else {
            throw SecureFileError.changed
        }
        return SecureFile(
            data: data,
            fingerprint: fingerprint,
            permissions: Int(value.st_mode & 0o777)
        )
    }

    private func readManagedFileForMutation(at url: URL) throws -> SecureFile? {
        do {
            guard let directory = try lstatInfo(at: paths.managedDirectoryURL)
            else {
                return nil
            }
            guard directory.isDirectory,
                  directory.owner == UInt32(geteuid())
            else {
                throw SecureFileError.unsafe
            }
            return try secureReadOwnedRegularFile(at: url)
        } catch SecureFileError.unsafe {
            throw ClaudeStatusLineConnectionError.unsafeTarget
        } catch SecureFileError.changed {
            throw ClaudeStatusLineConnectionError.settingsChangedExternally
        } catch {
            throw ClaudeStatusLineConnectionError.fileOperationFailed
        }
    }

    private func removeOwnedFileIfPresent(at url: URL) throws {
        guard let info = try lstatInfo(at: url) else { return }
        guard info.isRegular,
              info.owner == UInt32(geteuid()),
              info.linkCount == 1
        else {
            throw SecureFileError.unsafe
        }
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.unlink(path)
        }
        guard result == 0 else { throw SecureFileError.io }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func cleanupManagedArtifacts(_ metadata: DecodedMetadata) throws {
        try removeOwnedFileIfPresent(at: paths.originalCommandURL)
        try removeOwnedFileIfPresent(at: paths.collectorScriptURL)
        try removeOwnedFileIfPresent(at: paths.wrapperScriptURL)
        try removeOwnedFileIfPresent(at: paths.metadataURL)
        if let backupURL = originalBackupURL(metadata) {
            try removeOwnedFileIfPresent(at: backupURL)
        }
    }

    private func originalBackupURL(_ metadata: DecodedMetadata) -> URL? {
        guard let fileName = metadata.value.originalSettingsBackupFileName,
              !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else {
            return nil
        }
        return paths.backupsDirectoryURL
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func removeUnreferencedBackups() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: paths.backupsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls where url.lastPathComponent.hasPrefix("settings-")
            && url.pathExtension == "json" {
            try removeOwnedFileIfPresent(at: url)
        }
    }

    private func lstatInfo(at url: URL) throws -> FileInfo? {
        var value = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw SecureFileError.io
        }
        return FileInfo(value)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chmod(path, mode_t(permissions))
        }
        guard result == 0 else { throw SecureFileError.io }
        guard let updated = try lstatInfo(at: url),
              !updated.isSymbolicLink,
              updated.owner == UInt32(geteuid()),
              updated.permissions == permissions
        else {
            throw SecureFileError.unsafe
        }
    }

    // MARK: - Pure helpers

    private nonisolated static func loadBundledHelper() throws -> Data {
        let bundle = Bundle.main
        let url = bundle.url(
            forResource: "claude-statusline-aiusage",
            withExtension: "sh"
        ) ?? bundle.url(
            forResource: "claude-statusline-aiusage",
            withExtension: "sh",
            subdirectory: "Scripts"
        )
        guard let url else {
            throw ClaudeStatusLineConnectionError.helperUnavailable
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private nonisolated static func encodeSettings(
        _ root: [String: Any]
    ) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private nonisolated static func canonicalJSON(
        _ object: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private nonisolated static func decodeJSONObject(
        _ data: Data
    ) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private nonisolated static func jsonEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        guard let left = try? canonicalJSON(lhs),
              let right = try? canonicalJSON(rhs)
        else {
            return false
        }
        return left == right
    }

    private nonisolated static func encodeMetadata(
        _ metadata: ConnectionMetadata
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(metadata)
        data.append(0x0A)
        return data
    }

    private nonisolated static func metadata(
        _ value: ConnectionMetadata,
        phase: ConnectionPhase,
        collectorSHA256: String? = nil
    ) -> ConnectionMetadata {
        ConnectionMetadata(
            version: value.version,
            phase: phase,
            originalStatusLineJSONBase64:
                value.originalStatusLineJSONBase64,
            installedStatusLineJSONBase64:
                value.installedStatusLineJSONBase64,
            storesOriginalCommand: value.storesOriginalCommand,
            collectorSHA256: collectorSHA256 ?? value.collectorSHA256,
            installedAt: value.installedAt,
            originalSettingsBackupFileName:
                value.originalSettingsBackupFileName,
            originalSettingsSHA256: value.originalSettingsSHA256
        )
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static let wrapperData = Data(
        #"""
        #!/bin/zsh

        set -u

        collector="$HOME/.claude/aiusage/statusline-cache.sh"
        original_file="$HOME/.claude/aiusage/original-statusline-command"

        input="$(/bin/cat; /usr/bin/printf '\036')"
        input="${input%$'\036'}"

        if [[ -x "$collector" ]]; then
          /usr/bin/printf '%s' "$input" | "$collector" >/dev/null 2>&1 || true
        fi

        if [[ -f "$original_file" ]]; then
          original_command="$(/bin/cat "$original_file" 2>/dev/null; /usr/bin/printf '\036')"
          original_command="${original_command%$'\036'}"
          /usr/bin/printf '%s' "$input" | /bin/sh -c "$original_command"
          original_status=$?
          exit "$original_status"
        fi

        exit 0
        """#.utf8
    )
}

private enum InspectionError: Error {
    case invalidSettings
    case unsupportedStatusLine
}

private enum MetadataError: Error {
    case invalid
}

private enum SecureFileError: Error {
    case unsafe
    case changed
    case io
}

private enum WriteExpectation {
    case missing
    case existing(FileFingerprint, Data)
}

private struct SettingsSnapshot {
    let data: Data?
    let fingerprint: FileFingerprint?
    let permissions: Int?
}

private struct SecureFile {
    let data: Data
    let fingerprint: FileFingerprint?
    let permissions: Int?

    init(data: Data, fingerprint: FileFingerprint, permissions: Int) {
        self.data = data
        self.fingerprint = fingerprint
        self.permissions = permissions
    }

    init(data: Data, fingerprint: FileFingerprint?, permissions: Int?) {
        self.data = data
        self.fingerprint = fingerprint
        self.permissions = permissions
    }
}

private struct FileFingerprint: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let owner: UInt32
    let mode: UInt32

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        owner = UInt32(value.st_uid)
        mode = UInt32(value.st_mode)
    }
}

private struct FileInfo {
    let fingerprint: FileFingerprint
    let owner: UInt32
    let permissions: Int
    let linkCount: UInt64
    let kind: mode_t

    init(_ value: stat) {
        fingerprint = FileFingerprint(value)
        owner = UInt32(value.st_uid)
        permissions = Int(value.st_mode & 0o777)
        linkCount = UInt64(value.st_nlink)
        kind = value.st_mode & S_IFMT
    }

    var isRegular: Bool { kind == S_IFREG }
    var isDirectory: Bool { kind == S_IFDIR }
    var isSymbolicLink: Bool { kind == S_IFLNK }
}

private struct ConnectionMetadata: Codable {
    let version: Int
    let phase: ConnectionPhase
    let originalStatusLineJSONBase64: String?
    let installedStatusLineJSONBase64: String
    let storesOriginalCommand: Bool
    let collectorSHA256: String
    let installedAt: TimeInterval
    let originalSettingsBackupFileName: String?
    let originalSettingsSHA256: String?
}

private enum ConnectionPhase: String, Codable {
    case prepared
    case connected
    case disconnectPrepared
}

private struct BackupReference {
    let fileName: String
    let sha256: String
}

private struct DecodedMetadata {
    let value: ConnectionMetadata
    let originalStatusLine: [String: Any]?
    let installedStatusLine: [String: Any]
    let originalCommand: String?
}
