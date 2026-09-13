# DESIGN.md

# AgentChirp: does an agent need me, and where do I go?

AgentChirp is a local monitor for Claude Code and Codex sessions, not a transcript
viewer. Every surface answers those two questions first and stays out of the way
otherwise. Mode: Operate. Native macOS conventions outrank expression.

## The signal

- The mark is an upright bird silhouette beneath two rounded beam arcs, which
  also read as chirps. No eye, feet, or feather details; it must read at 18 points.
- The menu bar beacon is calm. It signals state; it does not animate all day.
  - Resting: the neutral template mark, steady.
  - Working: the same mark breathing slowly (75% and back every 1.4 seconds). The
    shape never changes; only opacity does.
  - Needs input: orange. A session that newly asks for input earns three short
    flashes (about two seconds), then the beacon holds steady orange until answered.
  - Just finished: green for ten seconds, even while other sessions work.
  - Reduce Motion removes the flash; every state is still readable by shape and color.
- Sound is a soft ping for a request and Glass for completion, never an error alert.
  Sounds can be turned off with the speaker button in the console header. Answered
  requests cancel their pending sound. Standalone Codex permissions stay visual-only because
  approval resolution is not separately observable through its hooks. Sessions
  started with `codex-chirp` use live shared-server status to clear amber and
  cancel answered alerts on the next refresh.

## One orange

System orange carries "needs input" everywhere: the menu bar, the header beacon,
the state dot, the clock, the headline. Light mode darkens it for text contrast;
dark mode uses it as is. Green is completion, the accent color is working, neutral
is idle. No other hue appears. All text uses system semantic colors; all fills are
black or white at low opacity and double under Increase Contrast. The console root
is clear so the popover's own material shows through.

## The console

The header is the answer. The beacon, lit by the top state, sits beside one
sentence: "2 need input", "3 working", "All quiet", "Nothing running". The subline
carries the rest of the counts, a just-finished project, or which integrations are
being watched. Three quiet controls sit at the top right, each an icon with a
caption beneath it in the Control Center idiom: Awake / May sleep, Sounds / Muted,
Quit. The caption states the current mode, the icon echoes it. The version rides on
the quit tooltip. There is no branding and no menu.

While any session is working, or Codex is waiting within an active turn, the app
keeps the Mac and display from idle sleep. The Awake button turns this off (sun when on, moon when sleep is
allowed). Its tooltip says whether the lock is currently held. A full-width hairline
closes the header; the same hairline, inset to the text edge, separates rows.

One list, one order: sessions that need input first (longest waiting at the top),
then working (longest running first), then idle (most recent first). There are no
tabs and no section headings; each row states its own state.

A row is 64 points and two lines. Line one: a state dot (filled orange, filled
accent, filled green, or a hollow ring), the project name, and a verb clock on the
right ("waiting 2m", "working 35m", "idle 2h 1m"). Line two: the provider and, for a
waiting session, what it is asking for ("Needs permission", "Waiting for
your answer"); otherwise the model. Projects with the same folder name show their
parent folder. The whole row opens its terminal when available; rows without a supported
terminal have no action or action icon. Hover shows
the full path and token usage. Arrow keys move between rows; Return activates;
keyboard focus draws the system focus ring.

The empty state confirms readiness and which providers are watched.

## Updates

Keep the window frame fixed throughout an opening. Live changes affect only the
scroll document and header text; scroll position and keyboard focus survive
one-second refreshes. Reopening may choose a new size. The popover and dashboard
must receive the same size at every opening.

## Verification

Use mixed-provider fixtures, same-name projects, waiting rows with and without a
recorded ask, a just-finished session, empty states, and overflow lists. Verify the
finite flash, the steady working beacon, the completion cue, ordering, copy
feedback, keyboard controls, and Reduce Motion. View-only screenshots cannot prove
native popover placement or material; capture native chrome too.

## Installation and settings

The downloaded app has a permanent home in Applications. A first-run window shows
which agent integrations were installed, reports failures with Check again, and
explains Codex hook review without pretending to grant trust. Login launch is an
explicit opt-in. Update checks have a visible preference; session data never
enters the update request.

The console keeps its three captioned controls. Its existing bird is also the
Settings button, with a tooltip, accessibility label, and Command-comma shortcut.
Opening AgentChirp again from Applications also opens Settings. This separate
window owns setup, login launch, and updates, with Done to close it.
Users start their agents from their terminal. Neither tool is
required to install AgentChirp. Missing tools get installation links, and newly
initialized tools are picked up automatically without restarting AgentChirp.
