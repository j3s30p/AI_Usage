# AiUsage architecture and data sources

This document describes AiUsage's implementation, the Codex and Claude usage sources, and its Keychain and privacy boundaries. See the project [README](../README.md) for installation and everyday use.

## Technology

- macOS 14 or later and Swift 6
- SwiftUI two-tab settings and popover views
- AppKit `NSStatusItem` menu bar UI
- Observation-based app state and preferences
- Foundation `URLSession`, `Process`, and Swift Concurrency
- macOS Security and LocalAuthentication for Keychain access
- ServiceManagement `SMAppService.mainApp` for launch at login
- Sparkle 2 for signed automatic updates

The main data path is:

```text
AppPreferences → AppDelegate → AppModel → UsageRepository
                                           ├─ CodexUsageProvider
                                           └─ ClaudeUsageProvider
```

Changing a preference cancels the current monitor and starts a new one with the selected interval and Claude source. Changing the Claude source clears the previous source's snapshot immediately so an older OAuth result cannot hide a newer local result solely because of its timestamp.

Launch at login uses `SMAppService.mainApp` without a helper or shell script. Registration changes only when the user changes the setting. AiUsage refreshes the system state when it becomes active and can open Login Items settings when macOS requires approval.

The menu bar's names, logos, and percentages remain in a template image so macOS can adapt them to light and dark menu bars. When usage ring colors are enabled, only the rings are drawn in a separate overlay: red through 5%, yellow through 30%, and green above 30%. The same thresholds apply to the larger rings in the popover. Color thresholds use the rounded percentage shown to the user.

At launch and every 24 hours, AiUsage asks Sparkle to probe the signed appcast without presenting update UI. Settings shows the installed and latest versions. When Sparkle reports a newer valid release, the popover shows an update button; selecting it starts Sparkle's standard signed update flow.

## Codex

AiUsage keeps one local `codex app-server` connection while Codex is enabled. At the selected interval it calls the official `account/rateLimits/read` method, reads the 300-minute and 10,080-minute windows, and reconnects with backoff after a disconnection.

When a response contains both default Codex and model-specific limits, AiUsage uses only the explicit `codex` limit. If the default limit briefly disappears from a multi-limit response, AiUsage reports a fetch failure instead of substituting another model's 100% value. A recent valid value remains visible within the allowed age for the selected refresh interval.

## Claude sources

The user chooses between two modes backed by three inputs. The default is `Local caches (recommended)`.

- Local caches checks the Claude Code statusLine cache first. A current statusLine snapshot is returned without reading Claude Desktop data. If the statusLine snapshot is unavailable, stale, or past its reset time, AiUsage checks Claude Desktop usage history. It uses Desktop data when that sample is current or newer; otherwise it retains a parsed statusLine snapshot.
- OAuth checks the private OAuth endpoint first. If that fails, AiUsage runs the same statusLine-to-Desktop local chain.

### statusLine cache

- Reads only the local `~/.claude/usage-cache.json` file.
- Does not access Keychain or start a login or browser flow.
- Refreshes when Claude Code's official [statusLine](https://code.claude.com/docs/en/statusline) runs.

```text
Claude Code → ~/.claude/aiusage/statusline-wrapper.sh
            → statusline-cache.sh
            → ~/.claude/usage-cache.json → AiUsage
```

The cache contains utilization, reset times, and capture time only. It does not contain a session ID, prompt, or working directory.

#### In-app connection

After the user selects **Connect Claude statusLine…** and approves the change, AiUsage:

1. Reads `~/.claude/settings.json` and verifies that its format can be preserved safely.
2. Stores the pre-change configuration in a dedicated `0600` backup.
3. Installs the bundled collector and wrapper under `~/.claude/aiusage/`.
4. Preserves other Claude settings and changes only `statusLine.command` to the AiUsage wrapper.

If a compatible statusLine command already exists, AiUsage stores it in a dedicated `0600` file and forwards the same JSON input to it, preserving its output and exit status. On disconnect, AiUsage restores the original statusLine only if the current setting exactly matches the installed value. It will not overwrite malformed JSON, an unknown statusLine format, a symbolic link, or a configuration changed externally after connection.

### OAuth Keychain (experimental)

- Checks `~/.claude/.credentials.json` first, then the `Claude Code-credentials` Keychain item.
- Background refresh uses `LAContext.interactionNotAllowed` and an explicit no-UI Keychain policy. Credentials are read only when access requires no prompt.
- If the private `https://api.anthropic.com/api/oauth/usage` request fails or Keychain cannot be read silently, AiUsage checks the statusLine cache and then Claude Desktop usage history without starting a login flow.
- Explicitly selecting OAuth mode is the sole boundary at which AiUsage may request Keychain approval. A cancellation or failure keeps the previous source.

The OAuth usage endpoint is not part of Anthropic's public API contract and may change or disappear. Refer to Anthropic's current [authentication and credential policy](https://code.claude.com/docs/en/legal-and-compliance).

## Claude Desktop and web

Claude Desktop does not update the AiUsage statusLine cache. As a local fallback, AiUsage reads version 2 of Claude Desktop's private, versioned `~/Library/Application Support/Claude/plan-usage-history.json` file. Invalid data and unknown versions are ignored safely.

AiUsage selects the last recorded sample and reads its capture time plus five-hour and weekly utilization. The file does not include reset times, so AiUsage does not infer them and the popover omits the reset line. Claude Desktop normally records a sample about every five minutes while running, but there is no hard freshness bound: logout, sleep, network errors, or API failures can create much longer gaps.

Each sample includes an organization identifier. AiUsage ignores that value and does not store or log it. For accounts with multiple organizations, the last sample may belong to the last recorded organization rather than the organization currently selected in Claude Desktop.

Using claude.ai without opening Claude Desktop or Claude Code does not create a local sample for AiUsage. AiUsage does not read browser cookies, conversation data, OAuth tokens, Local Storage, Session Storage, or any Claude Desktop data other than the plan usage history file.

## Keychain and code signing

Starting with `v1.0.0`, GitHub Release and Homebrew builds are signed with Developer ID Application, use Hardened Runtime and a secure timestamp, and are notarized by Apple. The notarization ticket is stapled to the app before the final ZIP is created, allowing Gatekeeper to verify distribution state while offline.

A stable Developer ID identity improves Keychain approval continuity. Explicit first-time approval may still be required for OAuth mode. Local development builds use ad-hoc signing and may be treated as another identity, causing renewed Keychain approval or unavailable launch-at-login registration.

See the [maintainer release process](releasing.md) for signing, notarization, verification, and Homebrew publication.

## Stored and excluded data

App preferences contain only:

- Enabled providers
- Name or logo display and percentage visibility
- Optional usage-based ring colors
- Refresh interval
- Claude usage source
- App language

After statusLine connection is approved, `~/.claude/aiusage/` contains connection scripts, metadata, the pre-change backup, and any existing statusLine command. These files are used only for preservation and exact disconnection and use `0600` or `0700` permissions.

Claude Desktop plan usage history is read in place and is not copied into app settings. Its organization identifier is ignored and is not stored or logged.

AiUsage does not store account email addresses, organization identifiers, session IDs, prompts, working directories, OAuth tokens, or server error bodies in app settings or logs. OAuth credentials remain in memory only while a request is created.
