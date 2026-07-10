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
}
