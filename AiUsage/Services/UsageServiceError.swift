import Foundation

enum UsageServiceError: LocalizedError, Sendable {
    case executableNotFound(String)
    case processStartFailed(String)
    case processClosed(String)
    case requestFailed(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case currentWindowUnavailable(String)
    case credentialsUnavailable
    case credentialsInvalid
    case credentialsAccessDenied
    case authenticationExpired
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
        case .credentialsUnavailable:
            "Claude Code 로그인 정보를 찾지 못했습니다. Claude Code에서 로그인해 주세요."
        case .credentialsInvalid:
            "Claude Code 로그인 정보를 읽을 수 없습니다. Claude Code에서 다시 로그인해 주세요."
        case .credentialsAccessDenied:
            "Claude 사용량을 읽으려면 키체인 접근을 허용해 주세요."
        case .authenticationExpired:
            "Claude 로그인이 만료되었습니다. Claude Code에서 다시 로그인해 주세요."
        case .serviceUnavailable(let name):
            "\(name) 사용량 서비스에 연결할 수 없습니다."
        }
    }
}
