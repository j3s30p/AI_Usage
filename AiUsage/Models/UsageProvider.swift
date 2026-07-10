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

    var logoAssetName: String {
        switch self {
        case .codex:
            "CodexLogo"
        case .claude:
            "ClaudeLogo"
        }
    }

    var logoSourceInsetFraction: CGFloat {
        switch self {
        case .codex:
            // The official Blossom SVG has generous whitespace around its paths.
            0.23
        case .claude:
            0
        }
    }
}
