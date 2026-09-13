#!/usr/bin/env bash
# Native helper is installed next to this adapter; source builds resolve it locally.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$script_dir/agentchirp-hook"
if [ ! -x "$helper" ]; then helper="$script_dir/.build/release/agentchirp-hook"; fi
if [ ! -x "$helper" ]; then
  if [ "${1:-}" = codex ]; then printf '{}\n'; exit 0; fi
  printf '%s\n' 'Start AgentChirp to install its helper, or run swift build -c release.' >&2
  exit 1
fi

# Only this explicit launcher mode starts a server. Monitoring remains read-only.
if [ "${1:-}" = launch-codex ]; then
  shift
  set -e
  for argument in "$@"; do
    case "$argument" in
      --remote|--remote=*) printf '%s\n' 'codex-chirp selects the local shared server; omit --remote.' >&2; exit 2 ;;
    esac
  done
  if ! command -v codex >/dev/null 2>&1; then
    printf '%s\n' 'Codex CLI was not found. Install it from https://developers.openai.com/codex/cli/ and open a new terminal, then try again.' >&2
    exit 127
  fi
  server=$(codex app-server daemon start)
  socket_path=$(printf '%s' "$server" | "$helper" --socket-path)
  exec codex --remote "unix://$socket_path" --cd "$PWD" "$@"
fi

provider=claude
state="${1:-}"
directory="$HOME/.claude/agentchirp/sessions"
if [ "$state" = codex ]; then
  provider=codex
  directory="${2:-${CODEX_HOME:-$HOME/.codex}/agentchirp/sessions}"
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
    if [ -f "$existing" ] && ! grep -Eq '"state"[[:space:]]*:[[:space:]]*"waiting"' "$existing"; then exit 0; fi
  fi
fi
if [ "$provider" = codex ]; then
  printf '%s' "$json" | "$helper" codex "$directory"
  exit 0
fi
effective=$(printf '%s' "$json" | "$helper" "$state" "$directory")
case "$effective" in
  working) set_tab 240 180 0 ;;
  waiting) set_tab 220 40 40 ;;
  done)    set_tab 40 160 80 ;;
  idle|ended) reset_tab ;;
esac
