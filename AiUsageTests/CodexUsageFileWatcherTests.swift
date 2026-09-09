import Foundation
import XCTest
@testable import AiUsage

final class CodexUsageFileWatcherTests: XCTestCase {
    func testNewDatedFileAfterStartEmitsSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        let datedDirectory = root.appendingPathComponent("2026/09/09", isDirectory: true)
        try FileManager.default.createDirectory(
            at: datedDirectory,
            withIntermediateDirectories: true
        )
        let file = datedDirectory.appendingPathComponent("rollout.jsonl")
        try append(record(), to: file)

        let snapshot = (await recorder.waitForCount(1)).last
        XCTAssertEqual(snapshot?.provider, .codex)
        XCTAssertEqual(snapshot?.weekly?.remainingPercentage, 80)
        XCTAssertNil(snapshot?.fiveHour)
    }

    func testSplitRecordAndIrrelevantRecordsAreIgnored() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        let valid = record(duration: 300, used: 42)
        let splitPoint = valid.count / 2
        try append(Data(valid[..<splitPoint]), to: file)
        let beforeCompletion = await recorder.waitForCount(
            1,
            timeout: .milliseconds(200)
        )
        XCTAssertTrue(beforeCompletion.isEmpty)

        try append(Data(valid[splitPoint...]), to: file)
        let snapshot = (await recorder.waitForCount(1)).last
        XCTAssertEqual(snapshot?.fiveHour?.remainingPercentage, 58)

        try append(Data("malformed\n".utf8), to: file)
        try append(record(limitID: "other", used: 1), to: file)
        try append(record(timestamp: Date().addingTimeInterval(-60), used: 2), to: file)
        try append(record(timestamp: Date().addingTimeInterval(60), used: 3), to: file)
        let ignored = await recorder.waitForCount(
            1,
            timeout: .milliseconds(250)
        )
        XCTAssertEqual(ignored.count, 1)
    }

    func testReplacementAndTruncationContinueWithFreshRecords() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        try append(record(used: 20), to: file)
        let first = (await recorder.waitForCount(1)).last
        XCTAssertEqual(first?.weekly?.remainingPercentage, 80)

        let replacement = root.appendingPathComponent("rollout.tmp")
        try append(record(used: 30), to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        let replaced = (await recorder.waitForCount(2)).last
        XCTAssertEqual(replaced?.weekly?.remainingPercentage, 70)

        try Data().write(to: file)
        try await Task.sleep(for: .milliseconds(150))
        try append(record(used: 40), to: file)
        let truncated = (await recorder.waitForCount(3)).last
        XCTAssertEqual(truncated?.weekly?.remainingPercentage, 60)
    }

    func testOversizedLineDoesNotPreventLaterSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        try append(Data(repeating: 0x78, count: 100_000) + Data("\n".utf8), to: file)
        try append(record(used: 55), to: file)
        let snapshot = (await recorder.waitForCount(1)).last
        XCTAssertEqual(snapshot?.weekly?.remainingPercentage, 45)
    }

    func testLargeBacklogJumpsToLatestTailInOneEvent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        try append(record(used: 10), to: file)
        let baseline = (await recorder.waitForCount(1)).last
        XCTAssertEqual(baseline?.weekly?.remainingPercentage, 90)

        let irrelevant = Data(repeating: 0x78, count: 300_000) + Data("\n".utf8)
        try append(irrelevant + record(used: 66), to: file)
        let latest = (await recorder.waitForCount(2)).last
        XCTAssertEqual(latest?.weekly?.remainingPercentage, 34)
    }

    func testBooleanUsedAndFractionalWindowFieldsAreIgnored() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        defer {
            watcher.stop()
            recorder.cancel()
        }

        try append(record(used: true), to: file)
        try append(record(duration: 300.5), to: file)
        let invalid = await recorder.waitForCount(
            1,
            timeout: .milliseconds(250)
        )
        XCTAssertTrue(invalid.isEmpty)

        try append(record(duration: 300, used: 25.5), to: file)
        let valid = (await recorder.waitForCount(1)).last
        XCTAssertEqual(valid?.fiveHour?.remainingPercentage, 75)
    }

    func testStopFinishesStreamAndPreventsLaterPublishes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let watcher = CodexUsageFileWatcher(sessionsURL: root)
        let stream = AsyncStream<UsageSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        watcher.start(stream.continuation)
        let recorder = SnapshotRecorder(stream: stream.stream)
        watcher.stop()

        try append(record(), to: file)
        let snapshot = await recorder.waitForCount(
            1,
            timeout: .milliseconds(250)
        )
        XCTAssertTrue(snapshot.isEmpty)
        recorder.cancel()
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

    private func append(_ data: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func record(
        timestamp: Date = .now,
        limitID: String = "codex",
        duration: Any = 10_080,
        used: Any = 20
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "type": "event_msg",
            "timestamp": formatter.string(from: timestamp),
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": limitID,
                    "primary": [
                        "used_percent": used,
                        "window_minutes": duration,
                        "resets_at": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
                    ]
                ]
            ]
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return encoded + Data("\n".utf8)
    }

    private final class SnapshotRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [UsageSnapshot] = []
        private var task: Task<Void, Never>?

        init(stream: AsyncStream<UsageSnapshot>) {
            task = Task { [weak self] in
                for await snapshot in stream {
                    self?.append(snapshot)
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }

        func waitForCount(
            _ count: Int,
            timeout: Duration = .seconds(2)
        ) async -> [UsageSnapshot] {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                let current = values()
                if current.count >= count { return current }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return values()
        }

        private func append(_ snapshot: UsageSnapshot) {
            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
        }

        private func values() -> [UsageSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
        }
    }
}
