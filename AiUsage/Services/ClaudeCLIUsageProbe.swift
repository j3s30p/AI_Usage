import Darwin
import Foundation

struct ClaudeCLIUsageSnapshot: Sendable, Equatable {
    let sessionUsedPercentage: Double
    let sessionResetDescription: String?
    let weeklyUsedPercentage: Double?
    let weeklyResetDescription: String?
}

enum ClaudeCLIUsageProbeError: LocalizedError, Sendable, Equatable {
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
            "Claude CLI 사용량 조회를 시작하지 못했습니다."
        case .timedOut:
            "Claude CLI 사용량 조회 시간이 초과되었습니다."
        case .outputTooLarge:
            "Claude CLI가 지나치게 큰 응답을 반환했습니다."
        case .commandFailed(let status):
            "Claude CLI 사용량 조회가 종료 코드 \(status)로 실패했습니다."
        case .invalidOutput:
            "Claude CLI 사용량 응답을 해석하지 못했습니다."
        }
    }
}

struct ClaudeCLIUsageProcessRequest: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let currentDirectoryURL: URL
}

enum ClaudeCLIUsageProcessInput: Sendable, Equatable {
    case enter
    case finish
}

struct ClaudeCLIUsageProcessResult: Sendable, Equatable {
    let output: String
    let terminationStatus: Int32
    let completedByOutput: Bool

    init(
        output: String,
        terminationStatus: Int32,
        completedByOutput: Bool = false
    ) {
        self.output = output
        self.terminationStatus = terminationStatus
        self.completedByOutput = completedByOutput
    }
}

protocol ClaudeCLIUsageProcessRunning: Sendable {
    func run(
        _ request: ClaudeCLIUsageProcessRequest,
        onOutput: @escaping @Sendable (String) -> ClaudeCLIUsageProcessInput?
    ) async throws -> ClaudeCLIUsageProcessResult
}

struct ClaudeCLIUsageProbe: Sendable {
    private let executableURL: URL?
    private let scriptURL: URL
    private let timeout: TimeInterval
    private let workingDirectoryURL: URL
    private let processRunner: any ClaudeCLIUsageProcessRunning

    init(
        executableURL: URL? = ExecutableLocator.locate("claude"),
        scriptURL: URL = URL(fileURLWithPath: "/usr/bin/script"),
        timeout: TimeInterval = 20,
        workingDirectoryURL: URL? = nil,
        processRunner: any ClaudeCLIUsageProcessRunning = ClaudeCLIUsageLiveProcessRunner()
    ) {
        self.executableURL = executableURL
        self.scriptURL = scriptURL
        self.timeout = timeout
        self.workingDirectoryURL = workingDirectoryURL ?? Self.defaultWorkingDirectoryURL
        self.processRunner = processRunner
    }

    func fetchUsage() async throws -> ClaudeCLIUsageSnapshot {
        guard let executableURL else {
            throw ClaudeCLIUsageProbeError.executableNotFound
        }

        let request = ClaudeCLIUsageProcessRequest(
            executableURL: scriptURL,
            arguments: [
                "-q",
                "/dev/null",
                executableURL.path,
                "/usage",
                "--allowed-tools",
                "",
                "--safe-mode",
                "--ax-screen-reader",
            ],
            timeout: timeout,
            currentDirectoryURL: workingDirectoryURL
        )
        let trustPromptGate = ClaudeCLITrustPromptGate()
        let result = try await processRunner.run(request) { output in
            if Self.containsTrustPrompt(output), trustPromptGate.takeEnter() {
                return .enter
            }
            return Self.hasCompleteUsageOutput(output) ? .finish : nil
        }

        guard result.terminationStatus == 0 || result.completedByOutput else {
            throw ClaudeCLIUsageProbeError.commandFailed(result.terminationStatus)
        }
        return try Self.parse(result.output)
    }

    static func parse(_ output: String) throws -> ClaudeCLIUsageSnapshot {
        let cleanOutput = cleanTerminalOutput(output)
        let lines = cleanOutput.components(separatedBy: .newlines)
        guard let sessionLabelIndex = lastLabelIndex(
            "Current session",
            lines: lines
        ) else {
            throw ClaudeCLIUsageProbeError.invalidOutput
        }
        guard let session = parseWindow(
            label: "Current session",
            labelIndex: sessionLabelIndex,
            lines: lines
        ) else {
            throw ClaudeCLIUsageProbeError.invalidOutput
        }

        let weeklyLabel = "Current week (all models)"
        let normalizedWeeklyLabel = normalizedForLabelSearch(weeklyLabel)
        let weeklyLabelIndex = lines.indices.dropFirst(sessionLabelIndex + 1).first(where: {
            normalizedForLabelSearch(lines[$0]).contains(normalizedWeeklyLabel)
        })
        let weekly = weeklyLabelIndex.flatMap {
            parseWindow(label: weeklyLabel, labelIndex: $0, lines: lines)
        }
        return ClaudeCLIUsageSnapshot(
            sessionUsedPercentage: session.usedPercentage,
            sessionResetDescription: session.resetDescription,
            weeklyUsedPercentage: weekly?.usedPercentage,
            weeklyResetDescription: weekly?.resetDescription
        )
    }

    private static func containsTrustPrompt(_ output: String) -> Bool {
        let cleanOutput = cleanTerminalOutput(output)
        return cleanOutput.localizedCaseInsensitiveContains(
            "Do you trust the files in this folder?"
        ) || cleanOutput.localizedCaseInsensitiveContains(
            "Quick safety check: Is this a project you created or one you trust?"
        )
    }

    private static func hasCompleteUsageOutput(_ output: String) -> Bool {
        guard let snapshot = try? parse(output),
              snapshot.sessionResetDescription != nil
        else { return false }

        let normalized = normalizedForLabelSearch(cleanTerminalOutput(output))
        let hasWeeklyLabel = normalized.contains("currentweekallmodels")
        return !hasWeeklyLabel || (
            snapshot.weeklyUsedPercentage != nil
                && snapshot.weeklyResetDescription != nil
        )
    }

    private static let defaultWorkingDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AiUsage/ClaudeProbe")

    private static func parseWindow(
        label: String,
        labelIndex: Int,
        lines: [String]
    ) -> (usedPercentage: Double, resetDescription: String?)? {
        let normalizedLabel = normalizedForLabelSearch(label)
        var percentage: Double?
        var resetText: String?
        for (offset, line) in lines.dropFirst(labelIndex).prefix(14).enumerated() {
            let normalizedLine = normalizedForLabelSearch(line)
            if offset > 0,
               normalizedLine.hasPrefix("current"),
               !normalizedLine.contains(normalizedLabel) {
                break
            }
            if percentage == nil {
                percentage = usedPercentage(from: line)
            }
            if resetText == nil {
                resetText = resetDescription(from: line)
            }
        }

        guard let percentage else { return nil }
        return (percentage, resetText)
    }

    private static func lastLabelIndex(_ label: String, lines: [String]) -> Int? {
        let normalizedLabel = normalizedForLabelSearch(label)
        return lines.indices.reversed().first(where: {
            normalizedForLabelSearch(lines[$0]).contains(normalizedLabel)
        })
    }

    private static func usedPercentage(from line: String) -> Double? {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]),
              value.isFinite,
              (0...100).contains(value)
        else { return nil }
        return value
    }

    private static func resetDescription(from line: String) -> String? {
        guard let resetsRange = line.range(of: "Resets", options: .caseInsensitive) else {
            return nil
        }
        let raw = String(line[resetsRange.lowerBound...])
        let trimmed = raw.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "│┃╎╏┆┇┊┋ ")
            )
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedForLabelSearch(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
        )
    }

    private static func cleanTerminalOutput(_ output: String) -> String {
        var clean = output.replacingOccurrences(of: "\r", with: "\n")
        clean = clean.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        clean = clean.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return String(
            clean.unicodeScalars.filter {
                $0 == "\n" || $0 == "\t" || $0.value >= 0x20
            }
        )
    }
}

private final class ClaudeCLITrustPromptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didSendEnter = false

    func takeEnter() -> Bool {
        lock.withLock {
            guard !didSendEnter else { return false }
            didSendEnter = true
            return true
        }
    }
}

struct ClaudeCLIUsageLiveProcessRunner: ClaudeCLIUsageProcessRunning {
    func run(
        _ request: ClaudeCLIUsageProcessRequest,
        onOutput: @escaping @Sendable (String) -> ClaudeCLIUsageProcessInput?
    ) async throws -> ClaudeCLIUsageProcessResult {
        guard request.timeout > 0, request.timeout.isFinite else {
            throw ClaudeCLIUsageProbeError.timedOut
        }

        let session = try ClaudeCLIUsageProcessSession(
            request: request,
            onOutput: onOutput
        )
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ClaudeCLIUsageProcessResult.self) { group in
                group.addTask {
                    try await session.waitForResult()
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(request.timeout))
                    } catch {
                        throw error
                    }
                    session.timeOut()
                    throw ClaudeCLIUsageProbeError.timedOut
                }

                guard let first = try await group.next() else {
                    session.terminate()
                    throw ClaudeCLIUsageProbeError.processStartFailed
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            session.terminate()
        }
    }
}

private final class ClaudeCLIUsageProcessSession: @unchecked Sendable {
    private static let maximumOutputBytes = 1_048_576

    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let parentPID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let onOutput: @Sendable (String) -> ClaudeCLIUsageProcessInput?
    private let lock = NSLock()
    private var output = Data()
    private var terminationStatus: Int32?
    private var didReachOutputEOF = false
    private var terminalError: ClaudeCLIUsageProbeError?
    private var waiters: [
        CheckedContinuation<Result<ClaudeCLIUsageProcessResult, any Error>, Never>
    ] = []
    private var didRequestTermination = false
    private var didCompleteCapture = false
    private var rootProcessIdentity: ProcessIdentity?

    init(
        request: ClaudeCLIUsageProcessRequest,
        onOutput: @escaping @Sendable (String) -> ClaudeCLIUsageProcessInput?
    ) throws {
        self.onOutput = onOutput
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ClaudeCLIUsageProbeError.processStartFailed
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.outputDidReachEOF()
                return
            }
            self?.consume(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try FileManager.default.createDirectory(
                at: request.currentDirectoryURL,
                withIntermediateDirectories: true
            )
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
            throw ClaudeCLIUsageProbeError.processStartFailed
        }
    }

    func waitForResult() async throws -> ClaudeCLIUsageProcessResult {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                Result<ClaudeCLIUsageProcessResult, any Error>,
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

    func terminate() {
        let rootIdentity: ProcessIdentity? = lock.withLock {
            guard !didRequestTermination else { return nil }
            didRequestTermination = true
            return self.rootProcessIdentity
        }
        guard let rootIdentity else { return }
        Self.terminate(processTreeRootedAt: rootIdentity)
    }

    func timeOut() {
        lock.withLock {
            if terminalError == nil {
                terminalError = .timedOut
            }
        }
        terminate()
    }

    private func consume(_ data: Data) {
        let accumulatedOutput: String?
        let shouldTerminate: Bool
        lock.lock()
        if output.count + data.count > Self.maximumOutputBytes {
            terminalError = .outputTooLarge
            accumulatedOutput = nil
            shouldTerminate = true
        } else {
            output.append(data)
            accumulatedOutput = String(decoding: output, as: UTF8.self)
            shouldTerminate = false
        }
        lock.unlock()

        if shouldTerminate {
            terminate()
            return
        }
        guard let accumulatedOutput,
              let input = onOutput(accumulatedOutput)
        else { return }
        switch input {
        case .enter:
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        case .finish:
            lock.withLock {
                didCompleteCapture = true
            }
            terminate()
        }
    }

    private func outputDidReachEOF() {
        finishIfPossible {
            didReachOutputEOF = true
        }
    }

    private func processDidTerminate(status: Int32) {
        finishIfPossible {
            terminationStatus = status
        }
    }

    private func finishIfPossible(_ update: () -> Void) {
        let completions: ([
            CheckedContinuation<Result<ClaudeCLIUsageProcessResult, any Error>, Never>
        ], Result<ClaudeCLIUsageProcessResult, any Error>?) = lock.withLock {
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

    private func completedResultLocked() -> Result<ClaudeCLIUsageProcessResult, any Error>? {
        guard let terminationStatus, didReachOutputEOF else { return nil }
        if let terminalError {
            return .failure(terminalError)
        }
        return .success(
            ClaudeCLIUsageProcessResult(
                output: String(decoding: output, as: UTF8.self),
                terminationStatus: terminationStatus,
                completedByOutput: didCompleteCapture
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
            // Expand from every surviving original node. This still finds children if
            // /usr/bin/script has exited and its Claude child was re-parented in the meantime.
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
        // Children first keeps wrappers from re-parenting descendants before they are signalled.
        for identity in processTree.reversed() where isSameProcess(identity) {
            kill(identity.pid, signal)
        }
    }
}
