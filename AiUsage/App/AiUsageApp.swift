import SwiftUI

@main
@MainActor
struct AiUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: appDelegate.preferences,
                onConnectClaudeKeychain: {
                    try await appDelegate.connectClaudeKeychainFromUserAction()
                }
            )
        }
    }
}
