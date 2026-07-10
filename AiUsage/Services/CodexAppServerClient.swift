import Darwin
import Foundation

// The JSONL transport follows OpenAI's public Codex app-server protocol.
// The line-stream implementation is intentionally small and keeps all auth handling inside Codex.
final class CodexAppServerClient: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lineStream: AsyncStream<Data>
    private let lineContinuation: AsyncStream<Data>.Continuation
    private let stateLock = NSLock()
    private var nextRequestID = 1
    private var isShutdown = false

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)
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

    init(executableURL: URL) throws {
        var continuation: AsyncStream<Data>.Continuation!
        lineStream = AsyncStream { continuation = $0 }
        lineContinuation = continuation

        process.executableURL = executableURL
        process.arguments = [
            "-s", "read-only",
            "-a", "untrusted",
            "app-server",
            "--listen", "stdio://",
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw UsageServiceError.processStartFailed("Codex")
        }

        do {
            try process.run()
        } catch {
            throw UsageServiceError.processStartFailed("Codex")
        }

        let outputBuffer = LineBuffer()
        let outputContinuation = lineContinuation
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                outputContinuation.finish()
                return
            }

            for line in outputBuffer.append(data) {
                outputContinuation.yield(line)
            }
        }

        // Drain stderr so a full pipe can never block app-server. It may contain diagnostics,
        // so the app deliberately neither persists nor displays the raw stream.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    deinit {
        shutdown()
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
            timeout: 8
        )
        try sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        let message = try await request(method: "account/rateLimits/read", timeout: 8)
        guard let result = message["result"] else {
            throw UsageServiceError.invalidResponse("Codex")
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        } catch {
            throw UsageServiceError.invalidResponse("Codex")
        }
    }

    func shutdown() {
        stateLock.lock()
        guard !isShutdown else {
            stateLock.unlock()
            return
        }
        isShutdown = true

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        stateLock.unlock()
    }

    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let requestID = try takeNextRequestID()
        try sendRequest(id: requestID, method: method, params: params)

        let message = try await withThrowingTaskGroup(of: SendableMessage.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw UsageServiceError.processClosed("Codex")
                }

                while true {
                    let candidate = try await self.readNextMessage()
                    guard self.integerID(candidate["id"]) == requestID else {
                        continue
                    }

                    if let error = candidate["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Codex 사용량 요청이 실패했습니다."
                        throw UsageServiceError.requestFailed(message)
                    }
                    return SendableMessage(value: candidate)
                }
            }

            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(timeout))
                self?.shutdown()
                throw UsageServiceError.requestTimedOut("Codex")
            }

            guard let first = try await group.next() else {
                throw UsageServiceError.requestTimedOut("Codex")
            }
            group.cancelAll()
            return first
        }

        return message.value
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        var payload: [String: Any] = ["id": id, "method": method]
        payload["params"] = params ?? [:]
        try send(payload)
    }

    private func sendNotification(method: String) throws {
        try send(["method": method, "params": [:]])
    }

    private func send(_ payload: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)

            stateLock.lock()
            defer { stateLock.unlock() }
            guard !isShutdown else {
                throw UsageServiceError.processClosed("Codex")
            }
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

    private func readNextMessage() async throws -> [String: Any] {
        for await line in lineStream {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            return message
        }
        throw UsageServiceError.processClosed("Codex")
    }

    private func integerID(_ value: Any?) -> Int? {
        switch value {
        case let id as Int:
            id
        case let number as NSNumber:
            number.intValue
        default:
            nil
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
