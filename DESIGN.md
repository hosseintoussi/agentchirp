# ccbeacon: attention, then return to work

The app answers two questions: does an agent need me, and where do I go to respond?
It is a local monitor for Claude Code and Codex sessions, not a transcript viewer.

## Information hierarchy

- The menu bar beacon signals urgency without taking extra space: amber flash for
  input, slow neutral blink for work, a brief green completion cue, steady at idle.
- Needs input / Working / Idle tabs are mutually exclusive. They own state names
  and counts. Do not repeat those as a summary strip, group headings, or row labels.
- A session row owns identity and action: project, provider, useful context, elapsed
  time, and a whole-row terminal action. Time means time in the current state. Tooltips clarify this.
- Rows use two lines in 64 points, separated by fine rules. Hover reveals path and usage.
- Compact borderless state segments use a neutral selected fill and quiet counts.
- A quiet sound toggle stays in the footer; Quit lives in the header settings menu.
  The compact header keeps the version beneath the app name.

## Navigation and updates

Opening prioritizes Needs input, then Working, then Idle. Longest-waiting sessions
come first. While open, respect the selected tab even as sessions change state.
The attention tab's count and amber label reveal new requests without stealing focus.
An empty tab explains its state once. The tabs provide state navigation.

Keep the window frame fixed throughout an opening. Changes in counts, state, and tabs
affect the scroll document. Reopening may choose a new size.
Preserve per-tab scrolling and focused controls during clock and usage updates.
The popover and dashboard must receive the same size at every opening. Keep the list's
scroll hierarchy attached throughout the presentation. Header and footer positions come
from actual content bounds, never a stale requested height.

## Verification

Use mixed-provider fixtures, same-name projects, empty states, and overflow lists.
Verify real popover anchoring, exclusive state membership, attention-first opening,
live transitions, terminal actions, keyboard controls, and Reduce Motion behavior.
View-only screenshots cannot prove native popover placement; capture native chrome too.
