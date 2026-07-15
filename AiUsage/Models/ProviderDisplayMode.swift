import Foundation

enum ProviderDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case name
    case logo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            String(localized: "이름")
        case .logo:
            String(localized: "로고")
        }
    }
}
