# ccbeacon

A macOS menu bar app that tells you when your Claude Code agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What it does

ccbeacon sits in your menu bar and watches all your active Claude Code sessions. You see exactly what's happening across every session, from any app, at a glance.

| State | Menu bar |
|-------|----------|
| No active sessions | Beacon mark |
| Sessions working | Dotted activity circle |
| Needs your input | Amber exclamation circle |
| Just finished | Checkmark for 10 seconds |

The icon keeps a fixed width in every state; hover for status and session counts.
Click the icon to open the session console. An attention summary leads into groups for
sessions that need input, are working, or are idle. Each session shows its project,
path, model, elapsed time, and input/output/cache token counts.

Use **Open terminal** to jump to the matching pane in iTerm2 or Terminal.app. Other
terminals remain visible without an unsupported jump action. Native buttons support
keyboard navigation; Escape dismisses the popover. The session list scrolls while the
summary and sound controls stay in place. Sound preferences persist between launches.

The console follows your Mac's light or dark appearance and uses a static beacon
signal without continuous animation.

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

## How it works

The hook script (`ccbeacon.sh`) is called by Claude Code on these events:

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

Everything runs locally. The hook script reads session metadata from Claude Code's hook stdin and writes state to `~/.claude/cc-sessions/`. The app reads per-session token counts from your local transcript files. No data leaves your machine.
