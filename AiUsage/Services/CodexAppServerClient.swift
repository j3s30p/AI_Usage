import Darwin
import Foundation

struct CodexAppServerNotification: Sendable, Equatable {
    let method: String
    let rawData: Data
}

// The JSONL transport follows OpenAI's public Codex app-server protocol.
// A single reader dispatches responses by request id while forwarding notifications separately.
final class CodexAppServerClient: @unchecked Sendable {
    private static let defaultArguments = [
        "-s", "read-only",
        "-a", "untrusted",
        "app-server",
        "--listen", "stdio://",
    ]

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let notificationContinuation: AsyncStream<CodexAppServerNotification>.Continuation
    private let requestTimeout: TimeInterval
    let notifications: AsyncStream<CodexAppServerNotification>

    private let stateLock = NSLock()
    private var nextRequestID = 1
    private var isShutdown = false
    private var pendingRequests: [Int: PendingRequest] = [:]

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct MessageHeader: Decodable {
        let id: Int?
        let method: String?
        let error: ResponseError?
    }

    private struct ResponseError: Decodable {
        let message: String?
    }

    private struct RateLimitsEnvelope: Decodable {
        let result: CodexRateLimitsResponse?
    }

    private final class LineBuffer: @unchecked Sendable {
        enum AppendResult {
            case lines([Data])
            case overflow
        }

        private static let maximumLineBytes = 1_048_576
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) -> AppendResult {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)
            guard buffer.count <= Self.maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                return .overflow
            }
            return .lines(takeCompleteLines())
        }

        func finish() -> [Data] {
            lock.lock()
            defer { lock.unlock() }

            var lines = takeCompleteLines()
            if !buffer.isEmpty {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: false)
            }
            return lines
        }

        private func takeCompleteLines() -> [Data] {
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
    }

    init(
        executableURL: URL,
        arguments: [String]? = nil,
        requestTimeout: TimeInterval = 8
    ) throws {
        var continuation: AsyncStream<CodexAppServerNotification>.Continuation!
        notifications = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
            continuation = $0
        }
        notificationContinuation = continuation
        self.requestTimeout = requestTimeout

        process.executableURL = executableURL
        process.arguments = arguments ?? Self.defaultArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            notificationContinuation.finish()
            throw UsageServiceError.processStartFailed("Codex")
        }

        let outputBuffer = LineBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                for line in outputBuffer.finish() {
                    self?.receive(line)
                }
                self?.connectionDidClose()
                return
            }

            switch outputBuffer.append(data) {
            case .lines(let lines):
                for line in lines {
                    self?.receive(line)
                }
            case .overflow:
                handle.readabilityHandler = nil
                self?.connectionDidClose()
            }
        }

        // Drain stderr so a full pipe can never block app-server. It may contain diagnostics,
        // so the app deliberately neither persists nor displays the raw stream.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            notificationContinuation.finish()
            throw UsageServiceError.processStartFailed("Codex")
        }
    }

    deinit {
        shutdown()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isShutdown && process.isRunning
    }

    var processIdentifier: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process.processIdentifier
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "aiusage",
                    "title": "AiUsage",
                    "version": "0.1.0",
                ],
            ],
            timeout: requestTimeout
        )
        try sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        let data = try await request(
            method: "account/rateLimits/read",
            timeout: requestTimeout
        )
        do {
            guard let result = try JSONDecoder().decode(RateLimitsEnvelope.self, from: data).result else {
                throw UsageServiceError.invalidResponse("Codex")
            }
            return result
        } catch let error as UsageServiceError {
            throw error
        } catch {
            throw UsageServiceError.invalidResponse("Codex")
        }
    }

    func shutdown() {
        closeConnection(terminateProcess: true)
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        let requestID = try takeNextRequestID()
        let payload = try serializeRequest(id: requestID, method: method, params: params)

        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                stateLock.lock()
                guard !isShutdown else {
                    stateLock.unlock()
                    continuation.resume(throwing: UsageServiceError.processClosed("Codex"))
                    return
                }
                pendingRequests[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: nil
                )
                stateLock.unlock()

                // Cancellation can race with registration after the first check above.
                // Re-check once the continuation is visible to the cancellation handler.
                if Task.isCancelled {
                    completeRequest(
                        id: requestID,
                        result: .failure(CancellationError())
                    )
                    return
                }

                do {
                    try sendSerialized(payload)
                } catch {
                    completeRequest(
                        id: requestID,
                        result: .failure(UsageServiceError.processClosed("Codex"))
                    )
                    closeConnection(terminateProcess: true)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.requestDidTimeOut(id: requestID)
                }

                stateLock.lock()
                if var pending = pendingRequests[requestID] {
                    pending.timeoutTask = timeoutTask
                    pendingRequests[requestID] = pending
                    stateLock.unlock()
                } else {
                    stateLock.unlock()
                    timeoutTask.cancel()
                }
            }
        } onCancel: { [weak self] in
            self?.completeRequest(id: requestID, result: .failure(CancellationError()))
        }

        let header = try? JSONDecoder().decode(MessageHeader.self, from: data)
        if header?.error != nil {
            // The server message can contain account, path, or request details. Keep the UI generic.
            throw UsageServiceError.requestFailed("Codex 사용량 요청이 실패했습니다.")
        }
        return data
    }

    private func serializeRequest(
        id: Int,
        method: String,
        params: [String: Any]?
    ) throws -> Data {
        var payload: [String: Any] = ["id": id, "method": method]
        payload["params"] = params ?? [:]
        do {
            return try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw UsageServiceError.invalidResponse("Codex")
        }
    }

    private func sendNotification(method: String) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: ["method": method, "params": [:]],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw UsageServiceError.invalidResponse("Codex")
        }
        try sendSerialized(data)
    }

    private func sendSerialized(_ data: Data) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown else {
            throw UsageServiceError.processClosed("Codex")
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            try inputPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        } catch {
            throw UsageServiceError.processClosed("Codex")
        }
    }

    private func takeNextRequestID() throws -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutdown else {
            throw UsageServiceError.processClosed("Codex")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        return requestID
    }

    private func receive(_ data: Data) {
        guard let header = try? JSONDecoder().decode(MessageHeader.self, from: data) else {
            return
        }

        if let method = header.method {
            stateLock.lock()
            let shouldForward = !isShutdown
            stateLock.unlock()
            if shouldForward {
                notificationContinuation.yield(
                    CodexAppServerNotification(method: method, rawData: data)
                )
            }
            return
        }

        guard let id = header.id else { return }
        completeRequest(id: id, result: .success(data))
    }

    private func requestDidTimeOut(id: Int) {
        let didComplete = completeRequest(
            id: id,
            result: .failure(UsageServiceError.requestTimedOut("Codex"))
        )
        if didComplete {
            closeConnection(terminateProcess: true)
        }
    }

    @discardableResult
    private func completeRequest(
        id: Int,
        result: Result<Data, any Error>
    ) -> Bool {
        stateLock.lock()
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            stateLock.unlock()
            return false
        }
        stateLock.unlock()

        pending.timeoutTask?.cancel()
        pending.continuation.resume(with: result)
        return true
    }

    private func connectionDidClose() {
        closeConnection(terminateProcess: true)
    }

    private func closeConnection(terminateProcess: Bool) {
        let pending: [PendingRequest]

        stateLock.lock()
        guard !isShutdown else {
            stateLock.unlock()
            return
        }
        isShutdown = true
        pending = Array(pendingRequests.values)
        pendingRequests.removeAll()
        stateLock.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        notificationContinuation.finish()

        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.resume(
                throwing: UsageServiceError.processClosed("Codex")
            )
        }

        if terminateProcess && process.isRunning {
            process.terminate()
            let process = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

struct CodexRateLimitsResponse: Decodable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    struct RateLimitSnapshot: Decodable, Sendable {
        let primary: Window?
        let secondary: Window?

        var windows: [Window] {
            [primary, secondary].compactMap { $0 }
        }
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Int64?
    }
}
