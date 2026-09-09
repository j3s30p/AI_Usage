import AppKit
import Foundation

enum ExecutableLocator {
    static func locate(_ executable: String) -> URL? {
        if executable == "codex" {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let applications = [
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
                URL(fileURLWithPath: "/Applications/Codex.app"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                home.appendingPathComponent("Applications/Codex.app"),
                home.appendingPathComponent("Applications/ChatGPT.app"),
            ].compactMap { $0 }
            return locateCodex(
                applicationURLs: applications,
                cliCandidates: cliCandidates(for: executable)
            )
        }

        return locateCLI(candidates: cliCandidates(for: executable))
    }

    static func locateCodex(
        applicationURLs: [URL],
        cliCandidates: [URL]
    ) -> URL? {
        for applicationURL in applicationURLs {
            let bundledExecutable = applicationURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
                return bundledExecutable
            }
        }

        return locateCLI(candidates: cliCandidates)
    }

    private static func locateCLI(candidates: [URL]) -> URL? {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static func cliCandidates(for executable: String) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var paths = [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "\(home)/.local/bin/\(executable)",
            "\(home)/bin/\(executable)",
            "/usr/bin/\(executable)",
        ]

        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/\(executable)" })
        }

        return paths.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }
}
