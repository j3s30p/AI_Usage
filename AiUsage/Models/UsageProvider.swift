import Foundation

enum UsageProvider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case codex
    case claude

    var id: Self { self }

    var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        }
    }
}
