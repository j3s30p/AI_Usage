import Foundation
import Security

struct ClaudeUsageProvider: UsageFetching {
    let provider = UsageProvider.claude

    func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try await Task.detached(priority: .utility) {
            try ClaudeCredentialReader.read()
        }.value

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageServiceError.serviceUnavailable("Claude")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageServiceError.serviceUnavailable("Claude")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageServiceError.invalidResponse("Claude")
        }
        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw UsageServiceError.authenticationExpired
        default:
            throw UsageServiceError.serviceUnavailable("Claude")
        }

        let payload: ClaudeUsageResponse
        do {
            payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw UsageServiceError.invalidResponse("Claude")
        }

        return try Self.makeSnapshot(from: payload)
    }

    static func makeSnapshot(
        from response: ClaudeUsageResponse,
        fetchedAt: Date = .now
    ) throws -> UsageSnapshot {
        guard let currentWindow = response.fiveHour,
              let resetAt = parseDate(currentWindow.resetsAt)
        else {
            throw UsageServiceError.currentWindowUnavailable("Claude")
        }

        let clampedUtilization = min(max(currentWindow.utilization, 0), 100)
        return UsageSnapshot(
            provider: .claude,
            remainingFraction: 1 - (clampedUtilization / 100),
            resetAt: resetAt,
            fetchedAt: fetchedAt
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
    }

    struct Window: Decodable, Sendable {
        let utilization: Double
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

private struct ClaudeCredentials: Sendable {
    let accessToken: String
}

private enum ClaudeCredentialReader {
    static func read() throws -> ClaudeCredentials {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw UsageServiceError.credentialsUnavailable
        }
        guard status != errSecUserCanceled,
              status != errSecAuthFailed,
              status != errSecInteractionNotAllowed
        else {
            throw UsageServiceError.credentialsAccessDenied
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw UsageServiceError.credentialsInvalid
        }

        let root: Root
        do {
            root = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            throw UsageServiceError.credentialsInvalid
        }

        guard let token = root.claudeAiOauth?.accessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw UsageServiceError.credentialsInvalid
        }
        return ClaudeCredentials(accessToken: token)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
    }
}
