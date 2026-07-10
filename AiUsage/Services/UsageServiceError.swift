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
    case allSourcesUnavailable(String)
    case serviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "\(name) CLI를 찾지 못했습니다. 먼저 설치하고 로그인해 주세요."
        case .processStartFailed(let name):
            "\(name)을 실행하지 못했습니다."
        case .processClosed(let name):
            "\(name) 연결이 예기치 않게 종료되었습니다."
        case .requestFailed(let message):
            message
        case .requestTimedOut(let name):
            "\(name) 사용량 조회 시간이 초과되었습니다."
        case .invalidResponse(let name):
            "\(name) 사용량 응답을 읽을 수 없습니다."
        case .currentWindowUnavailable(let name):
            "\(name)의 현재 5시간 사용량을 찾지 못했습니다."
        case .usageCacheUnavailable(let name):
            "\(name) statusLine 캐시가 없습니다. Claude Code를 다시 시작하고 메시지를 보낸 뒤 새로 고침해 주세요."
        case .usageCacheWaiting:
            "Claude Code의 첫 응답을 기다리는 중입니다."
        case .usageLimitsUnavailable:
            "Claude 사용 한도는 Claude.ai Pro/Max 로그인에서만 제공됩니다. API 키 세션은 지원되지 않습니다."
        case .allSourcesUnavailable(let name):
            "\(name) 사용량을 가져오지 못했습니다. OAuth 로그인, \(name) CLI, statusLine 캐시를 확인해 주세요."
        case .serviceUnavailable(let name):
            "\(name) 사용량 서비스에 연결할 수 없습니다."
        }
    }
}
