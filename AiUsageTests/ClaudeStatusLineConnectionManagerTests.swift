import Foundation
import XCTest
@testable import AiUsage

final class ClaudeStatusLineConnectionManagerTests: XCTestCase {
    func testConnectCreatesMissingSettingsWithoutOriginalCommand() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }

        let state = try await fixture.manager.connect()
        let settings = try fixture.readSettings()
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])

        XCTAssertEqual(state.configuration, .managedConnected)
        XCTAssertEqual(state.cache, .notReceived)
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(
            statusLine["command"] as? String,
            ClaudeStatusLineConnectionManager.managedCommand
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.originalCommandURL.path
            )
        )
    }

    func testDisconnectRemovesSettingsThatDidNotExistBeforeConnection() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        _ = try await fixture.manager.connect()

        let state = try await fixture.manager.disconnect()

        XCTAssertEqual(state.configuration, .disconnected)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.paths.settingsURL.path)
        )
    }

    func testConnectPreservesUnrelatedTopLevelKeys() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "alwaysThinkingEnabled": true,
            "env": ["SAFE_FLAG": "enabled"],
            "permissions": ["allow": ["Read", "Glob"]],
        ])

        _ = try await fixture.manager.connect()
        let settings = try fixture.readSettings()

        XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual(
            (settings["env"] as? [String: Any])?["SAFE_FLAG"] as? String,
            "enabled"
        )
        XCTAssertEqual(
            ((settings["permissions"] as? [String: Any])?["allow"] as? [String]),
            ["Read", "Glob"]
        )
    }

    func testForeignCommandRoundTripsAndWrapperPreservesIOAndExitStatus() async throws {
        let fixture = try StatusLineFixture(helperData: Self.noisyHelperData)
        defer { fixture.remove() }
        let originalCommand =
            #"/bin/cat; /usr/bin/printf 'original-error' >&2; exit 23"#
        try fixture.writeSettings([
            "theme": "dark",
            "statusLine": [
                "type": "command",
                "command": originalCommand,
                "refreshInterval": 7,
                "custom": ["kept": true],
            ],
        ])

        let before = await fixture.manager.inspect()
        XCTAssertEqual(
            before.configuration,
            .foreignStatusLineMergeAvailable
        )

        _ = try await fixture.manager.connect()
        let connectedSettings = try fixture.readSettings()
        let connectedStatusLine = try XCTUnwrap(
            connectedSettings["statusLine"] as? [String: Any]
        )
        XCTAssertEqual(connectedStatusLine["refreshInterval"] as? Int, 7)
        XCTAssertEqual(
            (connectedStatusLine["custom"] as? [String: Any])?["kept"] as? Bool,
            true
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.originalCommandURL),
            Data(originalCommand.utf8)
        )

        let input = Data("first\nsecond\n\n".utf8)
        let processResult = try fixture.runWrapper(input: input)
        XCTAssertEqual(processResult.output, input)
        XCTAssertEqual(processResult.error, Data("original-error".utf8))
        XCTAssertEqual(processResult.status, 23)

        var externallyUpdated = connectedSettings
        externallyUpdated["changedWhileConnected"] = "preserve-me"
        try fixture.writeSettings(externallyUpdated)
        let disconnected = try await fixture.manager.disconnect()
        let restored = try fixture.readSettings()
        let restoredStatusLine = try XCTUnwrap(
            restored["statusLine"] as? [String: Any]
        )

        XCTAssertEqual(
            disconnected.configuration,
            .foreignStatusLineMergeAvailable
        )
        XCTAssertEqual(restored["theme"] as? String, "dark")
        XCTAssertEqual(
            restored["changedWhileConnected"] as? String,
            "preserve-me"
        )
        XCTAssertEqual(restoredStatusLine["command"] as? String, originalCommand)
        XCTAssertEqual(restoredStatusLine["refreshInterval"] as? Int, 7)
        XCTAssertEqual(
            (restoredStatusLine["custom"] as? [String: Any])?["kept"] as? Bool,
            true
        )
    }

    func testInvalidJSONDoesNotMutateAnything() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        let invalid = Data(#"{"statusLine":{"type":"command""#.utf8)
        try fixture.writeRawSettings(invalid)

        do {
            _ = try await fixture.manager.connect()
            XCTFail("Invalid settings must block connection.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .invalidSettings
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.settingsURL), invalid)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.managedDirectoryURL.path
            )
        )
        let state = await fixture.manager.inspect()
        XCTAssertEqual(state.configuration, .blocked(.invalidSettings))
    }

    func testMissingBundledHelperDoesNotMutateSettings() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        let original = Data(#"{"custom":"unchanged"}"#.utf8)
        try fixture.writeRawSettings(original)
        let manager = ClaudeStatusLineConnectionManager(
            paths: fixture.paths,
            helperLoader: { throw MissingHelperFixtureError.missing }
        )

        do {
            _ = try await manager.connect()
            XCTFail("A missing bundled helper must fail before filesystem changes.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .helperUnavailable
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.settingsURL), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.managedDirectoryURL.path
            )
        )
    }

    func testLegacyConnectionIsDetectedMigratedAndRestoredWithoutChaining() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "statusLine": [
                "type": "command",
                "command": ClaudeStatusLineConnectionManager.legacyCommand,
                "refreshInterval": 10,
            ],
        ])

        let legacyState = await fixture.manager.inspect()
        XCTAssertEqual(
            legacyState.configuration,
            .legacyDirectAiUsageConnected
        )

        let connected = try await fixture.manager.connect()
        XCTAssertEqual(connected.configuration, .managedConnected)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.originalCommandURL.path
            )
        )

        _ = try await fixture.manager.disconnect()
        let restored = try fixture.readSettings()
        let statusLine = try XCTUnwrap(restored["statusLine"] as? [String: Any])
        XCTAssertEqual(
            statusLine["command"] as? String,
            ClaudeStatusLineConnectionManager.legacyCommand
        )
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 10)
    }

    func testConnectIsIdempotentAndRepairsMissingWrapper() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }

        _ = try await fixture.manager.connect()
        let firstSettings = try Data(contentsOf: fixture.paths.settingsURL)
        let firstMetadata = try Data(contentsOf: fixture.paths.metadataURL)

        let idempotent = try await fixture.manager.connect()
        XCTAssertEqual(idempotent.configuration, .managedConnected)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            firstSettings
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.metadataURL),
            firstMetadata
        )

        try FileManager.default.removeItem(at: fixture.paths.wrapperScriptURL)
        let damaged = await fixture.manager.inspect()
        XCTAssertEqual(damaged.configuration, .repairRequired)

        let repaired = try await fixture.manager.connect()
        XCTAssertEqual(repaired.configuration, .managedConnected)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.wrapperScriptURL.path
            )
        )
    }

    func testNewBundledHelperIsOfferedAndUpdatesWithoutChangingSettings() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "custom": "preserved",
            "statusLine": [
                "type": "command",
                "command": #"/usr/bin/printf 'original'"#,
            ],
        ])
        _ = try await fixture.manager.connect()
        let connectedSettings = try Data(contentsOf: fixture.paths.settingsURL)
        let originalBackup = try fixture.onlyBackupContents()
        let upgradedHelper = Data("#!/bin/zsh\nexit 7\n".utf8)
        let upgradedManager = fixture.manager(helperData: upgradedHelper)

        let available = await upgradedManager.inspect()

        XCTAssertEqual(available.configuration, .managedUpdateAvailable)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.collectorScriptURL),
            StatusLineFixture.quietHelperData
        )

        let updated = try await upgradedManager.connect()

        XCTAssertEqual(updated.configuration, .managedConnected)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.collectorScriptURL),
            upgradedHelper
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            connectedSettings
        )
        XCTAssertEqual(try fixture.onlyBackupContents(), originalBackup)

        _ = try await upgradedManager.disconnect()
        let restored = try fixture.readSettings()
        let restoredStatusLine = try XCTUnwrap(
            restored["statusLine"] as? [String: Any]
        )
        XCTAssertEqual(restored["custom"] as? String, "preserved")
        XCTAssertEqual(
            restoredStatusLine["command"] as? String,
            #"/usr/bin/printf 'original'"#
        )
    }

    func testTamperedCollectorRequiresRepairEvenWhenBundleHasAnUpdate() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        _ = try await fixture.manager.connect()
        try Data("tampered".utf8).write(
            to: fixture.paths.collectorScriptURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.paths.collectorScriptURL.path
        )
        let upgradedManager = fixture.manager(
            helperData: Data("#!/bin/zsh\nexit 8\n".utf8)
        )

        let state = await upgradedManager.inspect()

        XCTAssertEqual(state.configuration, .repairRequired)
    }

    func testInterruptedHelperUpdateRecoversWithoutChangingRestoreData() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "statusLine": [
                "type": "command",
                "command": #"/usr/bin/printf 'original'"#,
            ],
        ])
        _ = try await fixture.manager.connect()
        let connectedSettings = try Data(contentsOf: fixture.paths.settingsURL)
        let originalBackup = try fixture.onlyBackupContents()
        let upgradedHelper = Data("#!/bin/zsh\nexit 9\n".utf8)
        let upgradedManager = fixture.manager(helperData: upgradedHelper)

        try upgradedHelper.write(
            to: fixture.paths.collectorScriptURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.paths.collectorScriptURL.path
        )
        let interrupted = await upgradedManager.inspect()
        XCTAssertEqual(interrupted.configuration, .repairRequired)

        let recovered = try await upgradedManager.connect()

        XCTAssertEqual(recovered.configuration, .managedConnected)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            connectedSettings
        )
        XCTAssertEqual(try fixture.onlyBackupContents(), originalBackup)
    }

    func testInterruptedPreparedConnectResumesWithoutManagedFileConflict() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        _ = try await fixture.manager.connect()

        try fixture.setMetadataPhase("prepared")
        try FileManager.default.removeItem(at: fixture.paths.settingsURL)

        let interrupted = await fixture.manager.inspect()
        XCTAssertEqual(interrupted.configuration, .repairRequired)

        let resumed = try await fixture.manager.connect()
        XCTAssertEqual(resumed.configuration, .managedConnected)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path)
        )
        XCTAssertEqual(try fixture.metadataPhase(), "connected")
    }

    func testInterruptedDisconnectFinishesCleanupFromRestoredOriginalSettings() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        let originalCommand = #"/usr/bin/printf 'original'"#
        let originalSettings: [String: Any] = [
            "custom": "preserved",
            "statusLine": [
                "type": "command",
                "command": originalCommand,
                "refreshInterval": 11,
            ],
        ]
        try fixture.writeSettings(originalSettings)
        _ = try await fixture.manager.connect()

        try fixture.setMetadataPhase("disconnectPrepared")
        try fixture.writeSettings(originalSettings)
        let interrupted = await fixture.manager.inspect()
        XCTAssertEqual(interrupted.configuration, .repairRequired)

        let finished = try await fixture.manager.disconnect()
        XCTAssertEqual(
            finished.configuration,
            .foreignStatusLineMergeAvailable
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.wrapperScriptURL.path
            )
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.backupsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(backups.isEmpty)
    }

    func testConnectAfterInterruptedDisconnectCleansOrphanAndReconnects() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        let originalSettings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": #"/usr/bin/printf 'original'"#,
            ],
        ]
        try fixture.writeSettings(originalSettings)
        _ = try await fixture.manager.connect()
        try fixture.setMetadataPhase("disconnectPrepared")
        try fixture.writeSettings(originalSettings)

        let repaired = try await fixture.manager.connect()

        XCTAssertEqual(repaired.configuration, .managedConnected)
        XCTAssertEqual(try fixture.metadataPhase(), "connected")
        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.backupsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
    }

    func testDisconnectRefusesTamperedMetadataAndLeavesSettingsUntouched() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "statusLine": [
                "type": "command",
                "command": #"/usr/bin/printf 'original'"#,
            ],
        ])
        _ = try await fixture.manager.connect()
        let connectedSettings = try Data(contentsOf: fixture.paths.settingsURL)

        try fixture.replaceOriginalCommandInMetadata(
            with: #"/usr/bin/printf 'tampered'"#
        )
        let damaged = await fixture.manager.inspect()
        XCTAssertEqual(damaged.configuration, .repairRequired)

        do {
            _ = try await fixture.manager.disconnect()
            XCTFail("Tampered restore metadata must never be trusted.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .repairUnavailable
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            connectedSettings
        )
    }

    func testDisconnectRefusesInsecureMetadataPermissions() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        _ = try await fixture.manager.connect()
        let connectedSettings = try Data(contentsOf: fixture.paths.settingsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.paths.metadataURL.path
        )

        do {
            _ = try await fixture.manager.disconnect()
            XCTFail("Metadata with widened permissions must require repair.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .repairUnavailable
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            connectedSettings
        )
    }

    func testDisconnectRefusesExternallyChangedStatusLine() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        _ = try await fixture.manager.connect()

        var settings = try fixture.readSettings()
        var statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        statusLine["refreshInterval"] = 99
        settings["statusLine"] = statusLine
        try fixture.writeSettings(settings)
        let externallyChanged = try Data(contentsOf: fixture.paths.settingsURL)

        do {
            _ = try await fixture.manager.disconnect()
            XCTFail("Disconnect must not overwrite an externally changed statusLine.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .settingsChangedExternally
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.settingsURL),
            externallyChanged
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path)
        )
    }

    func testConnectBacksUpSettingsAndAppliesPrivatePermissions() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        let command = #"/usr/bin/printf 'private command'"#
        let original = Data(
            #"{"custom":true,"statusLine":{"type":"command","command":"/usr/bin/printf 'private command'"}}"#.utf8
        )
        try fixture.writeRawSettings(original)

        _ = try await fixture.manager.connect()

        XCTAssertEqual(try fixture.permissions(fixture.paths.settingsURL), 0o600)
        XCTAssertEqual(
            try fixture.permissions(fixture.paths.managedDirectoryURL),
            0o700
        )
        XCTAssertEqual(
            try fixture.permissions(fixture.paths.backupsDirectoryURL),
            0o700
        )
        XCTAssertEqual(
            try fixture.permissions(fixture.paths.collectorScriptURL),
            0o700
        )
        XCTAssertEqual(
            try fixture.permissions(fixture.paths.wrapperScriptURL),
            0o700
        )
        XCTAssertEqual(try fixture.permissions(fixture.paths.metadataURL), 0o600)
        XCTAssertEqual(
            try fixture.permissions(fixture.paths.originalCommandURL),
            0o600
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.originalCommandURL),
            Data(command.utf8)
        )

        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.backupsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backupURLs.count, 1)
        let backupURL = try XCTUnwrap(backupURLs.first)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertEqual(try fixture.permissions(backupURL), 0o600)
    }

    func testConnectRefusesSymlinkedSettingsWithoutFollowingIt() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.createClaudeDirectory()
        let externalURL = fixture.homeURL
            .appendingPathComponent("external-settings.json")
        let externalData = Data(#"{"external":"unchanged"}"#.utf8)
        try externalData.write(to: externalURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.settingsURL,
            withDestinationURL: externalURL
        )

        do {
            _ = try await fixture.manager.connect()
            XCTFail("A settings symlink must be refused.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeStatusLineConnectionError,
                .unsafeTarget
            )
        }

        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.managedDirectoryURL.path
            )
        )
    }

    func testInspectReportsCacheLifecycleWithoutReturningCacheContent() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }

        var state = await fixture.manager.inspect()
        XCTAssertEqual(state.configuration, .disconnected)
        XCTAssertEqual(state.cache, .notReceived)

        try fixture.writeCache(status: "waiting_for_first_response")
        state = await fixture.manager.inspect()
        XCTAssertEqual(state.cache, .waiting)

        try fixture.writeCache(status: "ready", includesRateLimits: true)
        state = await fixture.manager.inspect()
        XCTAssertEqual(state.cache, .received)

        try fixture.writeCache(status: "unsupported_account")
        state = await fixture.manager.inspect()
        XCTAssertEqual(state.cache, .unsupported)
    }

    func testManagedConnectionWaitsForCacheObservedAfterInstallation() async throws {
        let fixture = try StatusLineFixture()
        defer { fixture.remove() }
        try fixture.writeCache(
            status: "ready",
            includesRateLimits: true,
            capturedAt: 1_700_000_000
        )

        let connected = try await fixture.manager.connect()
        XCTAssertEqual(connected.cache, .notReceived)

        try fixture.writeCache(
            status: "ready",
            includesRateLimits: true,
            capturedAt: 1_750_000_000
        )
        let refreshed = await fixture.manager.inspect()
        XCTAssertEqual(refreshed.cache, .received)
    }

    private static let noisyHelperData = Data(
        #"""
        #!/bin/zsh
        /bin/cat >/dev/null
        /usr/bin/printf 'collector-output'
        /usr/bin/printf 'collector-error' >&2
        exit 9
        """#.utf8
    )
}

private enum MissingHelperFixtureError: Error {
    case missing
}

private struct StatusLineFixture {
    struct ProcessResult {
        let output: Data
        let error: Data
        let status: Int32
    }

    static let quietHelperData = Data(
        #"""
        #!/bin/zsh
        /bin/cat >/dev/null
        exit 0
        """#.utf8
    )

    let homeURL: URL
    let paths: ClaudeStatusLineConnectionPaths
    let manager: ClaudeStatusLineConnectionManager

    init(helperData: Data = Self.quietHelperData) throws {
        homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        paths = ClaudeStatusLineConnectionPaths(homeDirectoryURL: homeURL)
        manager = ClaudeStatusLineConnectionManager(
            paths: paths,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            helperLoader: { helperData }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: homeURL)
    }

    func createClaudeDirectory() throws {
        try FileManager.default.createDirectory(
            at: paths.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func writeSettings(_ root: [String: Any]) throws {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try writeRawSettings(data)
    }

    func writeRawSettings(_ data: Data) throws {
        try createClaudeDirectory()
        try data.write(to: paths.settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.settingsURL.path
        )
    }

    func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.settingsURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func writeCache(
        status: String,
        includesRateLimits: Bool = false,
        capturedAt: TimeInterval = 1_750_000_000
    ) throws {
        try createClaudeDirectory()
        var cache: [String: Any] = [
            "captured_at": capturedAt,
            "status": status,
        ]
        cache["rate_limits"] = includesRateLimits
            ? ["five_hour": ["used_percentage": 10, "resets_at": 1_800_000_000]]
            : NSNull()
        let data = try JSONSerialization.data(withJSONObject: cache)
        try data.write(to: paths.cacheURL, options: .atomic)
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    func runWrapper(input: Data) throws -> ProcessResult {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [paths.wrapperScriptURL.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        process.environment = environment

        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            output: output,
            error: error,
            status: process.terminationStatus
        )
    }

    func metadataPhase() throws -> String {
        let metadata = try readMetadata()
        return try XCTUnwrap(metadata["phase"] as? String)
    }

    func manager(helperData: Data) -> ClaudeStatusLineConnectionManager {
        ClaudeStatusLineConnectionManager(
            paths: paths,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            helperLoader: { helperData }
        )
    }

    func onlyBackupContents() throws -> Data {
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.backupsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(urls.count, 1)
        return try Data(contentsOf: XCTUnwrap(urls.first))
    }

    func setMetadataPhase(_ phase: String) throws {
        var metadata = try readMetadata()
        metadata["phase"] = phase
        try writeMetadata(metadata)
    }

    func replaceOriginalCommandInMetadata(with command: String) throws {
        var metadata = try readMetadata()
        let encoded = try XCTUnwrap(
            metadata["originalStatusLineJSONBase64"] as? String
        )
        let fragmentData = try XCTUnwrap(Data(base64Encoded: encoded))
        var fragment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fragmentData) as? [String: Any]
        )
        fragment["command"] = command
        let changed = try JSONSerialization.data(
            withJSONObject: fragment,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        metadata["originalStatusLineJSONBase64"] = changed.base64EncodedString()
        try writeMetadata(metadata)
    }

    private func readMetadata() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.metadataURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func writeMetadata(_ metadata: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: paths.metadataURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.metadataURL.path
        )
    }
}
