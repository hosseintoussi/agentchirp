# Signed Mac app releases

AgentChirp ships as a universal `AgentChirp.app` inside `AgentChirp.dmg`. The app
and DMG are signed with Developer ID, notarized, and stapled. A separate ZIP of
the stapled app is signed with Sparkle's Ed25519 key for in-app updates. The
release workflow publishes all three files together: DMG, ZIP, and `appcast.xml`.
There is no Homebrew release step.

## Local development and verification

```sh
swift build -c release
swift run AgentChirpTests
python3 Tests/Hooks/test_claude.py
python3 Tests/Hooks/test_codex.py
python3 Tests/CodexRuntime/test_launcher.py
python3 Tests/CodexRuntime/test_runtime.py
python3 Tests/Release/test_release.py
python3 scripts/package_app.py --development
python3 Tests/Release/test_bundle.py dist/AgentChirp.app
dist/AgentChirp.app/Contents/MacOS/agentchirp --ui-check
dist/AgentChirp.app/Contents/MacOS/agentchirp --installation-check /tmp/agentchirp-setup
python3 -m venv .build/packaging-venv
.build/packaging-venv/bin/pip install -r Packaging/requirements.txt
python3 scripts/distribute.py --development
python3 Tests/Release/test_dmg.py
```

The development app uses an ad-hoc signature by default; pass `--identity` to
exercise your Developer ID signature locally. It is marked as development and
does not start Sparkle or register login items. The diagnostic modes above skip
normal application launch and integration setup. The generated development DMG
is for local review only; do not publish it.

Builds require macOS, Swift/Xcode Command Line Tools, and Python 3. End users need
none of these developer tools. The packaging script builds each architecture
separately and combines them with `lipo`, so it also works with Command Line Tools
without a full Xcode installation.

## One-time signing setup

1. In Keychain Access, obtain a **Developer ID Application** certificate with its
   private key. `security find-identity -v -p codesigning` should list it. The app
   uses bundle ID `com.hosseintoussi.agentchirp`. A Developer ID Installer
   certificate is not needed.
2. Fetch the pinned Sparkle tools and create an update key in your Keychain:

   ```sh
   python3 scripts/sparkle_tools.py
   .build/tools/sparkle-2.9.6/bin/generate_keys --account agentchirp
   ```

   Keep the private key backed up securely. The public key is safe to publish.
   Keep this key pair stable across releases. Do not paste private keys into chat
   or put them in this repository.
3. Create an Apple app-specific password and store notarization credentials
   interactively in your Keychain:

   ```sh
   xcrun notarytool store-credentials agentchirp-notary
   ```

   Supply your Apple ID, Team ID, and app-specific password when prompted. An
   existing notarytool profile works too; use its name in the release command.

## Build a signed release locally

Set `DEVELOPER_ID_APPLICATION` to the exact certificate identity. The public update
key is committed in `Packaging/Info.plist`; its private counterpart is saved in the
local Keychain under Sparkle account `agentchirp`. `SPARKLE_PUBLIC_KEY` is an optional
override for deliberate key changes or isolated tests.

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
python3 scripts/package_app.py
python3 Tests/Release/test_bundle.py dist/AgentChirp.app
python3 scripts/distribute.py --notary-profile agentchirp-notary --identity "$DEVELOPER_ID_APPLICATION"
python3 scripts/appcast.py dist/AgentChirp-X.Y.Z.zip
```

Replace X.Y.Z with `appVersion`. Create the packaging venv using the commands
above before building a DMG; dmgbuild arranges the app and Applications shortcut
without Finder automation. Notarization uploads the signed app and DMG to
Apple; it does not publish a GitHub release. The app must be stapled **before**
building the update ZIP. DMG notarization happens separately so the downloaded
disk image also has its own ticket. Gatekeeper assessment and stapler validation
must succeed before publishing. Signing is performed inside-out, without using
`codesign --deep` for signing (deep verification is appropriate).

The generated feed lives at the stable GitHub latest-release asset URL in
`Packaging/Info.plist`. Archive download URLs contain an immutable version tag.
The generator verifies the archive signature against the public key embedded in
the app, so mismatched public/private keys fail before publication. This first
feed offers full updates; it does not generate delta updates.

## GitHub Actions credentials

Add these in the repository's Settings → Secrets and variables → Actions:

| Type | Name | Value |
| --- | --- | --- |
| Secret | `DEVELOPER_ID_P12_BASE64` | Base64 of the exported certificate **and private key** in a password-protected `.p12` |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | Password protecting that `.p12` |
| Secret | `APPLE_ID` | Apple ID used for notarization |
| Secret | `APPLE_TEAM_ID` | Developer Program Team ID |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| Secret | `SPARKLE_PRIVATE_KEY` | Contents of a Sparkle private-key export for account `agentchirp` |
| Variable | `DEVELOPER_ID_APPLICATION` | Exact Developer ID Application certificate identity |

Export the Sparkle key to a temporary file with `generate_keys --account agentchirp
-x /secure/temporary/path`, set the secret through GitHub's UI or `gh secret set`
using stdin, then remove the export. Do not log or commit exported credentials.
CI uses a temporary keychain, restores the original default, and deletes
credentials in an `always()` cleanup step. The updater does not send system
profiling or session data to GitHub.

## Publish

1. Move the completed changes from `[Unreleased]` into a dated `[X.Y.Z]` section
   in `CHANGELOG.md` and bump `appVersion` in `Sources/AgentChirpCore/Version.swift`.
2. Commit, tag `vX.Y.Z`, and push main plus the tag when ready to publish.
3. CI must pass on that exact main-push commit. The release workflow checks out
   that successful SHA and requires the tag and app version to match.
4. The workflow builds and checks the app, notarizes/staples it, verifies the
   update signature, and publishes the assets. Missing credentials or a failed
   verification stop publication.

The README download button points to `releases/latest/download/AgentChirp.dmg`.
The GitHub repository is currently `hosseintoussi/ccbeacon`; the app and asset
names are AgentChirp. CI derives hosting URLs from `GITHUB_REPOSITORY`. Update the
local default feed URL and README links if the repository is renamed.
The download becomes available after the first signed app release. No source or binary has
to be hosted on a separate download server.

Before the first public release, also test a browser-downloaded DMG on a Mac that
has not run the development build: drag/open, first-run setup with both/no/one tool, automatic launcher installation, Open Codex, Codex hook review,
launch at login and disabling it, terminal focus/Automation consent, and an
actual Sparkle update from one signed version to the next. Local diagnostic
checks do not claim these system-level flows have been exercised.
