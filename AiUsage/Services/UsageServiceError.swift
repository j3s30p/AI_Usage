import Foundation

enum UsageServiceError: LocalizedError, Sendable {
    case executableNotFound(String)
    case processStartFailed(String)
    case processClosed(String)
    case requestFailed(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case currentWindowUnavailable(String)
    case usageCacheUnavailable(String)
    case usageCacheWaiting
    case usageLimitsUnavailable
    case claudeOAuthAndCacheUnavailable
    case serviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            String(
                format: String(localized: "%@ CLI was not found. Install it and sign in first."),
                name
            )
        case .processStartFailed(let name):
            String(format: String(localized: "%@ could not be launched."), name)
        case .processClosed(let name):
            String(
                format: String(localized: "%@ connection ended unexpectedly."),
                name
            )
        case .requestFailed(let message):
            message
        case .requestTimedOut(let name):
            String(format: String(localized: "%@ usage request timed out."), name)
        case .invalidResponse(let name):
            String(format: String(localized: "%@ usage response could not be read."), name)
        case .currentWindowUnavailable(let name):
            String(format: String(localized: "No available usage limit was found for %@."), name)
        case .usageCacheUnavailable(let name):
            String(
                format: String(localized: "%@ statusLine cache is missing. Restart Claude Code, send a message, and refresh."),
                name
            )
        case .usageCacheWaiting:
            String(localized: "Claude Code의 첫 응답을 기다리는 중입니다.")
        case .usageLimitsUnavailable:
            String(localized: "Claude 사용 한도는 Claude.ai Pro/Max 로그인에서만 제공됩니다. API 키 세션은 지원되지 않습니다.")
        case .claudeOAuthAndCacheUnavailable:
            String(localized: "Claude OAuth를 무팝업으로 읽지 못했고 statusLine 캐시도 없습니다. Keychain 연결을 확인하거나 Claude Code에서 메시지를 보낸 뒤 다시 시도해 주세요.")
        case .serviceUnavailable(let name):
            String(format: String(localized: "%@ usage service could not be reached."), name)
        }
    }
}
