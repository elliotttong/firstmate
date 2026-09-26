#!/usr/bin/env bash
# fm-jcode-composer-input.sh - jcode's structural composer read.
#
# Prints exactly one word for the jcode TUI client working in <working-dir>:
#   empty    the client reports an empty composer
#   pending  the client reports composer text (any byte, whitespace included)
#   unknown  anything else: no daemon, debug control off, no session, more than
#            one session for the directory, no connected TUI client, a timeout,
#            or output that does not parse
#
# WHY IT EXISTS: a rendered jcode composer cannot prove itself empty. A draft of
# spaces renders exactly like an empty `N>` row, and a draft of blank lines can
# push its text off the captured rows. jcode's daemon reports the composer text
# itself (verified on jcode v0.88.0):
#
#   $ JCODE_DEBUG_CONTROL=1 jcode debug -S <session> client:state
#   {"input":"","processing":false,"cursor_pos":0,...}          # empty
#   {"input":"\nhidden draft on line two",...}                  # blank-first draft
#
# bin/fm-composer-lib.sh's fm_composer_jcode_verdict requires this read AND the
# rendered composer to agree before anything is called empty, so no single
# vendor surface is load-bearing for the one verdict that authorizes typing.
#
# The session is found by working directory, the same task<->session key
# bin/fm-jcode-busy-bridge.sh uses: firstmate gives every crewmate its own
# worktree. `jcode debug sessions` can list a directory more than once (for
# example a detached session beside a live one), and an ambiguous match reads
# `unknown` rather than guessing which client is the pane's.
#
# Usage: fm-jcode-composer-input.sh <working-dir>
# Env:   FM_JCODE_COMPOSER_TIMEOUT  seconds per daemon call (default 5)
#        FM_JCODE_BIN               jcode executable (default: PATH, then ~/.local/bin/jcode)
# Exit:  0 whenever a verdict is printed (including `unknown`); 2 usage.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$here/fm-timeout-lib.sh"

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: fm-jcode-composer-input.sh <working-dir>" >&2; exit 2; }

say() { printf '%s\n' "$1"; exit 0; }

working_dir=$(cd "$1" 2>/dev/null && pwd -P) || say unknown
bound=${FM_JCODE_COMPOSER_TIMEOUT:-5}
case "$bound" in ''|*[!0-9]*|0) bound=5 ;; esac
jcode_bin=${FM_JCODE_BIN:-}
if [ -z "$jcode_bin" ]; then
  jcode_bin=$(command -v jcode 2>/dev/null) || jcode_bin=
  [ -n "$jcode_bin" ] || [ ! -x "$HOME/.local/bin/jcode" ] || jcode_bin="$HOME/.local/bin/jcode"
fi
[ -n "$jcode_bin" ] || say unknown
command -v jq >/dev/null 2>&1 || say unknown

jdebug() {
  JCODE_DEBUG_CONTROL=1 fm_run_timed "$bound" "$jcode_bin" debug "$@" 2>/dev/null
}

sessions=$(jdebug sessions) || say unknown
session=$(printf '%s' "$sessions" | jq -r --arg wd "$working_dir" '
  if type != "array" then empty
  else map(select(type == "object" and .working_dir == $wd)) as $m
    | if ($m | length) == 1 then ($m[0].session_id // empty) else empty end
  end' 2>/dev/null) || say unknown
case "$session" in session_*) ;; *) say unknown ;; esac

state=$(jdebug -S "$session" client:state) || say unknown
printf '%s' "$state" | jq -r '
  if type == "object" and (.input | type) == "string"
  then (if .input == "" then "empty" else "pending" end)
  else "unknown" end' 2>/dev/null | head -n1 | grep -xE 'empty|pending' || say unknown
