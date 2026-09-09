import CoreServices
import Darwin
import Foundation

/// Reads newly appended Codex usage snapshots from local rollout files.
///
/// `CodexUsageProvider` remains the authority when this stream is unavailable or
/// stale. This watcher is deliberately small: one recursive FSEvents stream,
/// bounded tail reads, and no retained file handles or transcript content.
final class CodexUsageFileWatcher: @unchecked Sendable {
    private struct FileState {
        var inode: UInt64
        var offset: UInt64
        var pending = Data()
        var skippingOversizedLine = false
    }

    private static let maxTrackedFiles = 128
    private static let maxReadPerEvent = 256 * 1024
    private static let maxPendingBytes = 64 * 1024

    static var defaultSessionsURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private let sessionsURL: URL
    private let sessionsPath: String
    private let queue = DispatchQueue(label: "com.openai.AiUsage.codex-usage-file-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var monitoringStartedAt = Date.distantFuture
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<UsageSnapshot>.Continuation?
    private var states: [String: FileState] = [:]
    private var stateOrder: [String] = []
    private var stopped = false

    init(sessionsURL: URL = CodexUsageFileWatcher.defaultSessionsURL) {
        let standardized = sessionsURL.standardizedFileURL.resolvingSymlinksInPath()
        self.sessionsURL = standardized
        self.sessionsPath = standardized.path
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    func start(_ continuation: AsyncStream<UsageSnapshot>.Continuation) {
        syncOnQueue {
            guard !stopped, stream == nil else {
                continuation.finish()
                return
            }

            monitoringStartedAt = .now
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }

            let watchPath = Self.nearestExistingAncestor(of: sessionsURL).path
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                nil,
                Self.eventCallback,
                &context,
                [watchPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                flags
            ) else {
                self.continuation = nil
                continuation.finish()
                return
            }

            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stream = nil
                self.continuation = nil
                continuation.finish()
                return
            }
        }
    }

    func stop() {
        let pendingContinuation = syncOnQueue { () -> AsyncStream<UsageSnapshot>.Continuation? in
            guard !stopped else { return nil }
            stopped = true

            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }

            let continuation = self.continuation
            self.continuation = nil
            states.removeAll(keepingCapacity: false)
            stateOrder.removeAll(keepingCapacity: false)
            return continuation
        }

        pendingContinuation?.finish()
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, info, count, paths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<CodexUsageFileWatcher>
            .fromOpaque(info)
            .takeUnretainedValue()
        watcher.handleEvents(count: count, paths: paths)
    }

    private func handleEvents(count: Int, paths: UnsafeMutableRawPointer) {
        guard !stopped else { return }

        let eventPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        for index in 0..<count {
            let path = URL(fileURLWithPath: String(cString: eventPaths[index]))
                .resolvingSymlinksInPath()
                .path
            guard isSessionJSONL(path) else { continue }
            process(path: path)
        }
    }

    private func process(path: String) {
        guard let attributes = fileAttributes(path), attributes.isRegularFile else {
            return
        }

        var state = states[path]
        var discardLeadingFragment = false
        if state?.inode != attributes.inode || state?.offset ?? 0 > attributes.size {
            state = FileState(
                inode: attributes.inode,
                offset: attributes.size > UInt64(Self.maxReadPerEvent)
                    ? attributes.size - UInt64(Self.maxReadPerEvent)
                    : 0
            )
            discardLeadingFragment = state?.offset ?? 0 > 0
        } else if state == nil {
            state = FileState(
                inode: attributes.inode,
                offset: attributes.size > UInt64(Self.maxReadPerEvent)
                    ? attributes.size - UInt64(Self.maxReadPerEvent)
                    : 0
            )
            discardLeadingFragment = state?.offset ?? 0 > 0
        } else if let existing = state,
                  attributes.size - existing.offset > UInt64(Self.maxReadPerEvent)
        {
            // ponytail: jump to the latest bounded tail instead of waiting for another write.
            state = FileState(
                inode: attributes.inode,
                offset: attributes.size - UInt64(Self.maxReadPerEvent)
            )
            discardLeadingFragment = true
        }

        guard var state else { return }
        let remaining = attributes.size >= state.offset
            ? attributes.size - state.offset
            : 0
        guard remaining > 0 else {
            remember(state: state, for: path)
            return
        }

        let amount = min(remaining, UInt64(Self.maxReadPerEvent))
        guard let chunk = read(path: path, offset: state.offset, count: Int(amount)) else {
            remember(state: state, for: path)
            return
        }
        state.offset += UInt64(chunk.count)
        var data = chunk
        if discardLeadingFragment {
            guard let newline = data.firstIndex(of: 0x0A) else {
                state.skippingOversizedLine = true
                remember(state: state, for: path)
                return
            }
            data.removeSubrange(...newline)
        }
        consume(&data, state: &state)
        remember(state: state, for: path)
    }

    private func consume(_ data: inout Data, state: inout FileState) {
        while !data.isEmpty {
            if state.skippingOversizedLine {
                guard let newline = data.firstIndex(of: 0x0A) else {
                    data.removeAll(keepingCapacity: false)
                    return
                }
                data.removeSubrange(...newline)
                state.skippingOversizedLine = false
                continue
            }

            guard let newline = data.firstIndex(of: 0x0A) else {
                if state.pending.count + data.count > Self.maxPendingBytes {
                    state.pending.removeAll(keepingCapacity: false)
                    state.skippingOversizedLine = true
                    data.removeAll(keepingCapacity: false)
                } else {
                    state.pending.append(data)
                    data.removeAll(keepingCapacity: true)
                }
                return
            }

            let line = data.prefix(upTo: newline)
            data.removeSubrange(...newline)
            guard state.pending.count + line.count <= Self.maxPendingBytes else {
                state.pending.removeAll(keepingCapacity: false)
                continue
            }

            state.pending.append(line)
            let completeLine = state.pending
            state.pending.removeAll(keepingCapacity: true)
            guard !completeLine.isEmpty,
                  let snapshot = Self.parse(
                    line: completeLine,
                    monitoringStartedAt: monitoringStartedAt
                  )
            else { continue }
            continuation?.yield(snapshot)
        }
    }

    private func remember(state: FileState, for path: String) {
        if states[path] == nil {
            stateOrder.append(path)
        }
        states[path] = state
        while stateOrder.count > Self.maxTrackedFiles {
            let evicted = stateOrder.removeFirst()
            states.removeValue(forKey: evicted)
        }
    }

    private func isSessionJSONL(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        return path == sessionsPath || path.hasPrefix(sessionsPath + "/")
    }

    private struct FileAttributes {
        let inode: UInt64
        let size: UInt64
        let isRegularFile: Bool
    }

    private func fileAttributes(_ path: String) -> FileAttributes? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileAttributes(
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG
        )
    }

    private func read(path: String, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func parse(line: Data, monitoringStartedAt: Date) -> UsageSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            root["type"] as? String == "event_msg",
            let timestampText = root["timestamp"] as? String,
            let timestamp = parseTimestamp(timestampText),
            timestamp >= monitoringStartedAt,
            timestamp <= .now,
            let payload = root["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let limits = payload["rate_limits"] as? [String: Any],
            limits["limit_id"] as? String == "codex"
        else {
            return nil
        }

        let windows = ["primary", "secondary"].compactMap { key -> CodexRateLimitsResponse.Window? in
            guard let values = limits[key] as? [String: Any] else { return nil }
            guard
                let used = values["used_percent"] as? NSNumber,
                !(values["used_percent"] is Bool),
                used.doubleValue.isFinite,
                (0...100).contains(used.doubleValue),
                let duration = values["window_minutes"] as? NSNumber,
                !(values["window_minutes"] is Bool),
                duration.doubleValue.isFinite,
                duration.doubleValue.rounded() == duration.doubleValue,
                duration.intValue == 300 || duration.intValue == 10_080,
                let reset = values["resets_at"] as? NSNumber,
                !(values["resets_at"] is Bool),
                reset.int64Value > Int64(timestamp.timeIntervalSince1970),
                reset.int64Value > Int64(Date().timeIntervalSince1970)
            else { return nil }
            return CodexRateLimitsResponse.Window(
                usedPercent: used.doubleValue,
                windowDurationMins: duration.intValue,
                resetsAt: reset.int64Value
            )
        }

        guard !windows.isEmpty else { return nil }
        let primary = windows.first(where: { $0.windowDurationMins == 300 })
        let secondary = windows.first(where: { $0.windowDurationMins == 10_080 })
        let response = CodexRateLimitsResponse(
            rateLimits: .init(limitId: "codex", primary: primary, secondary: secondary),
            rateLimitsByLimitId: nil
        )
        return try? CodexUsageProvider.makeSnapshot(from: response, fetchedAt: timestamp)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
