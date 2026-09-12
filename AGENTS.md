# AgentChirp — developer guide

The product is AgentChirp. Its native bird silhouette and two rounded beam arcs
share one vector implementation for the menu bar and dashboard.

## Project layout

```
Sources/
  AgentChirpCore/     Pure logic — models, formatters, session loading. No AppKit.
    Core.swift      Session model, formatters, process liveness
    SessionPolicy.swift Typed state/event/outcome, notifications, beacon and row descriptors
    SessionRepository.swift Session loading, synchronized cleanup, background SessionStore
    TranscriptReader.swift Shared incremental JSONL transport with owned provider caches
    ConsoleSummary.swift Pure header presentation
    IntegrationInstaller.swift Shared hook installation with observable errors
    CodexTokens.swift Incremental Codex cumulative token adapter
    Version.swift   appVersion constant + isDevBuild detection (path-based)
  agentchirp/         AppKit menu bar app
    AppDelegate.swift  NSStatusItem, popover, notifications, file watching
    Dashboard.swift    Native session console, grouped rows, buttons, BeaconMark, adaptive surfaces
    Snapshot.swift     --snapshot flag: renders fixture consoles to PNGs for design review
    main.swift         Entry point
Tests/
  AgentChirpCoreTests/  Framework-free test runner (no XCTest needed)
agentchirp.sh           Claude/Codex hook adapters — writes provider-specific state files
```

AppKit code lives only in `Sources/agentchirp/`. Everything testable goes in `AgentChirpCore`.

## Build and run

```sh
swift build -c release
.build/release/agentchirp &
```

The menu bar button keeps the same beacon at a fixed square width with no text.
Resting and working share one neutral template image so macOS handles light/dark
contrast; the mark never changes shape. Working breathes by toggling the button's
alpha between 1 and 0.75 every 1.4 seconds (`updateWorkingBreath`), which costs no
redraw; idle is steady. A session that newly asks for input starts a finite flash
(`AppDelegate.flashCycles` × `flashPeriod`, about two seconds) and then holds a
steady `systemOrange`; there is no continuous pulse and no working blink. A fresh
completion shows `systemGreen` for 10 seconds. Reduce Motion skips the flash.
`updateButton` only regenerates the artwork when its descriptor changes.

The console has no tabs. `ConsoleSummary` builds the header headline and subline
from counts; `consoleOrder` (AgentChirpCore) sorts waiting (oldest first), then
working (oldest first), then idle (newest first). Waiting rows show
`waitingSummary(session.detail)`: only "Needs permission", "Waiting for your answer",
or "Waiting for you". Hooks persist generic permission/input kinds, never raw commands
or notification messages. Legacy details are sanitized before display. Live refreshes never resize
the open window. The viewport is calculated once per opening from the row count,
capped at 456 points of list (512 total). The next opening can resize.

**Popover sizing contract:** all real openings go through `DashboardController.show`,
which synchronizes `NSPopover.contentSize` before showing. AppKit caches this separately
from the controller view size across closes; changing only the view leaves stale window
chrome. Never set the root frame or preferred content size during a live refresh.
`DashboardSurface` keeps permanent header, scroll, clip, and document views;
its layout derives from actual bounds. Update document contents without detaching the
scroll hierarchy. Clamp restored offsets to both ends after focus restoration.
The native CI checks exercise deferred layout, animated large/small/empty reopen cycles,
focused-row removal, scroll restoration, and constrained content bounds.

Rows are fixed at 64 points, with path and token usage in tooltips. The whole row
opens the terminal (or copies the path for unsupported terminals and shows "Copied"
in the clock for 1.5 seconds). Arrow keys navigate rows and Return activates them.
There are no expandable rows. Same-name projects show `parent/name`. The header's
top right holds three captioned icon buttons (`HeaderIconButton`, image above a
9-point caption): Awake/May sleep, Sounds/Muted, Quit (the version is the quit
tooltip); there is no menu and no footer.

**Keep awake:** `updateSleepAssertion(working:)` in AppDelegate holds IOKit
`PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` assertions while any session is working or a Codex session is waiting, and `keepAwake`
(UserDefaults, default true) is on; it releases immediately otherwise. The
dashboard mirrors the preference through `keepAwake` / `onKeepAwake`.
See DESIGN.md for product intent and the responsibilities of each UI element.

Clicking opens a transient NSPopover with DashboardController. Native buttons support keyboard
navigation. State changes rebuild grouped rows, while clock/token ticks update labels in place.

To review the full console in light and dark appearances without installing hooks:

```sh
.build/release/agentchirp --snapshot /tmp
.build/release/agentchirp --ui-check
```

These commands render mixed, asks, finished, empty, working, idle, and overflow
fixtures plus the real popover, and exercise native controls, live transitions,
usage updates, the finite flash, and scrolling. Neither mode will
run the normal application launch or modify Claude settings.

## Test

```sh
swift run AgentChirpTests
python3 Tests/Hooks/test_codex.py
python3 Tests/Hooks/test_claude.py
python3 Tests/Release/test_release.py
python3 Tests/CodexRuntime/test_runtime.py # requires release build
python3 Tests/CodexRuntime/test_launcher.py
bash -n agentchirp.sh
```

No testing framework required — runs with Command Line Tools alone (no Xcode needed).
Tests cover: formatters (`fmtElapsed`, `stateClock`, `waitingSummary`, `consoleOrder`, `fmtBarTime`, `fmtK`, `cleanModel`), `Session.priority`,
`Session.dirName`, `processStartTime`, `readTokens` (incremental parsing, partial lines,
truncation), and `loadSessions` (state resolution, staleness, PID recycling, sort order).

## Hook script setup (required to see sessions)

Automatic: `syncClaudeIntegration()` (`Sources/agentchirp/Setup.swift`) runs at every
launch. It copies the bundled `agentchirp.sh` to `~/.claude/hooks/` when contents differ
(dev builds resolve it from the repo root, Homebrew builds from the keg's `libexec`)
and merges any missing hook entries into `~/.claude/settings.json` via
`mergedHookSettings()` in AgentChirpCore. Events that already contain a agentchirp entry
are never modified.

Claude events: SessionStart → idle, UserPromptSubmit → working, PreToolUse → `resume`,
Notification (permission_prompt, elicitation_dialog) → waiting, Stop/StopFailure → done,
SessionEnd removes the file. `resume` is how a granted permission becomes "working"
immediately: PreToolUse fires when the approved tool starts. Because it also fires
for every other tool call, the shell exits before Python unless the session file
currently says waiting; the writer rechecks under the lock before resuming. A repeated
state keeps its `ts`, so clocks measure time in the current state. Hooks persist
`last_event`; only Stop is successful completion. Startup, StopFailure, and Interrupt
never produce a completion sound or green tint.

This lives in the app — NOT in the Homebrew formula — because `post_install` runs in
Homebrew's sandbox with a fake `$HOME` and cannot write the user's real `~/.claude`.
Note: launching a dev build overwrites the user-installed hook with the repo version.

## Codex integration

`syncCodexIntegration()` installs the same bundled script under `$CODEX_HOME/hooks`
and merges the Codex-specific hooks into `hooks.json`. Default home: `~/.codex`.
Never write hook trust or approval settings; the user reviews definitions in `/hooks`.
The bundled script takes `codex <state-directory>` for the Codex adapter, keeping
existing release/Homebrew packaging intact. Hooks always return `{}` and never
make approval or continuation decisions.

`loadAllSessions()` combines Claude and Codex directories. Codex IDs are namespaced,
PID metadata uses `agent_pid`, and provider-specific transcript caches remain separate.
Codex waiting state is driven by hooks or live shared-server status, never transcript mtime. `Interrupt` suppresses
success sounds and the green completion tint. `CodexTokens.swift` treats token counts as cumulative
and cached input as a subset of input. Its JSONL parser is best-effort because Codex
transcripts are not a stable API. Session state must not depend on that parser.

Python hook tests use temporary directories only. UI snapshots include mixed providers.
Do not claim live Codex hook delivery until the user has trusted the installed hooks.

`codex-chirp` delegates to the installed adapter's `launch-codex` mode, starts
Codex's local App Server daemon and uses `--remote unix://...`. Ordinary `codex`
is unchanged. `CodexRuntimeClient` polls loaded root threads with read-only
`thread/read` calls on the SessionStore queue. It never subscribes to threads or
responds to server requests. `CodexRuntimeOverlay` overrides matching hook state,
preserves metadata and clocks, and falls back to hooks on disconnection. Live
status permits delayed permission sounds; validation rechecks it before playback.
`--codex-status` is a read-only diagnostic that skips application setup.

## Releasing a new version

1. Add a `## [X.Y.Z] - YYYY-MM-DD` section at the top of `CHANGELOG.md`
2. Bump `appVersion` in `Sources/AgentChirpCore/Version.swift`
3. Commit and tag:
   ```sh
   git commit -am "Bump to vX.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The release workflow (`.github/workflows/release.yml`) is triggered automatically once CI
passes on the pushed commit. It will:
- Check out the exact successful upstream main-push CI SHA, detect its version tag,
  and verify that the tag and appVersion match the checkout
- Extract the matching `## [X.Y.Z]` section from `CHANGELOG.md` as the release body
- Build a universal (arm64 + x86_64) binary and attach `agentchirp-vX.Y.Z-macos.tar.gz`
  (binary + hook script) to the GitHub release
- Point the Homebrew tap formula at the binary asset and update its SHA256

**If CI fails, the release will not run.**


## Homebrew tap

The tap lives at `github.com/hosseintoussi/homebrew-agentchirp`.
Formula: `Formula/agentchirp.rb` — install command: `brew tap hosseintoussi/agentchirp && brew install agentchirp`.

To manually update the formula after a release (if the workflow didn't run):
```sh
cd /path/to/homebrew-agentchirp
# update url and sha256 in Formula/agentchirp.rb
git commit -am "agentchirp vX.Y.Z"
git push
```

## Key implementation details

- **False notification prevention:** `fcntl.flock(LOCK_EX)` in `agentchirp.sh` serializes
  concurrent hook processes using 64 persistent SHA-256 bucket locks under `.locks`.
  Never unlink these locks. Both adapters share locking, atomic writes, and ancestry
  discovery; provider event handling remains separate. Cleanup acquires the same lock
  and compares the observed bytes before deleting, so a refreshed state survives.
  The app also debounces "waiting" state for 8 seconds and checks transcript mtime
  before playing a sound. Alert tickets remain cancellable through asynchronous validation.
  Codex question answers correlate by `tool_use_id`; permission requests have no
  approval-resolved event, so standalone permission signals are visual-only and keep-awake stays held
  through the pending interval until the turn becomes idle or ends.

- **Atomic state files:** the hook writes to `<session>.json.tmp` and `os.replace()`s it —
  the app reads without the lock, so the rename guarantees it never sees a half-written
  file. The rename also fires the directory watcher, giving instant menu bar updates.

- **SessionEnd deletes the state file** (detected via `hook_event_name` on stdin, so all
  hook events can pass the same-looking args). A quit session vanishes instead of passing
  through "done", which would chime "finished" for a session the user killed.

- **PID recycling:** a session is alive only if `kill(pid, 0)` succeeds *and* the process
  start time (via `sysctl KERN_PROC_PID`) predates the session's last hook event. Claude
  always starts before its first hook fires, so a later start time means the PID was reused.

- **Incremental transcript parsing:** `readTokens` caches a byte offset per transcript and
  parses only appended complete lines. Never re-read whole transcripts on the update tick —
  they can be tens of MB. `SessionStore` coalesces refreshes on a serial background queue
  and publishes snapshots to the main queue. UI actions consume that snapshot. Each
  repository owns its caches; inode changes, shrinkage, and equal-size rewrites reset
  parsing, and failed reads leave metadata uncommitted so the next refresh retries.

- **Menu bar text color:** use dynamic system colors (`NSColor.labelColor`) for the status
  button text so it adapts to light and dark menu bars. Never hardcode white or snapshot a
  dynamic color's `cgColor` for text — it becomes invisible on a light menu bar.

- **Update timer runs in `.common` run-loop mode** — in `.default` mode timers stop firing
  during interaction.

- **Version display:** the app version is the quit button's tooltip. The header
  shows state, never branding, and there is no visible development badge.
