import Foundation
import XCTest
@testable import AiUsage

final class ExecutableLocatorTests: XCTestCase {
    func testCodexUsesDesktopBundleWithoutStandaloneCLI() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundled = try makeExecutable(at: directory
            .appendingPathComponent("ChatGPT.app/Contents/Resources/codex"))

        XCTAssertEqual(
            ExecutableLocator.locateCodex(
                applicationURLs: [directory.appendingPathComponent("ChatGPT.app")],
                cliCandidates: []
            ),
            bundled
        )
    }

    func testCodexFallsBackWhenDesktopResourceIsMissingOrNotExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = directory.appendingPathComponent("Codex.app")
        let resource = application.appendingPathComponent("Contents/Resources/codex")
        let cli = try makeExecutable(at: directory.appendingPathComponent("bin/codex"))

        XCTAssertEqual(
            ExecutableLocator.locateCodex(
                applicationURLs: [application],
                cliCandidates: [cli]
            ),
            cli
        )

        try FileManager.default.createDirectory(
            at: resource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: resource)

        XCTAssertEqual(
            ExecutableLocator.locateCodex(
                applicationURLs: [application],
                cliCandidates: [cli]
            ),
            cli
        )
    }

    func testCodexFallsBackToStandaloneCLIWithoutDesktopApp() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try makeExecutable(at: directory.appendingPathComponent("bin/codex"))

        XCTAssertEqual(
            ExecutableLocator.locateCodex(applicationURLs: [], cliCandidates: [cli]),
            cli
        )
    }

    func testCodexReturnsNilWithoutDesktopAppOrCLI() {
        XCTAssertNil(ExecutableLocator.locateCodex(applicationURLs: [], cliCandidates: []))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeExecutable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }
}
