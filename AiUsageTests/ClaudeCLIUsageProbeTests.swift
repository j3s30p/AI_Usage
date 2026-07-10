import Darwin
import Foundation
import XCTest
@testable import AiUsage

final class ClaudeCLIUsageProbeTests: XCTestCase {
    func testParserExtractsUsedPercentagesAndResetDescriptions() throws {
        let fixture = """
        \u{001B}[2J\u{001B}[HSettings: Usage
        │ Current session
        │ █████░░░ 23.5% used
        │ Resets 2:00pm (Asia/Seoul) │
        │
        │ Current week (all models)
        │ ███████░ 48% used
        │ Resets Jul 14 at 9am (Asia/Seoul) │
        """

        let snapshot = try ClaudeCLIUsageProbe.parse(fixture)

        XCTAssertEqual(snapshot.sessionUsedPercentage, 23.5)
        XCTAssertEqual(snapshot.sessionResetDescription, "Resets 2:00pm (Asia/Seoul)")
        XCTAssertEqual(snapshot.weeklyUsedPercentage, 48)
        XCTAssertEqual(
            snapshot.weeklyResetDescription,
            "Resets Jul 14 at 9am (Asia/Seoul)"
        )
    }

    func testParserUsesLatestPanelAndDoesNotReuseOlderWeeklyWindow() throws {
        let fixture = """
        Settings: Usage
        Current session
        91% used
        Resets 1pm
        Current week (all models)
        88% used
        Resets Friday

        Opus | context 0%

        Settings: Usage
        Current session
        12% used
        Resets 4pm
        """

        let snapshot = try ClaudeCLIUsageProbe.parse(fixture)

        XCTAssertEqual(snapshot.sessionUsedPercentage, 12)
        XCTAssertEqual(snapshot.sessionResetDescription, "Resets 4pm")
        XCTAssertNil(snapshot.weeklyUsedPercentage)
        XCTAssertNil(snapshot.weeklyResetDescription)
    }

    func testParserRejectsOutputWithoutCurrentSessionUsage() {
        XCTAssertThrowsError(
            try ClaudeCLIUsageProbe.parse(
                "Current week (all models)\n20% used\nResets Friday"
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeCLIUsageProbeError, .invalidOutput)
        }
    }

    func testProbeBuildsPTYCommandAndSendsTrustEnterOnlyOnce() async throws {
        let fixture = """
        Do you trust the files in this folder?
        Settings: Usage
        Current session
        7% used
        Resets 5pm
        Current week (all models)
        19% used
        Resets Monday
        """
        let runner = RecordingClaudeCLIUsageRunner(
            outputChunks: [
                "Do you trust the files in this folder?",
                "Do you trust the files in this folder?\nLoading",
                fixture,
            ],
            result: ClaudeCLIUsageProcessResult(output: fixture, terminationStatus: 0)
        )
        let claudeURL = URL(fileURLWithPath: "/test/bin/claude")
        let scriptURL = URL(fileURLWithPath: "/test/usr/bin/script")
        let workingDirectoryURL = URL(fileURLWithPath: "/test/AiUsage/ClaudeProbe")
        let probe = ClaudeCLIUsageProbe(
            executableURL: claudeURL,
            scriptURL: scriptURL,
            timeout: 12,
            workingDirectoryURL: workingDirectoryURL,
            processRunner: runner
        )

        let snapshot = try await probe.fetchUsage()
        let recordedRequest = await runner.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        let inputs = await runner.inputs

        XCTAssertEqual(snapshot.sessionUsedPercentage, 7)
        XCTAssertEqual(request.executableURL, scriptURL)
        XCTAssertEqual(
            request.arguments,
            [
                "-q",
                "/dev/null",
                claudeURL.path,
                "/usage",
                "--allowed-tools",
                "",
                "--safe-mode",
                "--ax-screen-reader",
            ]
        )
        XCTAssertEqual(request.timeout, 12)
        XCTAssertEqual(request.currentDirectoryURL, workingDirectoryURL)
        XCTAssertEqual(inputs, [.enter, .finish])
    }

    func testProbeRecognizesModernQuickSafetyPrompt() async throws {
        let fixture = """
        Current session
        8% used
        Resets 6pm
        """
        let runner = RecordingClaudeCLIUsageRunner(
            outputChunks: [
                "Quick safety check: Is this a project you created or one you trust?",
                fixture,
            ],
            result: ClaudeCLIUsageProcessResult(output: fixture, terminationStatus: 0)
        )
        let probe = ClaudeCLIUsageProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        _ = try await probe.fetchUsage()

        let inputs = await runner.inputs
        XCTAssertEqual(inputs, [.enter, .finish])
    }

    func testIntentionalTerminationAfterCompleteOutputIsSuccessful() async throws {
        let fixture = """
        Current session
        66% 66% used
        Resets 2:59pm (Asia/Seoul)
        Current week (all models)
        7% 7% used
        Resets Jul 15 at 1:59am (Asia/Seoul)
        """
        let runner = RecordingClaudeCLIUsageRunner(
            outputChunks: [fixture],
            result: ClaudeCLIUsageProcessResult(
                output: fixture,
                terminationStatus: 15,
                completedByOutput: true
            )
        )
        let probe = ClaudeCLIUsageProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        let snapshot = try await probe.fetchUsage()
        let inputs = await runner.inputs

        XCTAssertEqual(snapshot.sessionUsedPercentage, 66)
        XCTAssertEqual(snapshot.weeklyUsedPercentage, 7)
        XCTAssertEqual(inputs, [.finish])
    }

    func testMissingExecutableDoesNotStartRunner() async {
        let runner = RecordingClaudeCLIUsageRunner(
            result: ClaudeCLIUsageProcessResult(output: "", terminationStatus: 0)
        )
        let probe = ClaudeCLIUsageProbe(
            executableURL: nil,
            processRunner: runner
        )

        do {
            _ = try await probe.fetchUsage()
            XCTFail("A missing Claude executable must fail before launching script.")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIUsageProbeError, .executableNotFound)
        }
        let request = await runner.lastRequest
        XCTAssertNil(request)
    }

    func testRunnerTimeoutIsPropagatedWithoutLeakingFixtureOutput() async {
        let runner = RecordingClaudeCLIUsageRunner(
            error: .timedOut,
            result: ClaudeCLIUsageProcessResult(
                output: "Account: private@example.com",
                terminationStatus: 1
            )
        )
        let probe = ClaudeCLIUsageProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            timeout: 0.25,
            processRunner: runner
        )

        do {
            _ = try await probe.fetchUsage()
            XCTFail("The runner timeout must be propagated.")
        } catch {
            let probeError = error as? ClaudeCLIUsageProbeError
            XCTAssertEqual(probeError, .timedOut)
            XCTAssertFalse(
                probeError?.localizedDescription.contains("private@example.com") == true
            )
        }
        let request = await runner.lastRequest
        XCTAssertEqual(request?.timeout, 0.25)
    }

    func testNonzeroExitDoesNotExposeCapturedAccountText() async {
        let runner = RecordingClaudeCLIUsageRunner(
            result: ClaudeCLIUsageProcessResult(
                output: "Account: private@example.com",
                terminationStatus: 9
            )
        )
        let probe = ClaudeCLIUsageProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        do {
            _ = try await probe.fetchUsage()
            XCTFail("A nonzero script exit must fail.")
        } catch {
            let probeError = error as? ClaudeCLIUsageProbeError
            XCTAssertEqual(probeError, .commandFailed(9))
            XCTAssertFalse(
                probeError?.localizedDescription.contains("private@example.com") == true
            )
        }
    }

    func testLiveRunnerStopsSyntheticLongLivedProcessAfterCompleteOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = directory.appendingPathComponent(
            "ClaudeProbe",
            isDirectory: true
        )
        let scriptURL = directory.appendingPathComponent("synthetic-probe.zsh")
        let pidURL = directory.appendingPathComponent("probe.pid")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
        print -r -- "$$" > "$1"
        print -r -- "Current session"
        print -r -- "5% used"
        print -r -- "Resets 7pm"
        read -r ignored
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let request = ClaudeCLIUsageProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, pidURL.path],
            timeout: 2,
            currentDirectoryURL: workingDirectory
        )

        let result = try await ClaudeCLIUsageLiveProcessRunner().run(request) { output in
            output.contains("Resets 7pm") ? .finish : nil
        }

        XCTAssertTrue(result.completedByOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingDirectory.path))
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    func testLiveRunnerStopsScriptChildThatIgnoresTerminationSignals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = directory.appendingPathComponent(
            "ClaudeProbe",
            isDirectory: true
        )
        let childScriptURL = directory.appendingPathComponent("stubborn-child.zsh")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let childScript = #"""
        trap '' HUP TERM INT
        print -r -- "$$" > "$1"
        print -r -- "Current session"
        print -r -- "5% used"
        print -r -- "Resets 7pm"
        while true; do
            /bin/sleep 1
        done
        """#
        try childScript.write(to: childScriptURL, atomically: true, encoding: .utf8)
        let request = ClaudeCLIUsageProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "-q",
                "/dev/null",
                "/bin/zsh",
                childScriptURL.path,
                childPIDURL.path,
            ],
            timeout: 2,
            currentDirectoryURL: workingDirectory
        )

        let result = try await ClaudeCLIUsageLiveProcessRunner().run(request) { output in
            output.contains("Resets 7pm") ? .finish : nil
        }

        XCTAssertTrue(result.completedByOutput)
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let didExit = await waitUntilProcessExits(childPID)
        XCTAssertTrue(didExit, "The PTY wrapper's stubborn child must not be orphaned.")
    }

    func testLiveRunnerTimeoutStopsScriptChildThatIgnoresTerminationSignals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = directory.appendingPathComponent(
            "ClaudeProbe",
            isDirectory: true
        )
        let childScriptURL = directory.appendingPathComponent("stubborn-timeout-child.zsh")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let childScript = #"""
        trap '' HUP TERM INT
        print -r -- "$$" > "$1"
        print -r -- "Loading usage data"
        while true; do
            /bin/sleep 1
        done
        """#
        try childScript.write(to: childScriptURL, atomically: true, encoding: .utf8)
        let request = ClaudeCLIUsageProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: [
                "-q",
                "/dev/null",
                "/bin/zsh",
                childScriptURL.path,
                childPIDURL.path,
            ],
            timeout: 0.05,
            currentDirectoryURL: workingDirectory
        )

        do {
            _ = try await ClaudeCLIUsageLiveProcessRunner().run(request) { _ in nil }
            XCTFail("The stubborn PTY child must be stopped at the timeout.")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIUsageProbeError, .timedOut)
        }

        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let didExit = await waitUntilProcessExits(childPID)
        XCTAssertTrue(didExit, "A timed-out PTY child must not be orphaned.")
    }

    func testLiveRunnerTimeoutStopsSyntheticProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = directory.appendingPathComponent(
            "ClaudeProbe",
            isDirectory: true
        )
        let scriptURL = directory.appendingPathComponent("synthetic-timeout.zsh")
        let pidURL = directory.appendingPathComponent("probe.pid")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
        print -r -- "$$" > "$1"
        print -r -- "Loading usage data"
        read -r ignored
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let request = ClaudeCLIUsageProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, pidURL.path],
            timeout: 0.05,
            currentDirectoryURL: workingDirectory
        )

        do {
            _ = try await ClaudeCLIUsageLiveProcessRunner().run(request) { _ in nil }
            XCTFail("The synthetic process must be stopped at the timeout.")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIUsageProbeError, .timedOut)
        }

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    private func waitUntilProcessExits(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor RecordingClaudeCLIUsageRunner: ClaudeCLIUsageProcessRunning {
    private(set) var lastRequest: ClaudeCLIUsageProcessRequest?
    private(set) var inputs: [ClaudeCLIUsageProcessInput] = []
    private let outputChunks: [String]
    private let error: ClaudeCLIUsageProbeError?
    private let result: ClaudeCLIUsageProcessResult

    init(
        outputChunks: [String] = [],
        error: ClaudeCLIUsageProbeError? = nil,
        result: ClaudeCLIUsageProcessResult
    ) {
        self.outputChunks = outputChunks
        self.error = error
        self.result = result
    }

    func run(
        _ request: ClaudeCLIUsageProcessRequest,
        onOutput: @escaping @Sendable (String) -> ClaudeCLIUsageProcessInput?
    ) async throws -> ClaudeCLIUsageProcessResult {
        lastRequest = request
        for output in outputChunks {
            if let input = onOutput(output) {
                inputs.append(input)
            }
        }
        if let error {
            throw error
        }
        return result
    }
}
