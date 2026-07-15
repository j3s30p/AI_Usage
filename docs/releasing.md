# AiUsage release process

This document describes how maintainers sign, notarize, and publish AiUsage through GitHub Releases and Homebrew. See the [README](../README.md) for user installation instructions.

## Release rules

- Never replace a published tag or release asset. The unsigned `v0.1.1` release remains part of the project history.
- Create release tags only for verified commits contained in `origin/main`.
- Publish only the final ZIP rebuilt from the app with its notarization ticket stapled.
- The Homebrew Cask SHA-256 must match the final ZIP published on GitHub.
- Never put certificates, private keys, passwords, or API keys in the repository, logs, or release assets.

## One-time Apple setup

1. The Apple Developer Program Account Holder creates a `Developer ID Application` certificate.
2. Export the certificate and private key from Keychain Access as a password-protected `.p12` file.
3. Create an App Store Connect Team API key for notarization and store its `.p8`, Key ID, and Issuer ID securely. The workflow expects a Team API key with an Issuer ID.
4. Verify that the certificate appears as a valid code-signing identity:

```bash
security find-identity -v -p codesigning
```

AiUsage distributes a ZIP containing an app, so a `Developer ID Installer` certificate is not required.

## GitHub Actions credentials and release environment

Create a `release` environment. Where possible, configure required reviewers, allow only `v*` tags to deploy, and protect `v*` tag creation, deletion, and force updates with a tag ruleset.

Register these six Actions secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | Apple Developer Team ID from the certificate |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect Team API `.p8` |
| `APPLE_API_KEY_ID` | Team API Key ID |
| `APPLE_API_ISSUER_ID` | Team API Issuer ID |

Repository secrets remain available to jobs that use the environment. Organizations that require environment secrets may register the same names there instead. Prefer GitHub's web settings so values do not enter terminal history. When using GitHub CLI, stream private files directly rather than printing their Base64 value:

```bash
/usr/bin/base64 -i DeveloperIDApplication.p12 \
  | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo j3s30p/AI_Usage
/usr/bin/base64 -i AuthKey.p8 \
  | gh secret set APPLE_API_KEY_P8_BASE64 --repo j3s30p/AI_Usage
```

Enter the remaining values through GitHub's private prompt or web settings. Before tagging, list secret names without exposing their values:

```bash
gh secret list --repo j3s30p/AI_Usage --json name --jq '.[].name' | sort
```

Sparkle update archives use a separate EdDSA key. Store its exported private
key as the `SPARKLE_PRIVATE_KEY` repository secret. The matching public key is
committed in `Config/AiUsage-Info.plist`; never commit the private key.

## Prepare a version

1. Set `MARKETING_VERSION` to the new semantic version.
2. Increment `CURRENT_PROJECT_VERSION` to an integer greater than the previous build.
3. Confirm that the README and technical documentation match the implementation and distribution state.
4. Run the complete test suite and verify a universal Release build.
5. Merge the pull request and synchronize local `main`.

The current `v1.1.1` project values are:

- `MARKETING_VERSION = 1.1.1`
- `CURRENT_PROJECT_VERSION = 6`

## Tag and publish a GitHub Release

After confirming that the merge commit is in `origin/main`:

```bash
git fetch origin main --tags
git switch main
git pull --ff-only origin main
git tag -a v1.1.1 -m "AiUsage v1.1.1"
git push origin v1.1.1
```

Pushing the tag starts `.github/workflows/release.yml`, which:

1. Validates the tag format, project version, build number, and `origin/main` ancestry.
2. Runs the complete test suite with ad-hoc signing.
3. Imports the Developer ID Application certificate into a temporary Keychain.
4. Builds an unsigned arm64 and x86_64 Release app without coverage instrumentation.
5. Applies Developer ID signing with Hardened Runtime and a secure timestamp.
6. Verifies the signature, Team ID, bundle ID, version, helper content, architectures, absence of LLVM coverage instrumentation, and absence of `get-task-allow`.
7. Submits a temporary ZIP with `notarytool submit --wait` and verifies the result and notarization log.
8. Staples the accepted ticket to the app.
9. Recreates the final ZIP from the stapled app.
10. Extracts and re-verifies the final ZIP with `codesign`, `stapler`, `spctl`, architecture, version, and helper checks.
11. Signs `appcast.xml` with the Sparkle EdDSA key.
12. Publishes the final ZIP, SHA-256 file, and appcast as a stable GitHub Release.
13. Deletes the temporary Keychain, `.p12`, and `.p8` whether the job succeeds or fails.

No GitHub Release is created unless notarization is accepted and every verification succeeds.

## Verify the published release

Download the ZIP from GitHub into a clean directory and repeat the distribution checks:

```bash
ditto -x -k AiUsage-v1.1.1-macos-universal.zip verify
codesign --verify --deep --strict --verbose=2 verify/AiUsage.app
spctl --assess --type execute --verbose=4 verify/AiUsage.app
xcrun stapler validate verify/AiUsage.app
lipo verify/AiUsage.app/Contents/MacOS/AiUsage -verify_arch arm64 x86_64
curl --fail --location \
  https://github.com/j3s30p/AI_Usage/releases/latest/download/appcast.xml
```

The signature must contain the expected Developer ID Application authority and Team ID, Hardened Runtime, and a secure timestamp. It must not include the `com.apple.security.get-task-allow` entitlement.

## Update Homebrew

After the GitHub Release succeeds, update `Casks/aiusage.rb` in `j3s30p/homebrew-tap`:

1. Change `version` to the new version.
2. Set `sha256` to the SHA-256 of the final GitHub ZIP.
3. Remove caveats that describe an unsigned or pre-notarization release.
4. Run `brew audit --cask j3s30p/tap/aiusage`.
5. Reinstall cleanly and repeat signature, Gatekeeper, and stapling checks on `/Applications/AiUsage.app`.
6. Exercise app launch, Codex and Claude reads, first OAuth approval, and launch-at-login registration and removal.

Do not publish a Homebrew version or SHA before its GitHub Release succeeds. End users update the installed app with `brew upgrade --cask aiusage`; `brew update` alone only refreshes Homebrew metadata.

## Credential handling

- Never paste private-key contents into GitHub logs or issues.
- Remove temporary Keychains and key files in the workflow's `always()` cleanup step.
- Revoke and replace Apple credentials and GitHub secrets immediately if exposure is suspected.
- Test a replacement certificate before the current one expires and revoke unused keys.
