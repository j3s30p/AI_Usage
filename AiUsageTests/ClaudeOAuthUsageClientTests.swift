import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import AiUsage

final class ClaudeOAuthUsageClientTests: XCTestCase {
    override func tearDown() {
        RequestCapturingURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testFetchUsageParsesFiveHourAndSevenDayAndBuildsRequiredRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let credentialURL = URL(fileURLWithPath: "/tmp/injected-claude-credentials.json")
        let loadedURL = LockedBox<URL?>(nil)
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let credentials = credentialJSON(
            accessToken: "test-access-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let responseData = Data(
            #"{"five_hour":{"utilization":12.5,"resets_at":"2026-07-10T05:30:00.123Z"},"seven_day":{"utilization":44,"resets_at":"2026-07-14T00:00:00Z"}}"#.utf8
        )

        RequestCapturingURLProtocol.setHandler { request in
            capturedRequest.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseData)
        }

        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            baseURL: URL(string: "https://usage.example.test")!,
            credentialsURL: credentialURL,
            credentialLoader: { url in
                loadedURL.set(url)
                return credentials
            },
            now: { now }
        )

        let usage = try await client.fetchUsage()

        XCTAssertEqual(loadedURL.value, credentialURL)
        XCTAssertEqual(usage.fiveHour?.utilization, 12.5)
        XCTAssertEqual(usage.sevenDay?.utilization, 44)
        XCTAssertEqual(
            usage.fiveHour?.resetsAt,
            ISO8601DateFormatter.withFractionalSeconds.date(
                from: "2026-07-10T05:30:00.123Z"
            )
        )
        XCTAssertEqual(
            usage.sevenDay?.resetsAt,
            ISO8601DateFormatter.internetDateTime.date(
                from: "2026-07-14T00:00:00Z"
            )
        )

        let request = try XCTUnwrap(capturedRequest.value)
        XCTAssertEqual(request.url?.absoluteString, "https://usage.example.test/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer test-access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-beta"),
            "oauth-2025-04-20"
        )
    }

    func testMissingCredentialsIsExplicitAndDoesNotReachNetwork() async {
        let requestCount = LockedBox(0)
        RequestCapturingURLProtocol.setHandler { request in
            requestCount.withValue { $0 += 1 }
            throw URLError(.badServerResponse)
        }
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in nil }
        )

        await assertClientError(.credentialsUnavailable) {
            _ = try await client.fetchUsage()
        }
        XCTAssertEqual(requestCount.value, 0)
    }

    func testMissingAccessTokenIsExplicit() async {
        let data = Data(
            #"{"claudeAiOauth":{"expiresAt":2000000000000}}"#.utf8
        )
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in data }
        )

        await assertClientError(.accessTokenMissing) {
            _ = try await client.fetchUsage()
        }
    }

    func testMissingClaudeOAuthObjectIsExplicit() async {
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in Data(#"{"mcpOAuth":{}}"#.utf8) }
        )

        await assertClientError(.oauthCredentialsMissing) {
            _ = try await client.fetchUsage()
        }
    }

    func testMissingExpirationIsExplicit() async {
        let data = Data(
            #"{"claudeAiOauth":{"accessToken":"test-access-token"}}"#.utf8
        )
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in data }
        )

        await assertClientError(.expirationMissing) {
            _ = try await client.fetchUsage()
        }
    }

    func testExpiredCredentialIsRejectedBeforeNetworkRequest() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = credentialJSON(
            accessToken: "expired-test-token",
            expiresAt: now.addingTimeInterval(-1)
        )
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in data },
            now: { now }
        )

        await assertClientError(.credentialsExpired) {
            _ = try await client.fetchUsage()
        }
    }

    func testHTTPErrorDoesNotExposeCredentialOrResponseBody() async {
        let token = "sensitive-test-token"
        let data = credentialJSON(
            accessToken: token,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        RequestCapturingURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"error":"secret server detail"}"#.utf8))
        }
        let client = ClaudeOAuthUsageClient(
            session: makeSession(),
            credentialLoader: { _ in data }
        )

        do {
            _ = try await client.fetchUsage()
            XCTFail("Expected the request to fail.")
        } catch let error as ClaudeOAuthUsageClientError {
            XCTAssertEqual(error, .forbidden)
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(token))
            XCTAssertFalse(description.contains("secret server detail"))
        } catch {
            XCTFail("Expected ClaudeOAuthUsageClientError.")
        }
    }

    func testDefaultCredentialLoaderReloadsRotatedKeychainCredential() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingFile = directory.appendingPathComponent("credentials.json")
        let readCount = LockedBox(0)
        let first = Data(#"{"claudeAiOauth":{"accessToken":"first"}}"#.utf8)
        let second = Data(#"{"claudeAiOauth":{"accessToken":"second"}}"#.utf8)
        let loader = ClaudeOAuthCredentialLoader {
            var result = first
            readCount.withValue {
                $0 += 1
                if $0 > 1 { result = second }
            }
            return result
        }

        XCTAssertEqual(try loader.load(from: missingFile), first)
        XCTAssertEqual(try loader.load(from: missingFile), second)
        XCTAssertEqual(readCount.value, 2)
    }

    func testAutomaticKeychainQueryForbidsAuthenticationUIWithBothPolicies() {
        let query = ClaudeOAuthUsageClient.keychainQuery
        let context = query[kSecUseAuthenticationContext] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI] as? String,
            ClaudeKeychainNoUIQuery.uiFailPolicyForTesting()
        )
    }

    func testUserInitiatedKeychainQueryAllowsDefaultAuthenticationUI() {
        let query = ClaudeOAuthUsageClient.userInitiatedKeychainQuery

        XCTAssertNil(query[kSecUseAuthenticationContext])
        XCTAssertNil(query[kSecUseAuthenticationUI])
    }

    func testUserInitiatedAccessReturnsOnlySanitizedCredentialState() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = "credential-must-never-escape"
        let credentialData = credentialJSON(
            accessToken: secret,
            expiresAt: now.addingTimeInterval(3_600)
        )
        let access = ClaudeOAuthUserInitiatedKeychainAccess(
            keychainReader: {
                ClaudeOAuthKeychainReadResult(
                    status: errSecSuccess,
                    data: credentialData
                )
            },
            now: { now }
        )

        let result = await access.requestAccessFromUserAction()

        XCTAssertEqual(result, .available)
        XCTAssertFalse(String(describing: result).contains(secret))
    }

    func testUserInitiatedAccessSanitizesDeniedCancelledAndInvalidResults() async {
        let denied = ClaudeOAuthUserInitiatedKeychainAccess(
            keychainReader: {
                ClaudeOAuthKeychainReadResult(
                    status: errSecAuthFailed,
                    data: Data("denied-secret".utf8)
                )
            }
        )
        let cancelled = ClaudeOAuthUserInitiatedKeychainAccess(
            keychainReader: {
                ClaudeOAuthKeychainReadResult(
                    status: errSecUserCanceled,
                    data: Data("cancelled-secret".utf8)
                )
            }
        )
        let invalid = ClaudeOAuthUserInitiatedKeychainAccess(
            keychainReader: {
                ClaudeOAuthKeychainReadResult(
                    status: errSecSuccess,
                    data: Data("invalid-secret".utf8)
                )
            }
        )

        let deniedResult = await denied.requestAccessFromUserAction()
        let cancelledResult = await cancelled.requestAccessFromUserAction()
        let invalidResult = await invalid.requestAccessFromUserAction()

        XCTAssertEqual(deniedResult, .denied)
        XCTAssertEqual(cancelledResult, .cancelled)
        XCTAssertEqual(invalidResult, .invalidCredentials)
        let descriptions = [deniedResult, cancelledResult, invalidResult]
            .map(String.init(describing:))
            .joined(separator: " ")
        XCTAssertFalse(descriptions.contains("denied-secret"))
        XCTAssertFalse(descriptions.contains("cancelled-secret"))
        XCTAssertFalse(descriptions.contains("invalid-secret"))
    }

    func testUserInitiatedAccessReportsExpiredWithoutReturningCredential() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = "expired-secret"
        let credentialData = credentialJSON(
            accessToken: secret,
            expiresAt: now.addingTimeInterval(-1)
        )
        let access = ClaudeOAuthUserInitiatedKeychainAccess(
            keychainReader: {
                ClaudeOAuthKeychainReadResult(
                    status: errSecSuccess,
                    data: credentialData
                )
            },
            now: { now }
        )

        let result = await access.requestAccessFromUserAction()

        XCTAssertEqual(result, .expired)
        XCTAssertFalse(String(describing: result).contains(secret))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func credentialJSON(accessToken: String, expiresAt: Date) -> Data {
        let expiresAtMilliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        return Data(
            #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","expiresAt":\#(expiresAtMilliseconds)}}"#.utf8
        )
    }

    private func assertClientError(
        _ expected: ClaudeOAuthUsageClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).")
        } catch let error as ClaudeOAuthUsageClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected ClaudeOAuthUsageClientError.")
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.lock()
        operation(&storedValue)
        lock.unlock()
    }
}

private final class RequestCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    private static func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static var internetDateTime: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
