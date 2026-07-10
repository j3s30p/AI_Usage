import Darwin
import Foundation
import XCTest
@testable import AiUsage

final class CodexAppServerClientTests: XCTestCase {
    func testClosedChildPipeThrowsInsteadOfTerminatingTheApp() async throws {
        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        defer { client.shutdown() }
        try await Task.sleep(for: .milliseconds(100))

        do {
            try await client.initialize()
            XCTFail("A closed child pipe must not accept a request.")
        } catch {
            XCTAssertTrue(error is UsageServiceError)
        }
    }

    func testConcurrentRequestsAreDemultiplexedAroundNotificationOnOneProcess() async throws {
        let scriptURL = try makeFakeAppServer()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path]
        )
        defer { client.shutdown() }

        let pid = client.processIdentifier
        XCTAssertGreaterThan(pid, 0)
        XCTAssertTrue(client.isRunning)

        try await client.initialize()

        let notificationTask = Task {
            var iterator = client.notifications.makeAsyncIterator()
            return await iterator.next()
        }
        defer { notificationTask.cancel() }

        async let firstResponse = client.fetchRateLimits()
        async let secondResponse = client.fetchRateLimits()
        let (first, second) = try await (firstResponse, secondResponse)

        XCTAssertEqual(client.processIdentifier, pid)
        XCTAssertTrue(client.isRunning)
        XCTAssertEqual(
            Set([first.rateLimits.primary?.usedPercent, second.rateLimits.primary?.usedPercent].compactMap { $0 }),
            Set([11, 22])
        )

        let notification = await notificationTask.value
        XCTAssertEqual(notification?.method, "account/rateLimits/updated")
        let rawObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(notification?.rawData))
                as? [String: Any]
        )
        XCTAssertEqual(rawObject["method"] as? String, "account/rateLimits/updated")

        client.shutdown()
        client.shutdown()
        XCTAssertFalse(client.isRunning)
        try await waitUntilProcessExits(pid)
    }

    func testTimedOutRequestClosesConnectionAndDoesNotLeavePendingContinuation() async throws {
        let scriptURL = try makeFakeAppServer()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, "ignore-rate-limits"],
            requestTimeout: 0.5
        )
        defer { client.shutdown() }

        try await client.initialize()
        do {
            _ = try await client.fetchRateLimits()
            XCTFail("An unanswered request must time out.")
        } catch UsageServiceError.requestTimedOut(let provider) {
            XCTAssertEqual(provider, "Codex")
        } catch {
            XCTFail("Expected a timeout, received \(error).")
        }
        XCTAssertFalse(client.isRunning)
    }

    func testServerErrorMessageIsNotExposed() async throws {
        let scriptURL = try makeFakeAppServer()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, "error-rate-limits"]
        )
        defer { client.shutdown() }

        try await client.initialize()
        do {
            _ = try await client.fetchRateLimits()
            XCTFail("A JSON-RPC error must fail the request.")
        } catch UsageServiceError.requestFailed(let message) {
            XCTAssertEqual(message, "Codex 사용량 요청이 실패했습니다.")
            XCTAssertFalse(message.contains("private@example.com"))
            XCTAssertFalse(message.contains("sensitive-token"))
        } catch {
            XCTFail("Expected a sanitized request failure, received \(error).")
        }
    }

    func testOversizedServerLineClosesConnection() async throws {
        let scriptURL = try makeFakeAppServer()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, "oversized-rate-limits"],
            requestTimeout: 2
        )
        defer { client.shutdown() }

        try await client.initialize()
        do {
            _ = try await client.fetchRateLimits()
            XCTFail("An oversized JSONL record must close the connection.")
        } catch {
            XCTAssertTrue(error is UsageServiceError)
        }
        XCTAssertFalse(client.isRunning)
    }

    func testShutdownForceKillsServerThatIgnoresTermination() async throws {
        let scriptURL = try makeFakeAppServer()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let client = try CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [scriptURL.path, "ignore-termination"]
        )
        let pid = client.processIdentifier
        try await client.initialize()

        client.shutdown()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(kill(pid, 0), 0, "The fake server should ignore SIGTERM.")
        try await waitUntilProcessExits(pid)
    }

    private func makeFakeAppServer() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let scriptURL = directory.appendingPathComponent("fake-app-server.zsh")
        let script = #"""
        #!/bin/zsh
        mode="${1:-respond}"
        first_rate_limit_id=""

        if [[ "$mode" == "ignore-termination" ]]; then
          trap '' TERM
        fi

        extract_id() {
          print -r -- "$1" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/'
        }

        rate_limit_response() {
          local id="$1"
          local used_percent="$2"
          print -r -- "{\"id\":${id},\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":${used_percent},\"windowDurationMins\":300,\"resetsAt\":2000000000},\"secondary\":{\"usedPercent\":40,\"windowDurationMins\":10080,\"resetsAt\":2000600000}}}}"
        }

        while IFS= read -r line; do
          if [[ "$line" == *'"method":"initialize"'* && "$line" == *'"id":'* ]]; then
            id=$(extract_id "$line")
            print -r -- "{\"id\":${id},\"result\":{}}"
            if [[ "$mode" == "ignore-termination" ]]; then
              while true; do :; done
            fi
          elif [[ "$line" == *'"method":"account/rateLimits/read"'* ]]; then
            if [[ "$mode" == "ignore-rate-limits" ]]; then
              continue
            fi
            id=$(extract_id "$line")
            if [[ "$mode" == "error-rate-limits" ]]; then
              print -r -- "{\"id\":${id},\"error\":{\"message\":\"private@example.com sensitive-token\"}}"
              continue
            fi
            if [[ "$mode" == "oversized-rate-limits" ]]; then
              /usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\\0' x
              print
              continue
            fi
            if [[ -z "$first_rate_limit_id" ]]; then
              first_rate_limit_id="$id"
            else
              print -r -- '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":33,"windowDurationMins":300,"resetsAt":2000000000}}}}'
              rate_limit_response "$id" 22
              rate_limit_response "$first_rate_limit_id" 11
              first_rate_limit_id=""
            fi
          fi
        done
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func waitUntilProcessExits(
        _ pid: Int32,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while kill(pid, 0) == 0 {
            guard clock.now < deadline else {
                XCTFail("The fake app-server process did not exit after shutdown.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(errno, ESRCH)
    }
}
