#!/usr/bin/env bash
# Start a separate shared-server CLI session. Monitoring never invokes this mode.
if [ "${1:-}" = launch-codex ]; then
  shift
  set -e
  for argument in "$@"; do
    case "$argument" in
      --remote|--remote=*) printf '%s\n' 'codex-beacon selects the local shared server; omit --remote.' >&2; exit 2 ;;
    esac
  done
  server=$(codex app-server daemon start)
  socket_path=$(printf '%s' "$server" | python3 -c 'import json,sys,os
value=json.load(sys.stdin).get("socketPath", "")
if not os.path.isabs(value): raise SystemExit("Codex did not return an absolute socket path")
print(value)')
  exec codex --remote "unix://$socket_path" --cd "$PWD" "$@"
fi

# One bundled adapter; no approval or continuation decisions.
provider=claude
state="${1:-}"
directory="$HOME/.claude/cc-sessions"
if [ "$state" = codex ]; then
  provider=codex
  directory="${2:-${CODEX_HOME:-$HOME/.codex}/ccbeacon/sessions}"
fi
TTY=/dev/tty

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
if [ "$provider" = claude ] && [ "$state" = resume ]; then
  if [[ "$json" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_.-]+)\" ]]; then
    existing="$directory/${BASH_REMATCH[1]}.json"
    if [ -f "$existing" ] && ! grep -q '"state": "waiting"' "$existing"; then exit 0; fi
  fi
fi
effective=$(printf '%s' "$json" | CCB_PROVIDER="$provider" CCB_STATE="$state" CCB_DIR="$directory" python3 -c '
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager

@contextmanager
def locked_state(path):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    locks = os.path.join(directory, ".locks")
    os.makedirs(locks, mode=0o700, exist_ok=True)
    sid = os.path.basename(path)[:-5]
    bucket = int(hashlib.sha256(sid.encode()).hexdigest(), 16) % 64
    # The app takes this same lock before revalidating stale state. Never unlink it.
    with open(os.path.join(locks, str(bucket)), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                previous = json.load(f)
            if not isinstance(previous, dict):
                previous = {}
        except (OSError, ValueError):
            previous = {}
        yield previous


def write_state(path, data):
    temporary = path + ".tmp"
    with open(temporary, "w") as f:
        json.dump(data, f)
    os.replace(temporary, path)

def process_info(provider):
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
        matches = (base == "codex" or base.startswith("codex-")) if provider == "codex" else (base.startswith("claude") or base == "node")
        if not agent and matches:
            agent = pid
            if tty.startswith("ttys"):
                device = "/dev/" + tty
        if base == "iterm2":
            terminal = "iTerm2"
        elif base == "terminal":
            terminal = "Terminal"
        pid = parent
    return agent, terminal, device


def record_codex(hook):
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
    directory = os.environ["CCB_DIR"]
    path = os.path.join(directory, sid + ".json")
    with locked_state(path) as previous:
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
        fingerprint = hashlib.sha256(json.dumps([tool, tool_input], sort_keys=True).encode()).hexdigest()
        # Questions may have different input representations after execution. Their
        # invocation id is stable across PreToolUse/PostToolUse; permissions lack it.
        call_id = hook.get("tool_use_id")
        tool_key = "call:" + call_id if isinstance(call_id, str) and call_id else fingerprint
        # Persist only the waiting kind; commands are used solely for correlation hashes.
        detail = previous.get("detail", "") if turn == previous_turn else ""
        if event == "PermissionRequest":
            tool_key = fingerprint
        if event == "PermissionRequest" or (event == "PreToolUse" and tool.split("__")[-1].split(".")[-1] == "request_user_input"):
            if tool_key not in pending:
                pending.append(tool_key)
            detail = "input" if event == "PreToolUse" else "permission"
        elif event == "PostToolUse":
            pending = [key for key in pending if key not in (tool_key, fingerprint)]
        elif event in ("Stop", "Interrupt", "UserPromptSubmit", "SessionStart"):
            pending = []
        if pending:
            state = "waiting"
        else:
            detail = ""
        now = time.time()
        ts = previous.get("ts", now) if previous.get("state") == state and turn == previous_turn else now
        # Re-evaluate ancestry each event: a resumed session may have moved terminals.
        agent, terminal, tty = process_info("codex")
        data = {"provider": "codex", "session_id": sid, "state": state, "ts": ts,
                "turn_id": turn, "last_event": event, "pending_tools": pending, "detail": detail,
                "cwd": hook.get("cwd") or previous.get("cwd", ""),
                "transcript_path": transcript or previous.get("transcript_path", ""), "model": hook.get("model") or previous.get("model", ""),
                "agent_pid": agent, "terminal": terminal, "tty": tty}
        write_state(path, data)


def record_claude(hook):
    sid = hook.get("session_id", "")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,160}", sid):
        return ""
    event = hook.get("hook_event_name", "")
    state = os.environ["CCB_STATE"]
    if state not in ("idle", "working", "waiting", "done", "resume"):
        return ""
    path = os.path.join(os.environ["CCB_DIR"], sid + ".json")
    agent, terminal, tty = process_info("claude")
    with locked_state(path) as previous:
        if event == "SessionEnd":
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            return "ended"
        previous_state = previous.get("state", "")
        if state == "resume":
            # Recheck under the lock; Stop may have arrived after the shell fast path.
            if previous_state and previous_state != "waiting":
                return ""
            state = "working"
        if state == "waiting" and previous_state == "done":
            return ""
        if state == "idle" and previous_state in ("working", "waiting"):
            return ""
        now = time.time()
        ts = previous.get("ts", now) if previous_state == state else now
        detail = ""
        if state == "waiting":
            detail = "input" if hook.get("notification_type") == "elicitation_dialog" else "permission"
        write_state(path, {"provider": "claude", "state": state, "ts": ts, "session_id": sid,
                           "last_event": event, "cwd": hook.get("cwd") or previous.get("cwd", ""),
                           "transcript_path": hook.get("transcript_path") or previous.get("transcript_path", ""),
                           "claude_pid": agent, "tty": tty, "terminal": terminal, "detail": detail})
        return state

try:
    hook = json.load(sys.stdin)
    if os.environ["CCB_PROVIDER"] == "codex":
        record_codex(hook)
    else:
        print(record_claude(hook))
except Exception:
    pass
if os.environ["CCB_PROVIDER"] == "codex":
    print("{}")
' 2>/dev/null)

if [ "$provider" = codex ]; then
  printf '%s\n' "$effective"
  exit 0
fi
case "$effective" in
  working) set_tab 240 180 0 ;;
  waiting) set_tab 220 40 40 ;;
  done)    set_tab 40 160 80 ;;
  idle|ended) reset_tab ;;
esac
