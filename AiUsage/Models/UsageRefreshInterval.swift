import Foundation

enum UsageRefreshInterval: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case threeMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    var id: String { rawValue }

    var duration: Duration {
        .seconds(seconds)
    }

    var seconds: Int {
        switch self {
        case .oneMinute:
            60
        case .threeMinutes:
            180
        case .fiveMinutes:
            300
        case .fifteenMinutes:
            900
        case .thirtyMinutes:
            1_800
        }
    }

    var maximumExpectedSnapshotAge: TimeInterval {
        max(15 * 60, TimeInterval(seconds + 120))
    }

    var displayName: String {
        switch self {
        case .oneMinute:
            String(localized: "1분")
        case .threeMinutes:
            String(localized: "3분")
        case .fiveMinutes:
            String(localized: "5분")
        case .fifteenMinutes:
            String(localized: "15분")
        case .thirtyMinutes:
            String(localized: "30분")
        }
    }
}
