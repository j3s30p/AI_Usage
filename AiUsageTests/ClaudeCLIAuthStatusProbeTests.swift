import Darwin
import Foundation
import XCTest
@testable import AiUsage

final class ClaudeCLIAuthStatusProbeTests: XCTestCase {
    func testProbeRunsNoninteractiveAuthStatusCommandWithFiveSecondDefault() async throws {
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(#"{"loggedIn":true}"#.utf8),
                terminationStatus: 0
            )
        )
        let executableURL = URL(fileURLWithPath: "/test/bin/claude")
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: executableURL,
            processRunner: runner
        )

        let loggedIn = try await probe.isLoggedIn()
        let request = await runner.lastRequest

        XCTAssertTrue(loggedIn)
        XCTAssertEqual(request?.executableURL, executableURL)
        XCTAssertEqual(request?.arguments, ["auth", "status", "--json"])
        XCTAssertEqual(request?.timeout, 5)
    }

    func testProbeReturnsFalseAndIgnoresSensitiveFields() async throws {
        let fixture = #"{"loggedIn":false,"email":"private@example.com","orgId":"secret"}"#
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(fixture.utf8),
                terminationStatus: 1
            )
        )
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        let loggedIn = try await probe.isLoggedIn()

        XCTAssertFalse(loggedIn)
    }

    func testProbeRejectsLoggedInOutputWhenCommandFailed() async {
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(#"{"loggedIn":true}"#.utf8),
                terminationStatus: 7
            )
        )
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        do {
            _ = try await probe.isLoggedIn()
            XCTFail("A failed auth command must not authorize /usage launch.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeCLIAuthStatusProbeError,
                .commandFailed(7)
            )
        }
    }

    func testMissingExecutableDoesNotStartProcess() async {
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(),
                terminationStatus: 0
            )
        )
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: nil,
            processRunner: runner
        )

        do {
            _ = try await probe.isLoggedIn()
            XCTFail("A missing executable must fail before process launch.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeCLIAuthStatusProbeError,
                .executableNotFound
            )
        }
        let request = await runner.lastRequest
        XCTAssertNil(request)
    }

    func testInvalidSuccessfulOutputIsRejectedWithoutExposingIt() async {
        let secret = "private@example.com"
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(#"{"email":"private@example.com"}"#.utf8),
                terminationStatus: 0
            )
        )
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        do {
            _ = try await probe.isLoggedIn()
            XCTFail("Output without loggedIn must fail.")
        } catch {
            let probeError = error as? ClaudeCLIAuthStatusProbeError
            XCTAssertEqual(probeError, .invalidOutput)
            XCTAssertFalse(probeError?.localizedDescription.contains(secret) == true)
        }
    }

    func testInvalidFailedOutputReportsOnlyExitStatus() async {
        let secret = "private@example.com"
        let runner = RecordingClaudeCLIAuthStatusRunner(
            result: ClaudeCLIAuthStatusProcessResult(
                standardOutput: Data(secret.utf8),
                terminationStatus: 7
            )
        )
        let probe = ClaudeCLIAuthStatusProbe(
            executableURL: URL(fileURLWithPath: "/test/bin/claude"),
            processRunner: runner
        )

        do {
            _ = try await probe.isLoggedIn()
            XCTFail("A failed command with invalid JSON must fail.")
        } catch {
            let probeError = error as? ClaudeCLIAuthStatusProbeError
            XCTAssertEqual(probeError, .commandFailed(7))
            XCTAssertFalse(probeError?.localizedDescription.contains(secret) == true)
        }
    }

    func testLiveRunnerUsesDevNullForStandardInput() async throws {
        let fixture = try SyntheticAuthStatusCommand(
            body: #"""
            if read -r ignored; then
                print -r -- '{"loggedIn":false}'
                exit 9
            fi
            print -r -- '{"loggedIn":true}'
            """#
        )
        defer { fixture.remove() }
        let request = ClaudeCLIAuthStatusProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.scriptURL.path],
            timeout: 1
        )

        let result = try await ClaudeCLIAuthStatusLiveProcessRunner().run(request)
        let decoded = try JSONDecoder().decode(
            LoggedInFixture.self,
            from: result.standardOutput
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(decoded.loggedIn)
    }

    func testLiveRunnerLimitsStandardOutput() async throws {
        let fixture = try SyntheticAuthStatusCommand(
            body: #"""
            print -n -- '0123456789012345678901234567890123456789'
            """#
        )
        defer { fixture.remove() }
        let runner = ClaudeCLIAuthStatusLiveProcessRunner(
            maximumStandardOutputBytes: 16,
            maximumStandardErrorBytes: 64
        )

        await assertOutputTooLarge(runner: runner, scriptURL: fixture.scriptURL)
    }

    func testLiveRunnerLimitsStandardErrorWithoutRetainingIt() async throws {
        let fixture = try SyntheticAuthStatusCommand(
            body: #"""
            print -nu2 -- 'private@example.com-private@example.com'
            print -r -- '{"loggedIn":true}'
            """#
        )
        defer { fixture.remove() }
        let runner = ClaudeCLIAuthStatusLiveProcessRunner(
            maximumStandardOutputBytes: 64,
            maximumStandardErrorBytes: 16
        )

        await assertOutputTooLarge(runner: runner, scriptURL: fixture.scriptURL)
    }

    func testLiveRunnerTimesOutAndKillsProcessThatIgnoresTermination() async throws {
        let fixture = try SyntheticAuthStatusCommand(
            body: #"""
            trap '' TERM
            print -r -- "$$" > "$1"
            while true; do :; done
            """#
        )
        defer { fixture.remove() }
        let pidURL = fixture.directoryURL.appendingPathComponent("timeout.pid")
        let request = ClaudeCLIAuthStatusProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.scriptURL.path, pidURL.path],
            timeout: 0.05
        )

        do {
            _ = try await ClaudeCLIAuthStatusLiveProcessRunner().run(request)
            XCTFail("A long-running auth check must time out.")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIAuthStatusProbeError, .timedOut)
        }

        let pid = try processIdentifier(from: pidURL)
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    func testLiveRunnerTimeoutKillsStubbornChildThatInheritsPipes() async throws {
        let fixture = try SyntheticAuthStatusProcessTree()
        defer { fixture.remove() }

        do {
            _ = try await ClaudeCLIAuthStatusLiveProcessRunner().run(
                fixture.request(timeout: 0.05)
            )
            XCTFail("A long-running auth process tree must time out.")
        } catch {
            XCTAssertEqual(error as? ClaudeCLIAuthStatusProbeError, .timedOut)
        }

        let rootPID = try processIdentifier(from: fixture.rootPIDURL)
        let childPID = try processIdentifier(from: fixture.childPIDURL)
        let didRootExit = await waitUntilProcessExits(rootPID)
        let didChildExit = await waitUntilProcessExits(childPID)
        XCTAssertTrue(didRootExit)
        XCTAssertTrue(
            didChildExit,
            "A timed-out auth-status child that inherits the pipes must not be orphaned."
        )
    }

    func testLiveRunnerCancellationKillsProcess() async throws {
        let fixture = try SyntheticAuthStatusCommand(
            body: #"""
            trap '' TERM
            print -r -- "$$" > "$1"
            while true; do :; done
            """#
        )
        defer { fixture.remove() }
        let pidURL = fixture.directoryURL.appendingPathComponent("cancel.pid")
        let request = ClaudeCLIAuthStatusProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [fixture.scriptURL.path, pidURL.path],
            timeout: 30
        )
        let task = Task {
            try await ClaudeCLIAuthStatusLiveProcessRunner().run(request)
        }
        let didStart = await waitUntilFileExists(pidURL)
        XCTAssertTrue(didStart)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled auth check must not succeed.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let pid = try processIdentifier(from: pidURL)
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    func testLiveRunnerCancellationKillsStubbornChildThatInheritsPipes() async throws {
        let fixture = try SyntheticAuthStatusProcessTree()
        defer { fixture.remove() }
        let task = Task {
            try await ClaudeCLIAuthStatusLiveProcessRunner().run(
                fixture.request(timeout: 30)
            )
        }
        let didStartRoot = await waitUntilFileExists(fixture.rootPIDURL)
        let didStartChild = await waitUntilFileExists(fixture.childPIDURL)
        XCTAssertTrue(didStartRoot)
        XCTAssertTrue(didStartChild)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled auth process tree must not succeed.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let rootPID = try processIdentifier(from: fixture.rootPIDURL)
        let childPID = try processIdentifier(from: fixture.childPIDURL)
        let didRootExit = await waitUntilProcessExits(rootPID)
        let didChildExit = await waitUntilProcessExits(childPID)
        XCTAssertTrue(didRootExit)
        XCTAssertTrue(
            didChildExit,
            "A cancelled auth-status child that inherits the pipes must not be orphaned."
        )
    }

    private func assertOutputTooLarge(
        runner: ClaudeCLIAuthStatusLiveProcessRunner,
        scriptURL: URL
    ) async {
        let request = ClaudeCLIAuthStatusProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path],
            timeout: 1
        )
        do {
            _ = try await runner.run(request)
            XCTFail("Oversized process output must fail.")
        } catch {
            let probeError = error as? ClaudeCLIAuthStatusProbeError
            XCTAssertEqual(probeError, .outputTooLarge)
            XCTAssertFalse(
                probeError?.localizedDescription.contains("private@example.com") == true
            )
        }
    }

    private func processIdentifier(from url: URL) throws -> Int32 {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(text))
    }

    private func waitUntilFileExists(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

private struct LoggedInFixture: Decodable {
    let loggedIn: Bool
}

private actor RecordingClaudeCLIAuthStatusRunner: ClaudeCLIAuthStatusProcessRunning {
    private(set) var lastRequest: ClaudeCLIAuthStatusProcessRequest?
    private let result: ClaudeCLIAuthStatusProcessResult

    init(result: ClaudeCLIAuthStatusProcessResult) {
        self.result = result
    }

    func run(
        _ request: ClaudeCLIAuthStatusProcessRequest
    ) async throws -> ClaudeCLIAuthStatusProcessResult {
        lastRequest = request
        return result
    }
}

private struct SyntheticAuthStatusCommand {
    let directoryURL: URL
    let scriptURL: URL

    init(body: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        scriptURL = directoryURL.appendingPathComponent("auth-status.zsh")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct SyntheticAuthStatusProcessTree {
    let directoryURL: URL
    let rootScriptURL: URL
    let childScriptURL: URL
    let rootPIDURL: URL
    let childPIDURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        rootScriptURL = directoryURL.appendingPathComponent("auth-status-root.zsh")
        childScriptURL = directoryURL.appendingPathComponent("auth-status-child.zsh")
        rootPIDURL = directoryURL.appendingPathComponent("root.pid")
        childPIDURL = directoryURL.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let rootScript = #"""
        trap '' HUP TERM INT
        /bin/zsh "$1" "$2" &
        print -r -- "$$" > "$3"
        wait
        """#
        let childScript = #"""
        trap '' HUP TERM INT
        print -r -- "$$" > "$1"
        while true; do
            /bin/sleep 1
        done
        """#
        try rootScript.write(to: rootScriptURL, atomically: true, encoding: .utf8)
        try childScript.write(to: childScriptURL, atomically: true, encoding: .utf8)
    }

    func request(timeout: TimeInterval) -> ClaudeCLIAuthStatusProcessRequest {
        ClaudeCLIAuthStatusProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                rootScriptURL.path,
                childScriptURL.path,
                childPIDURL.path,
                rootPIDURL.path,
            ],
            timeout: timeout
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
