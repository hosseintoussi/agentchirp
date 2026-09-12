# ccbeacon

A macOS menu bar app that tells you when your Claude Code and Codex agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What it does

ccbeacon sits in your menu bar and watches your active Claude Code and Codex sessions. You see exactly what's happening across every session, from any app, at a glance.

| State | Menu bar |
|-------|----------|
| No active sessions | Beacon mark |
| Sessions working | Slowly blinking beacon |
| Needs your input | Flashing amber beacon |
| Just finished | Green beacon for 10 seconds |

The icon keeps a fixed width in every state; hover for status and session counts.
Click the icon to open the session console. **Needs input / Working / Idle** tabs
show each state and its count once. Opening the console selects Needs input first,
then Working, then Idle. Sessions waiting longest appear first.

Each two-line row identifies the project and provider and shows elapsed time. Click
anywhere on the row to open its terminal; hover for the full path and token usage. Projects
with the same folder name show their parent folder to help distinguish them.

Live updates move sessions into the correct tab without switching your selection
or resizing the open popover. Rows have a fixed height and each tab remembers its
scroll position. Close and reopen to jump to the highest-priority state.

Terminal jumps support iTerm2 and Terminal.app. Unsupported terminals offer Copy path.
Arrow keys navigate session rows and Return opens the selected session;
Escape dismisses the popover. Sound preferences persist between launches. Quit lives
in the header settings menu.

The console follows your Mac's light or dark appearance. The neutral beacon blinks
slowly while working; amber flashes faster when input is needed. Reduce Motion
keeps both states steady.

---

## Install

### Homebrew (recommended)

```sh
brew tap hosseintoussi/ccbeacon
brew install ccbeacon
brew services start ccbeacon   # starts now and at every login
```

Installs a prebuilt universal binary — no compile step. On first launch ccbeacon
installs its hook script and merges the hook entries into `~/.claude/settings.json`
automatically, and keeps them up to date after every upgrade.

### Update

```sh
brew update && brew upgrade ccbeacon
brew services restart ccbeacon
```

### Build from source

Requires macOS 13+ and Swift (via Xcode or Command Line Tools).

```sh
git clone https://github.com/hosseintoussi/ccbeacon.git
cd ccbeacon
swift build -c release
.build/release/ccbeacon &
```

The app configures its Claude Code hooks automatically on first launch (see [Hook setup](#hook-setup)).

---

## Launch at login

**Homebrew install:** `brew services start ccbeacon` — Homebrew manages the LaunchAgent.

**Built from source:** add a LaunchAgent manually:

```sh
cat > ~/Library/LaunchAgents/com.hosseintoussi.ccbeacon.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hosseintoussi.ccbeacon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/.build/release/ccbeacon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hosseintoussi.ccbeacon.plist
```

---

## Hook setup

Automatic for every install method: at launch, ccbeacon installs (and keeps updated)
`~/.claude/hooks/ccbeacon.sh` and adds any missing hook entries to
`~/.claude/settings.json`. Existing entries are never modified — if you've customized
an event's ccbeacon hook, your version wins.

---

## Codex support

Codex sessions appear alongside Claude sessions, with a provider label, model, usage,
and the same compact menu bar states. Tested against Codex CLI 0.154.0.

When a Codex home exists, ccbeacon installs its adapter at
`~/.codex/hooks/ccbeacon.sh` and adds missing entries to `~/.codex/hooks.json`.
It preserves existing hooks and does not change `config.toml`, approval policy,
or hook trust. A custom `CODEX_HOME` is supported when ccbeacon is launched with
that environment variable.

**To activate:** restart Codex if needed, open `/hooks`, and review/trust the
ccbeacon entries. Then start or resume a session. Codex skips untrusted hooks;
installing ccbeacon alone does not approve them.

The adapter observes session start/end, prompts, tool calls, permission requests,
completion, and interruption. Supported input-question tool calls also appear as
waiting. Completion plays the normal cue; interruption does not announce success.
Approval state clears when the matching tool finishes or the turn stops. Other
parallel tool completions do not clear outstanding approvals.

Terminal jumps are available when a local iTerm2 or Terminal.app ancestor and TTY
can be identified. A session without that information remains visible without a
jump action. This integration does not attach to remote Codex servers or import
historical sessions. Codex may keep a detached session open for up to 30 minutes
before emitting SessionEnd.

Usage is a best-effort adapter for local Codex JSONL transcripts. It reads only
appended complete records and uses cumulative totals, splitting cached input out
of the IN column so tokens are not counted twice. Missing or changed transcript
formats do not affect hook-based lifecycle tracking.

See [Codex hook documentation](https://learn.chatgpt.com/docs/hooks) for the
supported events and required trust review.

---

## How it works

The shared hook script (`ccbeacon.sh`) uses separate Claude and Codex adapters.
Claude Code calls it on these events:

| Hook | Matcher | State written |
|------|---------|--------------|
| `SessionStart` | — | `idle` |
| `UserPromptSubmit` | — | `working` |
| `Notification` | `permission_prompt` | `waiting` |
| `Notification` | `elicitation_dialog` | `waiting` |
| `Stop` | — | `done` |
| `StopFailure` | — | `done` |
| `SessionEnd` | — | session file removed |

Each call atomically writes a small JSON file to `~/.claude/cc-sessions/` including the session's PID, TTY device, and terminal app. ccbeacon watches that directory with `DispatchSource` so state changes appear instantly, plus a 1-second refresh for elapsed times and staleness checks.

Sessions are kept alive as long as their Claude process is running (verified via `kill(pid, 0)` plus a process start-time check that guards against PID reuse). When the session ends — whether from a normal close or the process exiting — it disappears from the menu immediately.

Two `Notification` matchers trigger the amber "needs input" state: `permission_prompt` (tool approval dialogs) and `elicitation_dialog` (option/question UI rendered by Claude). Other notification types are ignored.

A `flock`-based exclusive lock in the hook script prevents a race condition where a `Notification` hook firing mid-run could overwrite a `Stop` hook running at the same moment.

---

## Security

Everything runs locally. The hook script reads session metadata from Claude Code's hook stdin and writes state to `~/.claude/cc-sessions/`. The Codex adapter writes state under `$CODEX_HOME/ccbeacon/sessions` (default `~/.codex`).
Both adapters retain session metadata, not prompt or tool content. The app reads
per-session token counts from your local transcript files. No data leaves your machine.
