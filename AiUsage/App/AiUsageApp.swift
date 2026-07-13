import SwiftUI

@main
@MainActor
struct AiUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: appDelegate.preferences,
                launchAtLoginController: appDelegate.launchAtLoginController,
                statusLineModel: appDelegate.statusLineSettingsModel,
                onAuthorizeClaudeOAuth: {
                    await appDelegate.authorizeClaudeOAuthFromUserSelection()
                }
            )
        }
    }
}
