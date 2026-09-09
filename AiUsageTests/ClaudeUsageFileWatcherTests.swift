import Foundation
import XCTest
@testable import AiUsage

final class ClaudeUsageFileWatcherTests: XCTestCase {
    func testChangeTriggersWithoutWaitingForPolling() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-cache.json")
        try Data("one".utf8).write(to: file)

        let watcher = ClaudeUsageFileWatcher(paths: [file])
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        defer { watcher.stop() }

        try Data("two!".utf8).write(to: file)
        let received = await nextEvent(from: stream.stream)
        XCTAssertTrue(received)
    }

    func testAtomicReplacementAndInitiallyAbsentFileTrigger() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-cache.json")
        let replacement = directory.appendingPathComponent("usage-cache.json.tmp")
        let watcher = ClaudeUsageFileWatcher(paths: [file])
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        defer { watcher.stop() }

        try Data("one".utf8).write(to: replacement)
        try FileManager.default.moveItem(at: replacement, to: file)
        let created = await nextEvent(from: stream.stream)
        XCTAssertTrue(created)

        try Data("two".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        let replaced = await nextEvent(from: stream.stream)
        XCTAssertTrue(replaced)
    }

    func testAbsentParentIsRearmedWhenCreated() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("missing/claude", isDirectory: true)
        let file = parent.appendingPathComponent("usage-cache.json")
        let watcher = ClaudeUsageFileWatcher(paths: [file])
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        defer { watcher.stop() }

        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try Data("created".utf8).write(to: file)
        let received = await nextEvent(from: stream.stream)
        XCTAssertTrue(received)
    }

    func testUnrelatedDirectoryWritesAreFilteredAndStopClosesWatches() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-cache.json")
        try Data("one".utf8).write(to: file)
        let unrelated = directory.appendingPathComponent("unrelated")
        let watcher = ClaudeUsageFileWatcher(paths: [file])
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        XCTAssertEqual(watcher.activeWatchCount, 1)

        try Data("other".utf8).write(to: unrelated)
        let received = await nextEvent(
            from: stream.stream,
            timeout: .milliseconds(250)
        )
        XCTAssertFalse(received)

        watcher.stop()
        XCTAssertEqual(watcher.activeWatchCount, 0)
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

    private func nextEvent(
        from stream: AsyncStream<Void>,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
