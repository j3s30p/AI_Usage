import Foundation

enum ClaudeUsageMode: String, CaseIterable, Identifiable, Sendable {
    case statusLine
    case oauth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .statusLine:
            "statusLine 캐시 (권장)"
        case .oauth:
            "OAuth Keychain (실험적)"
        }
    }

}
