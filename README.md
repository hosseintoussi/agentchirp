# ccbeacon

A macOS menu bar app that tells you when your Claude Code and Codex agents need attention — without you having to go look.

## The problem

You fire off a Claude Code agent, then switch to another app to keep working. Maybe you open a browser, write docs, review something else. Claude is running in the background.

But you have no idea when it finishes. Or when it hits a decision point and is waiting for your input. You either miss it for too long, or you keep tabbing back to check — which defeats the point of running it in the background.

## What it does

ccbeacon sits in your menu bar and watches your active Claude Code and Codex sessions. You see exactly what's happening across every session, from any app, at a glance.

| State | Menu bar |
|-------|----------|
| No active sessions | Neutral beacon, steady |
| Sessions working | Neutral beacon breathing slowly |
| Needs your input | Three short orange flashes, then steady orange |
| Just finished | Green beacon for 10 seconds |

The icon keeps a fixed width in every state and never animates continuously; hover
for counts. Click it to open the console. The header answers the question in one
line ("2 need input", "3 working", "All quiet") with the beacon lit to match.

Below is one list: sessions that need input first (longest waiting at the top), then
working (longest running first), then idle. Each row shows a state dot, the project,
a clock that says what the time means ("waiting 2m", "working 35m"), and on the second
line the provider and, when the agent is waiting, what it is asking for ("Needs
permission", "Waiting for your answer"). Projects with the same folder name
show their parent folder.

Click anywhere on a row to open its terminal; hover for the full path and token usage.
Terminal jumps support iTerm2 and Terminal.app; other terminals copy the project path
and the row says "Copied". Arrow keys move between rows, Return opens the selected
session, Escape dismisses the popover. Live updates reorder the list in place without
resizing the open popover.

While any session is working, ccbeacon keeps your Mac from going to sleep (the
display stays on). Three captioned buttons sit at the top right: Awake turns
that off (it then reads May sleep), Sounds toggles sounds, Quit quits (hover it for
the version).
The console follows your Mac's light or dark appearance and Increase Contrast, and
Reduce Motion removes the flash.

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

For automatic clearing of amber as soon as an answer or approval is accepted,
start new sessions with the optional `codex-beacon` launcher:

```sh
# Install the launcher from the repository or extracted release:
install -m 755 codex-beacon ~/.local/bin/codex-beacon
# Start ccbeacon once, then:
codex-beacon
# Or resume an existing conversation through the shared server:
codex-beacon resume --last
```

Ensure `~/.local/bin` is on your PATH. The launcher starts Codex's local shared
App Server automatically and connects the terminal to it. ccbeacon reads live
thread status about once per second, clears amber when work resumes, and checks
that a request remains unanswered before playing its delayed sound. It never
answers approvals or questions. Ordinary `codex` and already-running standalone
sessions continue using hooks. This optional integration uses the experimental
App Server interface in Codex CLI 0.154.0.

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
For standalone sessions, approval state clears when the matching tool finishes or the turn stops; permission prompts are visual-only because hooks cannot confirm when approval was granted. Other
parallel tool completions do not clear outstanding approvals.

Terminal jumps are available when a local iTerm2 or Terminal.app ancestor and TTY
can be identified. A session without that information remains visible; clicking its row copies the path. This integration does not attach to remote Codex servers or import
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
