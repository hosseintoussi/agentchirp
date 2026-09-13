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
    TranscriptReader.swift Shared incremental JSONL transport: model name and Claude interrupt marker
    ConsoleSummary.swift Pure header presentation
    IntegrationInstaller.swift Shared atomic executable/hook installation with observable errors
    HookAdapter.swift Native Claude/Codex hook transport, locking and ancestry
    CodexTranscript.swift Codex model name from turn_context records
    AgentProcessSnapshot.swift Bounded process discovery, ancestry, Codex terminal clients
    Version.swift   appVersion constant + isDevBuild detection (path-based)
  agentchirp-hook/    Native hook executable (no AppKit, no Python runtime)
  agentchirp/         AppKit menu bar app
    AppDelegate.swift  NSStatusItem, popover, notifications, file watching
    Dashboard.swift    Native session console, grouped rows, buttons, BeaconMark, adaptive surfaces
    Snapshot.swift     --snapshot flag: renders fixture consoles to PNGs for design review
    Installation.swift First-run settings window, Applications placement and login items
    Updates.swift      Sparkle updater; disabled in development bundles
    AppIcon.swift      Installed icon rendered from BeaconMark
    main.swift         Entry point
Tests/
  AgentChirpCoreTests/  Framework-free test runner (no XCTest needed)
agentchirp.sh           Thin shell adapter calling the bundled native helper
Packaging/             Info.plist and Apple Events entitlement
scripts/               App bundle, signing, notarization, DMG and update-feed tooling
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

Rows are fixed at 64 points, with the path in tooltips. The whole row
opens the terminal when available; unsupported or undetected terminals have no row
action or action icon. Arrow keys navigate rows and Return activates them.
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
navigation. State changes rebuild grouped rows, while clock ticks update labels in place.

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
swift build -c release # builds the native helper used by hook tests
swift run AgentChirpTests
python3 Tests/Hooks/test_codex.py
python3 Tests/Hooks/test_claude.py
python3 Tests/Release/test_release.py
python3 Tests/CodexRuntime/test_runtime.py # requires release build
python3 Tests/CodexRuntime/test_launcher.py
bash -n agentchirp.sh
python3 scripts/package_app.py --development
python3 Tests/Release/test_bundle.py dist/AgentChirp.app
dist/AgentChirp.app/Contents/MacOS/agentchirp --installation-check /tmp/agentchirp-setup
```

No testing framework required — runs with Command Line Tools alone (no Xcode needed).
Tests cover: formatters (`fmtElapsed`, `stateClock`, `waitingSummary`, `consoleOrder`, `fmtBarTime`, `cleanModel`), `Session.priority`,
`Session.dirName`, `processStartTime`, `readTranscript` (incremental parsing, partial lines,
truncation, interrupt markers), `loadSessions` (state resolution, staleness, PID recycling,
interrupt resolution, sort order), and the native Claude hook adapter (question kinds, subagent calls).

## Hook script setup (required to see sessions)

Automatic: `syncIntegrations()` (`Sources/agentchirp/Setup.swift`) runs at every
launch for detected provider homes. It copies the bundled `agentchirp.sh` and native
`agentchirp-hook` to `~/.claude/hooks/` when contents differ. Release bundles resolve
resources from Contents/Resources and the helper from Contents/MacOS; source builds
resolve the script from the repo root and helper beside the executable. Setup
merges any missing hook entries into `~/.claude/settings.json` via
`mergedHookSettings()` in AgentChirpCore. Events that already contain a agentchirp entry
are never modified.

Claude events: SessionStart → idle, UserPromptSubmit → working, PermissionRequest and
Notification (permission_prompt, elicitation_dialog) → waiting, PreToolUse and PostToolUse
→ `resume`, Stop/StopFailure → done, SessionEnd removes the file. Claude Code runs
PreToolUse *before* the permission prompt and never again after approval, and it has no
approval-resolved hook; `resume` therefore ends a wait at the approved tool's PostToolUse
or at the next tool call, and the app's transcript-mtime check covers the gap. Because
both resume events fire for every tool call, the shell exits before launching the native
helper unless the session file currently says waiting; the writer rechecks under the lock
before resuming. PermissionRequest fires immediately, about six seconds before the
permission_prompt notification, and is the only event that identifies the request: the
helper stores a SHA-256 fingerprint of tool name and input (identical in PostToolUse) in
`pending_tools`, its generic kind in `pending_kinds` (`AskUserQuestion` → `input`, which a
later notification must not demote) and its owner in `pending_agents` (`agent_id`, empty for
the main thread). PostToolUse resumes only the matching request; PreToolUse resolves every
request owned by the calling agent, so a parallel sibling's completion or a subagent's tool
call never clears someone else's prompt. Records without fingerprints (notification-only
hook sets) resume on any main-thread step. Headless `claude -p` runs fire PermissionRequest
and then deny without a prompt, so they can show a brief wait. A repeated
state keeps its `ts`, so clocks measure time in the current state. Hooks persist
`last_event`; only Stop is successful completion. Startup, StopFailure, and Interrupt
never produce a completion sound or green tint. Escape fires no hook: `loadSessions`
resolves a working Claude session to idle (`last_event` Interrupt, clock from the marker)
when the transcript's `[Request interrupted by user…]` entry is newer than `updated_at`.
Hooks also persist `updated_at` for process liveness; never use the display clock
as the latest hook time. A changed owner discards the previous turn and pending requests.

The app owns integration setup and reports failures in its setup window. Starting a
development executable still updates the user's installed hooks; snapshot, UI,
icon-export and installation-check modes skip normal launch and never do setup.

## Codex integration

`syncIntegrations()` installs the same bundled script under `$CODEX_HOME/hooks`
and merges the Codex-specific hooks into `hooks.json`. Default home: `~/.codex`.
Never write hook trust or approval settings; the user reviews definitions in `/hooks`.
The bundled script takes `codex <state-directory>` for the Codex adapter, keeping
the shell entry point stable across updates. Hooks always return `{}` and never
make approval or continuation decisions.

`loadAllSessions()` combines Claude and Codex directories. Codex IDs are namespaced,
PID metadata uses `agent_pid`, and provider-specific transcript caches remain separate.
Codex waiting state is driven by hooks or live shared-server status, never transcript mtime. `Interrupt` suppresses
success sounds and the green completion tint. `CodexTranscript.swift` reads only the model
name from `turn_context` records. Its JSONL parser is best-effort because Codex
transcripts are not a stable API. Session state must not depend on that parser.

Python hook tests use temporary directories only. UI snapshots include mixed providers.
Do not claim live Codex hook delivery until the user has trusted the installed hooks.

`codex-chirp` delegates to the installed adapter's `launch-codex` mode, starts
Codex's local App Server daemon and uses `--remote unix://...`. Plain `codex` needs no wrapper: daemon-backed sessions use the same runtime monitoring,
while older standalone sessions retain hook tracking. `CodexRuntimeClient` polls loaded root threads with read-only
`thread/read` calls on the SessionStore queue. It never subscribes to threads or
responds to server requests. `CodexRuntimeOverlay` overrides matching hook state,
preserves metadata and clocks, and falls back to hooks on disconnection. Live
status permits delayed permission sounds; validation rechecks it before playback.
`AgentProcessSnapshot` reads local client processes on the store queue. Trim padded
`ps` command fields before matching bare executable names. Server-backed sessions
match terminal clients only when both client and thread are unique in their project;
bindings retain PID and start time. Cached idle threads disappear after that client
exits or no client remains in the project. Ambiguous matches have no terminal action,
failed process inspection preserves rows, and detached active work stays visible.
Known retired thread IDs persist in `retiredCodexThreads` UserDefaults and are excluded
before terminal matching. Explicit activity clears retirement; a complete runtime
listing prunes unloaded IDs. A failed read must not discard this history.
Completion identity uses the hook's completion time, independently of the runtime
state clock. Newly observed activity invalidates earlier success; a later Stop can
notify even when the runtime already reported idle. New hook waiting timestamps
restart the request clock and alert ticket even if consecutive polls both see waiting.
`--codex-status` is a read-only diagnostic that skips application setup.

## Native app installation and releases

See `RELEASING.md` for credential setup and exact local/CI commands. The single
prebuilt distribution is a universal Developer ID Application signed, notarized,
stapled `AgentChirp.app` inside `AgentChirp.dmg`. The same stapled app is zipped
and Ed25519 signed for Sparkle. No Homebrew packaging or migration is maintained.

`python3 scripts/package_app.py --development` builds a local preview bundle.
Production packaging requires `DEVELOPER_ID_APPLICATION`. The public Sparkle key
is in Packaging/Info.plist; its private counterpart lives in the agentchirp Keychain account.
The release workflow still waits for successful main-push CI, checks out that exact
SHA, and requires a matching version tag and appVersion before publishing.
Bump appVersion and add a dated changelog section before tagging a new release.
Never publish a development bundle or an unstapled archive as an official release.

The first-run window owns integration results/retry, explicit login opt-in via
`SMAppService.mainApp`, update preferences and a Done button. Codex setup automatically
installs the bundled launcher in ~/Library/Application Support/AgentChirp/bin.
Users start Codex from their terminal; setup does not edit shell profiles or PATH.
Only an explicit launch starts Codex's own server. Provider home changes are checked every 10 seconds;
missing tools show get-tool links and never create provider homes or block setup.
The console's bird opens Settings; Command-comma and Finder reopen do too. The
console retains its three captioned controls and live popover sizing contract.
Development bundles do not start Sparkle or register login items. `--installation-check`
uses injected actions and exercises real controls without touching user setup.

## Key implementation details

- **False notification prevention:** `flock(LOCK_EX)` in `HookAdapter.swift` serializes
  concurrent hook processes using 64 persistent SHA-256 bucket locks under `.locks`.
  Never unlink these locks. Both adapters share locking, atomic writes, and ancestry
  discovery; provider event handling remains separate. Cleanup acquires the same lock
  and compares the observed bytes before deleting, so a refreshed state survives.
  The app also debounces "waiting" state for 8 seconds and checks transcript mtime
  before playing a sound. Alert tickets remain cancellable through asynchronous validation.
  Codex question answers correlate by `tool_use_id`; permission requests have no
  approval-resolved event, so standalone permission signals are visual-only and keep-awake stays held
  through the pending interval until the turn becomes idle or ends.
  Each pending Codex request retains its generic kind so resolving one request
  recomputes the remaining input/permission state. Untyped legacy requests stay visual-only.

- **Atomic state files:** the hook writes to `<session>.json.tmp` and `os.replace()`s it —
  the app reads without the lock, so the rename guarantees it never sees a half-written
  file. The rename also fires the directory watcher, giving instant menu bar updates.

- **SessionEnd deletes the state file** (detected via `hook_event_name` on stdin, so all
  hook events can pass the same-looking args). A quit session vanishes instead of passing
  through "done", which would chime "finished" for a session the user killed.

- **PID recycling:** a session is alive only if `kill(pid, 0)` succeeds *and* the process
  start time (via `sysctl KERN_PROC_PID`) predates `updated_at` (legacy files fall back
  to `ts`). Waiting sessions with live owners do not expire; the four-hour timeout is
  only a fallback for missing owner PIDs. Claude
  always starts before its first hook fires, so a later start time means the PID was reused.

- **Incremental transcript parsing:** `TranscriptReader` caches a byte offset per transcript and
  parses only appended complete lines, keeping just the model name and the latest Claude
  interrupt marker (Claude Code writes one line per content block, so nothing is summed).
  Never re-read whole transcripts on the update tick — they can be tens of MB. `SessionStore` coalesces refreshes on a serial background queue
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
