#!/usr/bin/env bash
# Codex uses the same bundled script with a separate provider adapter. Always emit
# an empty JSON result so hooks never change approval or continuation decisions.
if [ "${1:-}" = "codex" ]; then
  shift
  exec python3 -c 'import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time


def process_info():
    # Only the actual ancestor chain can identify this terminal. Do not guess from
    # another Codex window or bind a desktop session to an arbitrary open terminal.
    try:
        out = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,tty=,comm="],
                                      text=True, stderr=subprocess.DEVNULL, timeout=1)
    except Exception:
        return 0, "", ""
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            table[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
    pid, agent, terminal, device = os.getppid(), 0, "", ""
    seen = set()
    while pid > 1 and pid in table and pid not in seen:
        seen.add(pid)
        parent, tty, command = table[pid]
        base = os.path.basename(command).lower()
        if not agent and (base == "codex" or base.startswith("codex-")):
            agent = pid
            if tty.startswith("ttys"):
                device = "/dev/" + tty
        if base == "iterm2":
            terminal = "iTerm2"
        elif base == "terminal":
            terminal = "Terminal"
        pid = parent
    return agent, terminal, device


def record():
    hook = json.load(sys.stdin)
    sid = hook.get("session_id", "")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", sid):
        return
    event = hook.get("hook_event_name", "")
    states = {"SessionStart": "idle", "UserPromptSubmit": "working",
              "PreToolUse": "working", "PostToolUse": "working",
              "PermissionRequest": "waiting", "Stop": "done", "Interrupt": "idle"}
    if event not in states and event != "SessionEnd":
        return
    transcript = hook.get("transcript_path") or ""
    # Subagent hooks can report their parent'"'"'s session id. Ignore a child
    # transcript rather than letting its Stop mark the parent finished.
    if transcript:
        try:
            with open(transcript) as f:
                first = json.loads(f.readline(65536))
            if first.get("type") == "session_meta":
                meta = first.get("payload", {})
                if meta.get("id") and meta["id"] != sid:
                    return
                if isinstance(meta.get("source"), dict) and "subagent" in meta["source"]:
                    return
        except (OSError, ValueError):
            pass
    directory = sys.argv[1]
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, sid + ".json")
    # Keep locks separate from state files: unlinking a lock lets queued writers
    # lock different inodes and breaks serialization. These tiny files are reusable.
    locks = os.path.join(directory, ".locks")
    os.makedirs(locks, mode=0o700, exist_ok=True)
    lock_path = os.path.join(locks, str(int(hashlib.sha256(sid.encode()).hexdigest(), 16) % 64))
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                previous = json.load(f)
        except (OSError, ValueError):
            previous = {}
        if event == "SessionEnd":
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            return
        turn = hook.get("turn_id") or previous.get("turn_id", "")
        previous_turn = previous.get("turn_id", "")
        if event not in ("SessionStart", "UserPromptSubmit"):
            if previous_turn and turn and turn != previous_turn:
                return
            if previous.get("last_event") in ("Stop", "Interrupt") and turn == previous_turn:
                return
        if event == "SessionStart" and previous.get("state") in ("working", "waiting"):
            return
        state = states[event]
        pending = previous.get("pending_tools", []) if turn == previous_turn else []
        tool = hook.get("tool_name", "")
        tool_input = hook.get("tool_input")
        # Approval events can add a description absent from PostToolUse. Bash and
        # patch calls correlate on the actual command, not that approval-only text.
        if isinstance(tool_input, dict) and "command" in tool_input:
            tool_input = {"command": tool_input["command"]}
        tool_key = hashlib.sha256(json.dumps([tool, tool_input], sort_keys=True).encode()).hexdigest()
        # The console shows what the agent is waiting for: the tool and, for shell
        # calls, the command itself (trimmed so the state file stays small).
        detail = previous.get("detail", "") if turn == previous_turn else ""
        if event == "PermissionRequest" or (event == "PreToolUse" and tool.split("__")[-1].split(".")[-1] == "request_user_input"):
            if tool_key not in pending:
                pending.append(tool_key)
            command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
            command = " ".join(str(command).split())[:120]
            detail = f"{tool}: {command}" if command else (tool or "")
        elif event == "PostToolUse":
            pending = [key for key in pending if key != tool_key]
        elif event in ("Stop", "Interrupt", "UserPromptSubmit", "SessionStart"):
            pending = []
        if pending:
            state = "waiting"
        else:
            detail = ""
        now = time.time()
        ts = previous.get("ts", now) if previous.get("state") == state and turn == previous_turn else now
        # Re-evaluate ancestry each event: a resumed session may have moved terminals.
        agent, terminal, tty = process_info()
        data = {"provider": "codex", "session_id": sid, "state": state, "ts": ts,
                "turn_id": turn, "last_event": event, "pending_tools": pending, "detail": detail,
                "cwd": hook.get("cwd") or previous.get("cwd", ""),
                "transcript_path": transcript, "model": hook.get("model") or previous.get("model", ""),
                "agent_pid": agent, "terminal": terminal, "tty": tty}
        temporary = path + ".tmp"
        with open(temporary, "w") as f:
            json.dump(data, f)
        os.replace(temporary, path)


try:
    record()
except Exception:
    # Monitoring must not block the agent or add text to its prompt.
    pass
print("{}")
' "${1:-${CODEX_HOME:-$HOME/.codex}/ccbeacon/sessions}"
fi

# Reflect Claude Code state: iTerm2 tab color + session state file.
state="${1:-}"
TTY=/dev/tty
SESSIONS_DIR="$HOME/.claude/cc-sessions"
ts=$(date +%s)

# 2>/dev/null must come before >"$TTY": redirections apply left to right, so a failed
# tty open is silenced instead of spamming stderr when there is no controlling terminal.
set_tab() {
  [ -w "$TTY" ] || return 0
  printf '\033]6;1;bg;red;brightness;%s\a'   "$1" 2>/dev/null >"$TTY" || true
  printf '\033]6;1;bg;green;brightness;%s\a' "$2" 2>/dev/null >"$TTY" || true
  printf '\033]6;1;bg;blue;brightness;%s\a'  "$3" 2>/dev/null >"$TTY" || true
}

reset_tab() {
  [ -w "$TTY" ] || return 0
  printf '\033]6;1;bg;*;default\a' 2>/dev/null >"$TTY" || true
}

json=$(cat 2>/dev/null || echo "{}")

# PreToolUse fires the moment an approved tool starts, which is the only signal that
# a permission prompt was answered. It also fires for every other tool call, so only
# a session that is currently waiting pays for the Python write; the rest exit here.
if [ "$state" = "resume" ]; then
  if [[ "$json" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_.-]+)\" ]]; then
    existing="$SESSIONS_DIR/${BASH_REMATCH[1]}.json"
    if [ -f "$existing" ] && ! grep -q '"state": "waiting"' "$existing"; then exit 0; fi
  fi
  state=working
fi

# Values reach Python via the environment (not shell interpolation), so paths or hook
# fields containing quotes cannot break or inject into the Python source.
# Python prints the effective state ("" when the write was skipped); the shell then
# colors the tab to match what was actually recorded.
effective=$(printf '%s' "$json" | CCB_STATE="$state" CCB_TS="$ts" CCB_DIR="$SESSIONS_DIR" python3 -c '
import sys, json, os, fcntl

hook = {}
try:
    hook = json.load(sys.stdin)
except Exception:
    pass

state           = os.environ.get("CCB_STATE", "")
ts              = int(os.environ.get("CCB_TS", "0") or 0)
sessions_dir    = os.environ.get("CCB_DIR", "")
event           = hook.get("hook_event_name", "")
session_id      = str(hook.get("session_id", "default")).replace("/", "_")
cwd             = hook.get("cwd", "")
transcript_path = hook.get("transcript_path", "")
# Notification hooks carry a human sentence ("Claude needs your permission to use
# Bash"); the console shows it on the row so the user knows what is being asked.
detail          = " ".join(str(hook.get("message", "") or "").split())[:200] if state == "waiting" else ""

# Walk the process tree to find the Claude PID, hosting terminal app, and TTY device.
# TTY is read from the ps snapshot for the Claude process -- the hook process itself has
# all fds redirected (stdin piped, stderr to /dev/null), so its own tty is useless.
# One ps snapshot for the whole table instead of one call per ancestor. Matching is on
# the executable basename: comm is a full path on macOS, so the old exact-name check
# never detected Terminal.app.
def _find_session_info():
    import subprocess as _sp
    try:
        out = _sp.check_output(["ps", "-axo", "pid=,ppid=,tty=,comm="],
                               stderr=_sp.DEVNULL, text=True)
    except Exception:
        return 0, "", ""
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            try:
                procs[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
            except ValueError:
                pass
    pid = os.getppid()
    seen = set()
    claude_pid = 0
    terminal = ""
    tty_device = ""
    for _ in range(12):
        if pid <= 1 or pid in seen or pid not in procs:
            break
        seen.add(pid)
        ppid, tty, comm = procs[pid]
        base = comm.rsplit("/", 1)[-1].lower().strip()
        if not claude_pid and ("node" in base or base.startswith("claude")):
            claude_pid = pid
            if tty and tty != "??":
                if tty.startswith("/dev/"):
                    tty_device = tty
                elif tty.startswith("ttys"):
                    tty_device = "/dev/" + tty
                else:
                    tty_device = "/dev/tty" + tty
        if not terminal:
            if "iterm2" in base:      terminal = "iTerm2"
            elif base == "terminal":  terminal = "Terminal"
        pid = ppid
    return claude_pid, terminal, tty_device

# Fast path: the session file already holds pid/tty/terminal from an earlier event.
# Reuse them while that PID is alive (reads are safe lock-free thanks to atomic
# writes); a session resumed in a new terminal has a dead stored PID and re-walks.
_prev = {}
try:
    with open(os.path.join(sessions_dir, f"{session_id}.json")) as _f:
        _prev = json.load(_f)
except Exception:
    pass

claude_pid   = int(_prev.get("claude_pid", 0) or 0)
tty_device   = _prev.get("tty", "")
terminal_app = _prev.get("terminal", "")

_alive = False
if claude_pid > 0:
    try:
        os.kill(claude_pid, 0)
        _alive = True
    except PermissionError:
        _alive = True
    except Exception:
        _alive = False

if not (_alive and tty_device):
    claude_pid, terminal_app, tty_device = _find_session_info()
    if claude_pid == 0:   claude_pid   = int(_prev.get("claude_pid", 0) or 0)
    if not tty_device:    tty_device   = _prev.get("tty", "")
    if not terminal_app:  terminal_app = _prev.get("terminal", "")

os.makedirs(sessions_dir, exist_ok=True)
session_file = os.path.join(sessions_dir, f"{session_id}.json")
lock_path    = session_file + ".lock"

# Serialize concurrent hook scripts (Notification and Stop can run simultaneously).
# flock ensures the read-check-write is atomic so a stale state can never win the race.
with open(lock_path, "w") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)

    # SessionEnd means the session is over (quit, not finished): remove the state file
    # so the app drops the session immediately and never chimes "finished" for a quit.
    if event == "SessionEnd":
        for p in (session_file, lock_path):
            try:
                os.remove(p)
            except OSError:
                pass
        print("ended")
        sys.exit(0)

    # prev_state must be re-read under the lock: another hook may have written
    # between the fast-path read above and acquiring the lock.
    skip = False
    prev_state = ""
    prev_ts = 0
    try:
        with open(session_file) as f:
            _locked_prev = json.load(f)
            prev_state = _locked_prev.get("state", "")
            prev_ts = int(_locked_prev.get("ts", 0) or 0)
    except Exception:
        pass
    # ts means "time in the current state": a repeat of the same state keeps it.
    if prev_state == state and prev_ts:
        ts = prev_ts

    if state == "waiting":
        if prev_state == "done":
            skip = True
    elif state == "idle":
        if prev_state in ("working", "waiting"):
            skip = True

    if not skip:
        # Write to a temp file and rename: the rename is atomic, so the app (which reads
        # without the lock) never sees a truncated file, and the directory watcher gets
        # an event for every state change.
        tmp = session_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"state": state, "ts": ts, "session_id": session_id,
                       "cwd": cwd, "transcript_path": transcript_path,
                       "claude_pid": claude_pid, "tty": tty_device,
                       "terminal": terminal_app, "detail": detail}, f)
        os.replace(tmp, session_file)
        print(state)
' 2>/dev/null)

case "$effective" in
  working) set_tab 240 180 0 ;;
  waiting) set_tab 220 40 40 ;;
  done)    set_tab 40 160 80 ;;
  idle)    reset_tab ;;
  ended)   reset_tab ;;
esac
