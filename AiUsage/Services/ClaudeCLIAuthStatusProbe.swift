import Darwin
import Foundation

enum ClaudeCLIAuthStatusProbeError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case processStartFailed
    case timedOut
    case outputTooLarge
    case commandFailed(Int32)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Claude CLI를 찾지 못했습니다."
        case .processStartFailed:
            "Claude CLI 로그인 상태 확인을 시작하지 못했습니다."
        case .timedOut:
            "Claude CLI 로그인 상태 확인 시간이 초과되었습니다."
        case .outputTooLarge:
            "Claude CLI가 지나치게 큰 응답을 반환했습니다."
        case .commandFailed(let status):
            "Claude CLI 로그인 상태 확인이 종료 코드 \(status)로 실패했습니다."
        case .invalidOutput:
            "Claude CLI 로그인 상태 응답을 해석하지 못했습니다."
        }
    }
}

struct ClaudeCLIAuthStatusProcessRequest: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
}

struct ClaudeCLIAuthStatusProcessResult: Sendable, Equatable {
    let standardOutput: Data
    let terminationStatus: Int32
}

protocol ClaudeCLIAuthStatusProcessRunning: Sendable {
    func run(
        _ request: ClaudeCLIAuthStatusProcessRequest
    ) async throws -> ClaudeCLIAuthStatusProcessResult
}

struct ClaudeCLIAuthStatusProbe: Sendable {
    private struct AuthStatus: Decodable {
        let loggedIn: Bool
    }

    private let executableURL: URL?
    private let timeout: TimeInterval
    private let processRunner: any ClaudeCLIAuthStatusProcessRunning

    init(
        executableURL: URL? = ExecutableLocator.locate("claude"),
        timeout: TimeInterval = 5,
        processRunner: any ClaudeCLIAuthStatusProcessRunning =
            ClaudeCLIAuthStatusLiveProcessRunner()
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.processRunner = processRunner
    }

    func isLoggedIn() async throws -> Bool {
        try Task.checkCancellation()
        guard let executableURL else {
            throw ClaudeCLIAuthStatusProbeError.executableNotFound
        }

        let result = try await processRunner.run(
            ClaudeCLIAuthStatusProcessRequest(
                executableURL: executableURL,
                arguments: ["auth", "status", "--json"],
                timeout: timeout
            )
        )
        try Task.checkCancellation()

        if let status = try? JSONDecoder().decode(
            AuthStatus.self,
            from: result.standardOutput
        ) {
            guard status.loggedIn else { return false }
            guard result.terminationStatus == 0 else {
                throw ClaudeCLIAuthStatusProbeError.commandFailed(
                    result.terminationStatus
                )
            }
            return true
        }
        guard result.terminationStatus == 0 else {
            throw ClaudeCLIAuthStatusProbeError.commandFailed(
                result.terminationStatus
            )
        }
        throw ClaudeCLIAuthStatusProbeError.invalidOutput
    }
}

struct ClaudeCLIAuthStatusLiveProcessRunner: ClaudeCLIAuthStatusProcessRunning {
    private let maximumStandardOutputBytes: Int
    private let maximumStandardErrorBytes: Int

    init(
        maximumStandardOutputBytes: Int = 65_536,
        maximumStandardErrorBytes: Int = 65_536
    ) {
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
    }

    func run(
        _ request: ClaudeCLIAuthStatusProcessRequest
    ) async throws -> ClaudeCLIAuthStatusProcessResult {
        try Task.checkCancellation()
        guard request.timeout > 0,
              request.timeout.isFinite,
              maximumStandardOutputBytes > 0,
              maximumStandardErrorBytes > 0
        else {
            throw ClaudeCLIAuthStatusProbeError.timedOut
        }

        let session = try ClaudeCLIAuthStatusProcessSession(
            request: request,
            maximumStandardOutputBytes: maximumStandardOutputBytes,
            maximumStandardErrorBytes: maximumStandardErrorBytes
        )
        if Task.isCancelled {
            session.terminate()
            throw CancellationError()
        }

        return try await withTaskCancellationHandler {
            let result = try await withThrowingTaskGroup(
                of: ClaudeCLIAuthStatusProcessResult.self
            ) { group in
                group.addTask {
                    try await session.waitForResult()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeout))
                    session.timeOut()
                    throw ClaudeCLIAuthStatusProbeError.timedOut
                }

                guard let first = try await group.next() else {
                    session.terminate()
                    throw ClaudeCLIAuthStatusProbeError.processStartFailed
                }
                group.cancelAll()
                return first
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            session.terminate()
        }
    }
}

private final class ClaudeCLIAuthStatusProcessSession: @unchecked Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let parentPID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let maximumStandardOutputBytes: Int
    private let maximumStandardErrorBytes: Int
    private let lock = NSLock()

    private var standardOutput = Data()
    private var standardErrorByteCount = 0
    private var terminationStatus: Int32?
    private var didReachOutputEOF = false
    private var didReachErrorEOF = false
    private var terminalError: ClaudeCLIAuthStatusProbeError?
    private var didRequestTermination = false
    private var rootProcessIdentity: ProcessIdentity?
    private var waiters: [
        CheckedContinuation<
            Result<ClaudeCLIAuthStatusProcessResult, any Error>,
            Never
        >
    ] = []

    init(
        request: ClaudeCLIAuthStatusProcessRequest,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int
    ) throws {
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.outputDidReachEOF()
                return
            }
            self?.consumeStandardOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.errorDidReachEOF()
                return
            }
            self?.consumeStandardError(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
            let identity = Self.processIdentity(for: process.processIdentifier)
            let shouldTerminateImmediately = lock.withLock {
                rootProcessIdentity = identity
                return didRequestTermination
            }
            if shouldTerminateImmediately, let identity {
                Self.terminate(processTreeRootedAt: identity)
            }
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ClaudeCLIAuthStatusProbeError.processStartFailed
        }
    }

    func waitForResult() async throws -> ClaudeCLIAuthStatusProcessResult {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<ClaudeCLIAuthStatusProcessResult, any Error>,
                Never
            >) in
            lock.lock()
            if let completed = completedResultLocked() {
                lock.unlock()
                continuation.resume(returning: completed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
        return try result.get()
    }

    func timeOut() {
        lock.withLock {
            if terminalError == nil {
                terminalError = .timedOut
            }
        }
        terminate()
    }

    func terminate() {
        let rootIdentity: ProcessIdentity? = lock.withLock {
            guard !didRequestTermination else { return nil }
            didRequestTermination = true
            return rootProcessIdentity
        }
        guard let rootIdentity else { return }
        Self.terminate(processTreeRootedAt: rootIdentity)
    }

    private func consumeStandardOutput(_ data: Data) {
        let shouldTerminate = lock.withLock {
            guard terminalError == nil else { return false }
            guard standardOutput.count + data.count <= maximumStandardOutputBytes else {
                terminalError = .outputTooLarge
                return true
            }
            standardOutput.append(data)
            return false
        }
        if shouldTerminate {
            terminate()
        }
    }

    private func consumeStandardError(_ data: Data) {
        let shouldTerminate = lock.withLock {
            guard terminalError == nil else { return false }
            guard standardErrorByteCount + data.count <= maximumStandardErrorBytes else {
                terminalError = .outputTooLarge
                return true
            }
            standardErrorByteCount += data.count
            return false
        }
        if shouldTerminate {
            terminate()
        }
    }

    private func outputDidReachEOF() {
        finishIfPossible {
            didReachOutputEOF = true
        }
    }

    private func errorDidReachEOF() {
        finishIfPossible {
            didReachErrorEOF = true
        }
    }

    private func processDidTerminate(status: Int32) {
        finishIfPossible {
            terminationStatus = status
        }
    }

    private func finishIfPossible(_ update: () -> Void) {
        let completions: (
            [CheckedContinuation<
                Result<ClaudeCLIAuthStatusProcessResult, any Error>,
                Never
            >],
            Result<ClaudeCLIAuthStatusProcessResult, any Error>?
        ) = lock.withLock {
            update()
            guard let result = completedResultLocked() else { return ([], nil) }
            let pending = waiters
            waiters.removeAll()
            return (pending, result)
        }
        guard let result = completions.1 else { return }
        for continuation in completions.0 {
            continuation.resume(returning: result)
        }
    }

    private func completedResultLocked() -> Result<
        ClaudeCLIAuthStatusProcessResult,
        any Error
    >? {
        guard let terminationStatus,
              didReachOutputEOF,
              didReachErrorEOF
        else { return nil }
        if let terminalError {
            return .failure(terminalError)
        }
        return .success(
            ClaudeCLIAuthStatusProcessResult(
                standardOutput: standardOutput,
                terminationStatus: terminationStatus
            )
        )
    }

    private static func expandedProcessTree(
        from originalTree: [ProcessIdentity]
    ) -> [ProcessIdentity] {
        var identities: [pid_t: ProcessIdentity] = [:]
        for identity in originalTree {
            for current in processTree(rootedAt: identity) {
                identities[current.pid] = current
            }
        }
        return Array(identities.values)
    }

    private static func terminate(processTreeRootedAt root: ProcessIdentity) {
        let processTree = processTree(rootedAt: root)
        signal(processTree: processTree, with: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            // A wrapper can exit and re-parent a surviving child after SIGTERM.
            // Re-expand from every original identity before the final SIGKILL.
            let expandedTree = expandedProcessTree(from: processTree)
            signal(processTree: expandedTree, with: SIGKILL)
        }
    }

    private static func processTree(rootedAt root: ProcessIdentity) -> [ProcessIdentity] {
        guard isSameProcess(root) else { return [] }

        var result: [ProcessIdentity] = []
        var queue = [root]
        var visited: Set<pid_t> = []
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            guard visited.insert(parent.pid).inserted, isSameProcess(parent) else { continue }
            result.append(parent)

            for childPID in childProcessIdentifiers(of: parent.pid) {
                guard let child = processIdentity(for: childPID),
                      child.parentPID == parent.pid
                else { continue }
                queue.append(child)
            }
        }
        return result
    }

    private static func childProcessIdentifiers(of parentPID: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4_096 {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            let count = identifiers.withUnsafeMutableBytes { buffer in
                proc_listchildpids(
                    parentPID,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard count >= 0 else { return [] }
            if count < capacity {
                return Array(identifiers.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard actualSize == expectedSize,
              info.pbi_pid == UInt32(pid)
        else { return nil }

        return ProcessIdentity(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func isSameProcess(_ identity: ProcessIdentity) -> Bool {
        guard let current = processIdentity(for: identity.pid) else { return false }
        return current.startSeconds == identity.startSeconds
            && current.startMicroseconds == identity.startMicroseconds
    }

    private static func signal(processTree: [ProcessIdentity], with signal: Int32) {
        // Signal children first so wrappers cannot orphan them before they are reached.
        for identity in processTree.reversed() where isSameProcess(identity) {
            kill(identity.pid, signal)
        }
    }
}
