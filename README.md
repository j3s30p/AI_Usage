<p align="right">English | <a href="README.ko.md">한국어</a></p>

<p align="center">
  <img src="docs/images/aiusage-app-icon.png" width="112" alt="AiUsage app icon">
</p>

<h1 align="center">AiUsage</h1>

<p align="center">
  See your remaining Codex and Claude usage directly in the macOS menu bar.
</p>

<p align="center">
  <a href="https://github.com/j3s30p/AI_Usage/releases/latest"><img src="https://img.shields.io/github/v/release/j3s30p/AI_Usage?display_name=tag&sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Homebrew-Cask-FBB040?logo=homebrew&logoColor=000000" alt="Homebrew Cask">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
</p>

![AiUsage showing live usage](docs/images/aiusage-live-usage.png)

AiUsage is a native macOS menu bar app that shows the current usage limits reported by Codex and Claude in one place. Check the remaining percentage and reset time without switching apps or running a command.

## Features

- **Usage at a glance** — A menu bar ring and optional percentage show the current remaining allowance.
- **Five-hour and weekly limits** — The menu bar prefers the five-hour limit and falls back to the weekly limit when necessary. The popover shows both separately.
- **Codex and Claude together** — Show either provider or both.
- **Customizable menu bar** — Choose provider names or logos and whether to show percentages.
- **Automatic refresh** — Refresh every 1, 3, 5, 15, or 30 minutes; the default is 3 minutes.
- **Last known good value** — Temporary failures do not immediately replace valid usage with 100% or an empty state.
- **Launch at login** — Register through macOS without a helper app or terminal command.

## Install

### Homebrew

```bash
brew install --cask j3s30p/tap/aiusage
open -a AiUsage
```

To update an existing installation:

```bash
brew upgrade --cask aiusage
```

### Direct download

Download the universal macOS ZIP from the [latest GitHub Release](https://github.com/j3s30p/AI_Usage/releases/latest), extract it, and move `AiUsage.app` to Applications.

Release builds are signed with a Developer ID Application certificate and notarized by Apple. Both Apple Silicon and Intel Macs are supported.

## First launch

1. Select AiUsage in the menu bar and open **Settings**.
2. Choose the providers and display style you want in the menu bar.
3. Codex works without another connection step when the local Codex CLI is signed in.
4. For Claude, keep the recommended `statusLine cache` mode, select **Connect Claude statusLine…** once, and approve the change. You do not need to enter commands or edit settings files manually.

After the connection is established, Claude statusLine provides fresh usage when Claude Code produces its next response. AiUsage preserves a compatible existing statusLine and restores it when you disconnect. To read usage shared with Claude Desktop or claude.ai, you may select the experimental `OAuth Keychain` mode when valid Claude Code OAuth credentials are available.

## Display behavior

```text
Codex · [ring] 23% │ Claude · [ring] 48%
```

- At 100%, the ring is complete. As the remaining allowance decreases, it disappears clockwise from 12 o'clock.
- At 0%, a red 1-degree arc remains so an exhausted limit is still visible.
- A provider that has not connected displays a disconnected indicator instead of a guessed percentage.
- The popover shows the five-hour and weekly percentages with their reset times. Limits that the account does not provide are marked unavailable.

## Data sources

| Provider | Source | Notes |
| --- | --- | --- |
| Codex | Local `codex app-server` method `account/rateLimits/read` | Requires an installed and signed-in Codex CLI. AiUsage does not open another login window. |
| Claude statusLine | Local `~/.claude/usage-cache.json` cache | Recommended. Claude Code refreshes the value when it responds. |
| Claude OAuth | Claude Code's local credential store and Anthropic usage endpoint | Checked only after explicit selection. This experimental feature depends on a private API. |

If OAuth usage fails or credentials cannot be read silently in the background, AiUsage does not repeatedly show authentication prompts and falls back to the statusLine cache.

## Privacy and macOS permissions

AiUsage has no server of its own and includes no analytics SDK. Codex and Claude statusLine data are read locally. A request is sent to Anthropic's usage endpoint only when Claude OAuth mode is selected.

- AiUsage does not collect or log account email addresses, prompts, conversation content, session IDs, or working directories while reading usage.
- The statusLine cache stores only utilization, reset times, and capture time.
- A backup needed to restore existing Claude settings is stored locally with `0600` permissions.
- OAuth tokens and server error bodies are not stored in app settings or logs.
- Screen Recording and Accessibility permissions are not required.
- Keychain approval can begin only after the user explicitly selects Claude OAuth mode.
- Launch at login uses macOS `SMAppService`; if macOS requires approval, AiUsage links to System Settings.

See [Architecture and data sources](docs/architecture.md) for the full data flow and security boundaries.

## Troubleshooting

### The menu bar shows a disconnected indicator

- **Codex:** Confirm that the Codex CLI is signed in, then refresh the popover.
- **Claude statusLine:** Check the connection in Settings and send one message in Claude Code.
- **Claude OAuth:** Select OAuth mode again in Settings to verify authorization.

After a provider has connected successfully, AiUsage retains its recent value through temporary failures. When that value becomes too old, AiUsage shows a disconnected state instead of guessing.

### Launch at login cannot be enabled

Try enabling the setting again. If macOS requests approval, select **Open System Settings** and allow AiUsage under `General > Login Items & Extensions`.

## Requirements

- macOS 14 Sonoma or later
- Codex display: Codex CLI installed and signed in
- Claude display: Claude Code installed and signed in to a Claude.ai Pro or Max account

API-key sessions without a shared subscription limit are not supported.

## Documentation

- [Architecture and data sources](docs/architecture.md)
- [Maintainer release process](docs/releasing.md)
- [Brand assets and attribution](BRAND_ASSETS.md)

---

AiUsage is not made or endorsed by OpenAI or Anthropic. Codex, OpenAI, Claude, and Anthropic trademarks and logos belong to their respective owners.
