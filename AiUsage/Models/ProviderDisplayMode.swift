import Foundation

enum ProviderDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case name
    case logo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            "이름"
        case .logo:
            "로고"
        }
    }
}
