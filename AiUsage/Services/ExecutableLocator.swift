import Foundation

enum ExecutableLocator {
    static func locate(_ executable: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var candidates = [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "\(home)/.local/bin/\(executable)",
            "\(home)/bin/\(executable)",
            "/usr/bin/\(executable)",
        ]

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(executable)" })
        }

        for candidate in candidates {
            let expanded = NSString(string: candidate).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        return nil
    }
}
