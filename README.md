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

- **Codex and Claude together** — See both providers in one menu bar app.
- **Five-hour and weekly limits** — Check remaining percentages and reset times at a glance.
- **A menu bar that fits** — Choose names or logos, percentages, refresh timing, and optional usage-based ring colors.
- **Reliable background monitoring** — Keep the latest valid value through temporary failures and optionally launch at login.

![AiUsage menu bar showing Codex and Claude remaining usage](docs/images/aiusage-menubar.png)

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
2. Use the **General** tab for app behavior and Claude connections, and the **Menu Bar** tab to choose providers, display style, refresh interval, and optional usage ring colors.
3. Codex works without another connection step when the local Codex CLI is signed in.
4. For Claude, keep the recommended `statusLine cache` mode, select **Connect Claude statusLine…** once, and approve the change. You do not need to enter commands or edit settings files manually.

Claude statusLine provides fresh usage after Claude Code's next response. AiUsage preserves a compatible existing statusLine and restores it when disconnected. Experimental OAuth mode is also available for compatible Claude Code credentials.

## Privacy and macOS permissions

AiUsage has no server of its own and includes no analytics SDK.

- Codex and Claude statusLine data are read locally.
- Prompts, conversations, account emails, session IDs, and working directories are not collected or logged.
- Screen Recording and Accessibility permissions are not required.

See [Architecture and data sources](docs/architecture.md) for the full data flow and security boundaries.

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
