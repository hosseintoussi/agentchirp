# Changelog

## [Unreleased]

### Native installation
- Missing agents no longer require manual setup: installation links and automatic detection handle either tool arriving later without blocking AgentChirp
- Added a Developer ID signed app bundle, Apple notarization and stapling, and a drag-to-Applications DMG release pipeline; removed the Homebrew release path
- Added a first-run setup window with integration results, retry, launch at login, automatic Codex launcher setup and an Open Codex action, and built-in Sparkle updates
- Replaced the Python hook runtime with a bundled Swift helper, preserving session state, privacy, atomic writes, and shared bucket locks
- Added signed update archive verification, clean-home bundle checks, and native setup interaction/layout checks

### AgentChirp
- Renamed the app and executable to AgentChirp / `agentchirp`, with a native bird-and-beam mark
- Added `codex-chirp`; renamed the hooks, modules, session directories, and release artifacts consistently

### Added
- Keep awake: while any session is working the app holds system and display sleep assertions to keep the screen on. An Awake button in the header turns it off; the preference persists

### Changed — signal-first console
- The menu bar beacon is calm: a new request flashes three times and then holds steady orange; working breathes slowly (opacity only) and idle is steady. The continuous 30 fps attention pulse is gone. A completion shows green even while other sessions work
- The console header now answers the question ("2 need input", "3 working", "All quiet", "Nothing running") beside a beacon lit by the top state; the top right holds captioned Awake, Sounds, and Quit buttons (version on the quit tooltip) instead of a menu
- Tabs are gone. One list orders sessions by what needs you: waiting (longest first), working (longest running first), idle (newest first). Rows carry a state dot and a verb clock ("waiting 2m", "idle 2h 1m")
- Waiting rows show only "Needs permission" or "Waiting for your answer"; hooks store generic waiting kinds instead of commands or notification text
- One orange everywhere: the light-mode attention color is derived from system orange instead of a hardcoded brown; the console root is clear so the popover material shows through; fills double under Increase Contrast; row glyphs use secondary label color
- Copying a path for an unsupported terminal now says "Copied" in the row; tooltips name the terminal that can't be focused
- The needs-input sound is Ping instead of Sosumi
- Same-name projects show `parent/name`; VoiceOver labels include state, time, and the ask; keyboard focus draws the system focus ring
- Header shrank from 92 to 56 points and the footer was removed; the popover fits its content
- Granting a permission now flips the session back to working immediately: a `PreToolUse` hook (`agentchirp.sh resume`) is installed for Claude Code and only writes when the session was waiting. Previously the app waited for the transcript to change, which could take as long as the approved tool ran
- `fmtElapsed` spaces units ("2h 1m") and adds days


### Fixed
- Completion cues retain the successful hook's identity and time: stale successes cannot finish later Codex turns, and a Stop arriving after runtime idle still sounds once
- Successive Codex questions between polls receive separate clocks, sound timers, and attention flashes
- Closed Codex threads no longer block new terminal bindings or reappear after restarting AgentChirp
- Resumed sessions use fresh process ownership independently of their display clocks; live waiting sessions no longer expire after four hours
- Mixed Codex questions and permission requests keep the correct remaining waiting kind and sound eligibility
- Codex waiting sessions retain keep-awake through long approved commands; idle and ended sessions release it
- Answered questions cancel pending sounds even during asynchronous validation; tool-call IDs correlate Codex answers
- Standalone Codex permission prompts use visual signals only because hooks do not report approval resolution separately
- Optional `codex-chirp` launcher and read-only shared-server monitoring clear amber when Codex resumes, with live validation of delayed alerts
- Release builds check out the exact successful CI commit and verify its tag against appVersion
- Stale cleanup shares persistent locks with hook writers and preserves concurrently refreshed state
- Claude startup and failed turns no longer show successful completion; hooks retain lifecycle outcomes
- Transcript replacement resets token totals, and failed reads retry without requiring another file change
- Clearing waiting state correctly changes an overlapping completion beacon from orange to green
- Each row completion dot expires independently; header text stays clear of its controls

### Refactored
- Session loading and transcript parsing run on a serial background store; UI actions reuse published snapshots
- Shared transcript transport, hook installation, locking, atomic writes, and process discovery replace duplicated infrastructure
- Typed lifecycle, notification, and presentation policies live in AgentChirpCore with regression coverage

## [2.1.3] - 2026-07-02

### Changed
- The open dropdown now updates fully in place: rows swap their view when a session changes state, disappear when a session ends, appear for new sessions, and the header count stays current — previously only elapsed times ticked and state changes waited for reopen
- Idle dot uses opaque `systemGray` — it was ~25%-alpha `tertiaryLabelColor`, so its visibility varied with whatever was on screen behind the translucent menu
- Mute item icon shows the current sound state instead of the post-click state

### Removed
- "IDLE" section label — the gray dot, flat card, and "idle" text already mark idle sessions

## [2.1.2] - 2026-07-02

(v2.1.1 was tagged but its release build failed; these are its notes, released as v2.1.2.)

### Added
- The app now installs and updates its own Claude Code integration at launch: copies the bundled hook script to `~/.claude/hooks/` when it differs and merges missing hook entries into `~/.claude/settings.json` (existing entries are never touched). Homebrew's `post_install` ran in a sandbox with a fake `$HOME`, so the formula's automatic setup silently never worked — this replaces it
- Releases ship a prebuilt universal (arm64 + x86_64) binary; `brew install` no longer compiles from source

### Changed
- Dropdown elapsed times update live while the menu is open
- Hook script latency roughly halved: session PID/tty/terminal are reused from the previous state file while the PID is alive, and the process-tree walk (first event only) takes one `ps` snapshot instead of up to 12 sequential calls
- Login launch moved to `brew services start agentchirp` (formula `service` block) instead of a hand-written LaunchAgent

### Fixed
- Terminal.app detection in the hook — `ps` reports a full executable path, so the old exact-name match never detected it

## [2.1.0] - 2026-07-02

### Changed — dropdown redesign
- Session rows are now rounded cards with gaps between them instead of full-bleed rows — sessions no longer blur together
- Readable text hierarchy: path is `secondaryLabelColor` (was tertiary), model moved to the right of the path line, token counts stay as fine print
- Only the waiting state gets a color wash (amber); working cards are neutral with an accent-colored spinner, idle rows are flat with an "Idle" section label — one loud state instead of three
- Clickable rows highlight on hover and swap the elapsed time for "open ↗" — the always-visible `↗` icon no longer hides the elapsed time
- Working spinner uses the system accent color; elapsed times use monospaced digits; paths truncate in the middle so the leaf directory stays visible
- All card/dot colors resolve at draw time, adapting to light/dark menus (previously `cgColor` snapshots)
- Cursor handling uses `cursorUpdate` instead of unbalanced push/pop

### Added
- `agentchirp --snapshot [dir]` renders the dropdown with fixture sessions to `menu-dark.png` / `menu-light.png` for design review

### Fixed
- Hook script now writes session files atomically (temp file + rename) — the app can no longer read a half-written file, which caused sessions to flicker out of the menu and re-trigger "needs input" sounds
- Update timer moved to the `.common` run-loop mode — the menu bar spinner and elapsed times no longer freeze while the dropdown is open
- Transcript token counts are now parsed incrementally (only appended lines) instead of re-reading the whole transcript every second — large sessions no longer burn CPU on the main thread
- Menu bar text uses dynamic `labelColor` so it stays readable on light menu bars (was hardcoded white)
- Session rows keep a stable order across refreshes (priority, then newest first) — equal-priority rows no longer shuffle randomly
- Quitting a Claude session no longer plays the "finished" chime — `SessionEnd` removes the session file instead of writing `done`
- `SessionEnd` also resets the iTerm2 tab color (tabs no longer stay green forever)
- Clicking a session row no longer guesses iTerm2 when the session's terminal is unknown; rows are only clickable for supported terminals (iTerm2, Terminal.app), and the tty is validated before being passed to AppleScript
- Stale PID detection now also checks the process start time via `sysctl`, so a recycled PID can't keep a dead session alive
- `.lock` files in `~/.claude/agentchirp/sessions/` are cleaned up instead of accumulating forever
- Hook script values are passed to Python via the environment instead of shell interpolation (robust against quotes in paths)

### Changed
- Mute setting persists across restarts
- Session model shows the most recently used model instead of the first one
- `osxNotify` renamed to `playSound` — the menu bar icon is the visual notification; sounds are the audio cue

### Removed
- Dead code: `DoneCircleView`, `fmtClock`, unused `Session.cost` field

## [2.0.8] - 2026-06-30

### Changed
- Menu bar elapsed time format changed from `mm:ss` to `Xs` / `Xm` / `Xh` / `Xd` for better readability on long-running sessions

## [2.0.7] - 2026-06-30

### Changed
- Menu bar icon changed from `✦` to `>_` across all states (idle, done, waiting)
- Session rows now show a blue left stripe and tint for running sessions (was only shown for waiting)
- Running sessions use a blue spinner instead of secondary-label color
- "Open" pill replaced with a compact `↗` icon for TTY-linked rows
- Token usage row uses `tertiaryLabelColor` instead of `quaternaryLabelColor` for better readability
- Menu header shrunk to 44px with vertically centered title

### Added
- Empty state row "No active sessions" shown when no session files are present

### Removed
- Daily activity stats row and `DailyStats` / `loadDailyStats` — simplifies the menu

## [2.0.6] - 2026-06-27

### Changed
- Activity row redesigned: "Activity" header above a stats line (`N sessions · N msgs · N tools`), no date prefix — always shows the most recent day's data
- Consistent vertical spacing throughout the menu — session rows use uniform 4px gaps between all four lines; header and activity row balanced to match
- `fmtFull` pinned to `en_US` locale so number formatting is consistent regardless of system locale

### Added
- Tests for `fmtFull` and `dailyLabel` (48 total)

## [2.0.5] - 2026-06-27

### Fixed
- Daily stats row now always shows the most recent available entry instead of hiding when today has no data yet — labeled "Today", "Yesterday", or the date

## [2.0.4] - 2026-06-27

### Added
- `StopFailure` hook — sessions are marked done immediately when Claude hits an API error or crashes, rather than waiting for PID timeout
- `SessionEnd` hook — accelerates cleanup when a session exits cleanly, combined with PID liveness for reliability

## [2.0.3] - 2026-06-27

### Changed
- Daily stats row now reads from Claude Code's own `~/.claude/stats-cache.json` and shows sessions, messages, and tool calls for today — no more homegrown token accounting
- Removed token-counting transcript parsing from the Stop hook; hook script is significantly simpler

### Fixed
- Sessions no longer disappear after 2 hours of being idle — sessions persist as long as their Claude process is running, regardless of idle time
- Added `elicitation_dialog` as a second `Notification` hook matcher so Claude's option/question UI (AskUserQuestion) correctly triggers the "needs input" state

## [2.0.2] - 2026-06-26

### Fixed
- Removed false "needs input" notifications triggered by any response ending with `?` — `waiting` state now only fires from Claude Code's structured notification events
- Removed unused `asking` state and its purple UI (tint, stripe, `?` icon, "has question" notification)

## [2.0.1] - 2026-06-26

### Fixed
- Session rows now show model, path, and token stats on separate lines — no more truncation
- Daily stats row stacks token counts below the session count so the full string is visible

## [2.0.0] - 2026-06-26

### Added
- **Terminal deep-link:** click any session row to jump directly to that terminal pane — works with iTerm2 and Terminal.app via AppleScript
- **Pill-style "open" button** replaces elapsed time in session rows when a TTY is detected; hand cursor on hover signals it's clickable
- **SessionStart hook** — fresh sessions appear immediately without needing to type first
- **PID-based liveness detection** — sessions disappear instantly when their Claude process exits, no more stale entries lingering for minutes
- **`idle` state** — sessions in `done` state with a live process are resolved to `idle` and stay visible; removed the moment the process exits
- **Multi-session taskbar** — two or more active sessions shows "N sessions" instead of elapsed time
- Hook detects terminal app (iTerm2 / Terminal.app) and per-pane TTY device by walking the process tree

### Fixed
- Sessions not disappearing after closing a terminal
- Sessions stuck in "waiting" after tool approval (resolved via transcript mtime check)
- False "input needed" notifications from recap messages (now uses `matcher: "permission_prompt"` on the Notification hook)
- Green elapsed time color removed from session rows

## [1.1.2] - 2026-06-26

### Fixed
- Dev badge incorrectly shown on Homebrew installs — now uses `Bundle.main.executablePath` instead of `argv[0]` for reliable install path detection
- LaunchAgent installed automatically at login via `brew install`

## [1.1.1] - 2026-06-26

### Fixed
- Release workflow now correctly uses CHANGELOG.md for release notes

## [1.1.0] - 2026-06-26

### Added
- Version number and `dev` badge visible in menu dropdown header
- GitHub Actions CI (build + test on every push and PR)
- GitHub Actions release workflow — tag a version to publish automatically
- Homebrew `post_install` now auto-installs the hook script and configures `~/.claude/settings.json`

### Fixed
- Version text color in dropdown was invisible (switched to `secondaryLabelColor`)

## [1.0.0] - 2026-06-26

Initial release.

- macOS menu bar app monitoring all active Claude Code sessions
- Spinning indicator with elapsed time while working
- Pulsing amber dot + Sosumi sound when a session needs input
- Green flash + Glass sound when a session finishes
- Dropdown with per-session details: project, model, elapsed time, token usage
- Daily token usage summary
- `flock`-based hook script prevents false "needs input" notifications
- 8-second debounce with transcript recency check as belt-and-suspenders
- Homebrew tap: `brew tap hosseintoussi/agentchirp && brew install agentchirp`
