import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case korean = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            String(localized: "System Default")
        case .english:
            "English"
        case .korean:
            "한국어"
        }
    }

    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .korean: ["ko"]
        }
    }
}
