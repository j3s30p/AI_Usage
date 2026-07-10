import Foundation
import LocalAuthentication
import Security

struct ClaudeOAuthUsageResponse: Sendable, Equatable {
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?
}

struct ClaudeOAuthUsageWindow: Sendable, Equatable {
    let utilization: Double
    let resetsAt: Date?
}

enum ClaudeOAuthUsageClientError: LocalizedError, Sendable, Equatable {
    case credentialsUnavailable
    case credentialsUnreadable
    case credentialsInvalid
    case oauthCredentialsMissing
    case accessTokenMissing
    case expirationMissing
    case credentialsExpired
    case unauthorized
    case forbidden
    case rateLimited
    case httpFailure(Int)
    case invalidResponse
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            "Claude OAuth 인증 정보를 찾지 못했습니다."
        case .credentialsUnreadable:
            "Claude OAuth 인증 정보를 읽을 수 없습니다."
        case .credentialsInvalid:
            "Claude OAuth 인증 정보 형식이 올바르지 않습니다."
        case .oauthCredentialsMissing:
            "Claude Code 인증 정보에 claudeAiOauth 항목이 없습니다."
        case .accessTokenMissing:
            "Claude OAuth 액세스 토큰이 없습니다."
        case .expirationMissing:
            "Claude OAuth 인증 정보에 만료 시각이 없습니다."
        case .credentialsExpired:
            "Claude OAuth 인증이 만료되었습니다. Claude Code에서 다시 로그인해 주세요."
        case .unauthorized:
            "Claude OAuth 인증이 유효하지 않습니다. Claude Code에서 다시 로그인해 주세요."
        case .forbidden:
            "Claude OAuth 토큰에 사용량을 조회할 권한이 없습니다."
        case .rateLimited:
            "Claude OAuth 사용량 조회가 일시적으로 제한되었습니다. 잠시 후 다시 시도해 주세요."
        case .httpFailure(let statusCode):
            "Claude OAuth 사용량 조회가 실패했습니다. (HTTP \(statusCode))"
        case .invalidResponse:
            "Claude OAuth 사용량 응답을 읽을 수 없습니다."
        case .networkFailure:
            "Claude OAuth 사용량 서비스에 연결할 수 없습니다."
        }
    }
}

struct ClaudeOAuthUsageClient: Sendable {
    typealias CredentialLoader = @Sendable (URL) throws -> Data?

    private static let betaHeader = "oauth-2025-04-20"
    private static let keychainService = "Claude Code-credentials"

    private let session: URLSession
    private let baseURL: URL
    private let credentialsURL: URL
    private let credentialLoader: CredentialLoader
    private let now: @Sendable () -> Date

    init(
        session: URLSession? = nil,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false),
        credentialLoader: CredentialLoader? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session ?? Self.makeDefaultSession()
        self.baseURL = baseURL
        self.credentialsURL = credentialsURL
        if let credentialLoader {
            self.credentialLoader = credentialLoader
        } else {
            let loader = ClaudeOAuthCredentialLoader()
            self.credentialLoader = { try loader.load(from: $0) }
        }
        self.now = now
    }

    func fetchUsage() async throws -> ClaudeOAuthUsageResponse {
        let credentials = try loadCredentials()
        let request = makeRequest(accessToken: credentials.accessToken)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ClaudeOAuthUsageClientError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeOAuthUsageClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            return try decodeUsage(data)
        case 401:
            throw ClaudeOAuthUsageClientError.unauthorized
        case 403:
            throw ClaudeOAuthUsageClientError.forbidden
        case 429:
            throw ClaudeOAuthUsageClientError.rateLimited
        default:
            throw ClaudeOAuthUsageClientError.httpFailure(httpResponse.statusCode)
        }
    }

    private func loadCredentials() throws -> Credential {
        let data: Data
        do {
            guard let loadedData = try credentialLoader(credentialsURL), !loadedData.isEmpty else {
                throw ClaudeOAuthUsageClientError.credentialsUnavailable
            }
            data = loadedData
        } catch let error as ClaudeOAuthUsageClientError {
            throw error
        } catch {
            throw ClaudeOAuthUsageClientError.credentialsUnreadable
        }

        let root: CredentialRoot
        do {
            root = try JSONDecoder().decode(CredentialRoot.self, from: data)
        } catch {
            throw ClaudeOAuthUsageClientError.credentialsInvalid
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeOAuthUsageClientError.oauthCredentialsMissing
        }

        let accessToken = oauth.accessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw ClaudeOAuthUsageClientError.accessTokenMissing
        }
        guard let expiresAtMilliseconds = oauth.expiresAt else {
            throw ClaudeOAuthUsageClientError.expirationMissing
        }

        let expiresAt = Date(
            timeIntervalSince1970: expiresAtMilliseconds / 1_000
        )
        guard now() < expiresAt else {
            throw ClaudeOAuthUsageClientError.credentialsExpired
        }
        return Credential(accessToken: accessToken)
    }

    private func makeRequest(accessToken: String) -> URLRequest {
        let url = baseURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("oauth", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func decodeUsage(_ data: Data) throws -> ClaudeOAuthUsageResponse {
        let payload: UsagePayload
        do {
            payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        } catch {
            throw ClaudeOAuthUsageClientError.invalidResponse
        }

        return ClaudeOAuthUsageResponse(
            fiveHour: try makeWindow(payload.fiveHour),
            sevenDay: try makeWindow(payload.sevenDay)
        )
    }

    private func makeWindow(_ rawWindow: RawUsageWindow?) throws -> ClaudeOAuthUsageWindow? {
        guard let rawWindow else { return nil }
        let resetsAt: Date?
        if let rawReset = rawWindow.resetsAt {
            guard let parsedReset = Self.parseISO8601(rawReset) else {
                throw ClaudeOAuthUsageClientError.invalidResponse
            }
            resetsAt = parsedReset
        } else {
            resetsAt = nil
        }
        return ClaudeOAuthUsageWindow(
            utilization: rawWindow.utilization,
            resetsAt: resetsAt
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func readKeychainCredentialData() -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(keychainQuery as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static var keychainQuery: [CFString: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Automatic refresh must never interrupt the user with a Keychain dialog.
            // If access is not already available, OAuth cleanly falls through to CLI/statusLine.
            kSecUseAuthenticationContext: authenticationContext,
        ]
    }

    private struct Credential: Sendable {
        let accessToken: String
    }

    private struct CredentialRoot: Decodable {
        let claudeAiOauth: OAuthCredential?
    }

    private struct OAuthCredential: Decodable {
        let accessToken: String?
        let expiresAt: Double?
    }

    private struct UsagePayload: Decodable {
        let fiveHour: RawUsageWindow?
        let sevenDay: RawUsageWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct RawUsageWindow: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

final class ClaudeOAuthCredentialLoader: @unchecked Sendable {
    typealias KeychainReader = @Sendable () -> Data?

    private let keychainReader: KeychainReader

    init(
        keychainReader: @escaping KeychainReader = ClaudeOAuthUsageClient
            .readKeychainCredentialData
    ) {
        self.keychainReader = keychainReader
    }

    func load(from fileURL: URL) throws -> Data? {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                return try Data(contentsOf: fileURL)
            } catch {
                throw ClaudeOAuthUsageClientError.credentialsUnreadable
            }
        }

        // This query is explicitly non-interactive. Re-read so a token rotated by Claude Code
        // becomes available without restarting AiUsage; unavailable access falls through safely.
        return keychainReader()
    }
}
