import Foundation

enum ClaudeUsageMode: String, CaseIterable, Identifiable, Sendable {
    case statusLine
    case oauth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .statusLine:
            String(localized: "statusLine 캐시 (권장)")
        case .oauth:
            String(localized: "OAuth Keychain (실험적)")
        }
    }

}
