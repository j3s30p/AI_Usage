import Darwin
import Foundation

/// Watches the directories containing Claude's local usage files.
///
/// Directory vnode events are filtered by the target file's signature, so
/// unrelated writes do not produce refreshes. Watching the nearest existing
/// ancestor also covers an absent parent and later directory creation.
final class ClaudeUsageFileWatcher: @unchecked Sendable {
    private struct FileSignature: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct Target {
        let fileURL: URL
        var watchedURL: URL?
        var source: DispatchSourceFileSystemObject?
        var signature: FileSignature?
    }

    private let paths: [URL]
    private let queue = DispatchQueue(
        label: "com.j3s30p.AiUsage.claude-usage-file-watcher"
    )
    private var targets: [Target]
    private var continuation: AsyncStream<Void>.Continuation?
    private var pendingEvent = false
    private var stopped = false

    init(paths: [URL]) {
        self.paths = paths
        self.targets = paths.map { Target(fileURL: $0) }
    }

    func start(_ continuation: AsyncStream<Void>.Continuation) {
        queue.sync {
            guard !stopped else {
                continuation.finish()
                return
            }
            self.continuation = continuation
            rearmAll()
        }
    }

    func stop() {
        let continuation = queue.sync { () -> AsyncStream<Void>.Continuation? in
            guard !stopped else { return nil }
            stopped = true
            pendingEvent = false
            for index in targets.indices {
                cancelSource(at: index)
            }
            let pendingContinuation = self.continuation
            self.continuation = nil
            return pendingContinuation
        }
        continuation?.finish()
    }

    var activeWatchCount: Int {
        queue.sync { targets.reduce(into: 0) { count, target in
            count += target.source == nil ? 0 : 1
        } }
    }

    private func rearmAll() {
        for index in targets.indices {
            rearm(at: index)
        }
    }

    private func rearm(
        at index: Int,
        force: Bool = false,
        reconcile: Bool = true,
        notify: Bool = false
    ) {
        let target = targets[index]
        let previousSignature = targets[index].signature
        if force {
            cancelSource(at: index)
            targets[index].watchedURL = nil
        }
        let fileSignature = signature(of: target.fileURL)
        let watchURL = fileSignature == nil
            ? nearestExistingDirectory(for: target.fileURL)
            : target.fileURL
        if watchURL != target.watchedURL {
            cancelSource(at: index)
            targets[index].watchedURL = watchURL
        }

        targets[index].signature = fileSignature
        guard let watchURL, targets[index].source == nil else { return }

        let descriptor = open(watchURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setRegistrationHandler { [weak self] in
            self?.reconcileRegistration(at: index)
        }
        source.setEventHandler { [weak self] in
            self?.watchTargetChanged(at: index)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        targets[index].source = source
        source.resume()

        if notify, previousSignature != fileSignature {
            scheduleEvent()
        }

        guard reconcile else { return }
        let currentSignature = signature(of: target.fileURL)
        guard currentSignature != fileSignature else { return }
        rearm(at: index, force: true, reconcile: false, notify: true)
        scheduleEvent()
    }

    private func watchTargetChanged(at index: Int) {
        guard !stopped else { return }
        let target = targets[index]
        let oldSignature = target.signature
        rearm(at: index, force: true, notify: true)
        let newSignature = targets[index].signature
        if oldSignature != newSignature {
            scheduleEvent()
        }
    }

    private func reconcileRegistration(at index: Int) {
        guard !stopped else { return }
        let target = targets[index]
        let currentSignature = signature(of: target.fileURL)
        let currentWatchURL = currentSignature == nil
            ? nearestExistingDirectory(for: target.fileURL)
            : target.fileURL
        guard currentSignature != target.signature
            || currentWatchURL != target.watchedURL
        else { return }
        rearm(at: index, force: true, notify: true)
    }

    private func scheduleEvent() {
        guard !pendingEvent else { return }
        pendingEvent = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingEvent = false
            self.continuation?.yield()
        }
    }

    private func cancelSource(at index: Int) {
        targets[index].source?.cancel()
        targets[index].source = nil
    }

    private func nearestExistingDirectory(for fileURL: URL) -> URL? {
        var directory = fileURL.deletingLastPathComponent()
        while directory.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return FileManager.default.fileExists(atPath: "/") ? URL(fileURLWithPath: "/") : nil
    }

    private func signature(of fileURL: URL) -> FileSignature? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return nil }
        return FileSignature(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}
