#!/usr/bin/env bash
# fm-notion-check.sh - the Notion board reconcile as a standing watcher check.
#
# Usage:
#   fm-notion-check.sh [check]
#   fm-notion-check.sh arm
#   fm-notion-check.sh disarm
#   fm-notion-check.sh --help
#
# `check` runs one reconcile pass in both directions, outside the model's
# context, and prints one line only when firstmate should wake:
#   down  bin/fm-notion.sh down - new work in firstmate's lane marked Ready,
#         and answers the captain has written on rows flagged Needs you.
#   up    bin/fm-notion.sh up - firstmate's own records against the board.
#         Report-only by default; with the private opt-in file
#         config/notion-sync containing the word `apply`, the pass also
#         writes (bounded per pass, so a big first sync spreads over passes).
#         Drift (orphan, stale and spec lines) is reported either way, never
#         resolved.
# Each surfaced item is keyed (ready page, answer page plus answer text,
# drift line) in the private record state/.notion-check, so the same item
# wakes firstmate once, and again only if it changes or disappears and
# returns. A pass that fails (Notion unreachable, missing credential) is
# reported once per distinct failure line. The wake line names counts and
# points at `fm-notion.sh down` and `fm-notion.sh up` for the detail.
#
# A board field can raise work or carry an answer; it never grants merge,
# destructive, irreversible, or security-sensitive authority.
#
# `arm` writes state/notion.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its FM_CHECK_INTERVAL
# cadence and turns its one line into a `check:` wake. `disarm` retires the
# shim and its trust binding through fm-check-unregister.sh and removes the
# record.
#
# The pass must finish inside the watcher's per-check bound (FM_CHECK_TIMEOUT,
# default 30). FM_NOTION_CHECK_BUDGET (default 20, valid 5..25) is cut down to
# fit, and a pass that overruns reports one line naming the budget.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config"
RECORD="$STATE/.notion-check"
RECORD_SCHEMA=fm-notion-check-v1
CHECK_ID=notion
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
NOTION_BIN="$SCRIPT_DIR/fm-notion.sh"
MAX_LINE=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_SECS=${FM_NOTION_CHECK_BUDGET:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*) BUDGET_SECS=0 ;;
esac
if [ "$BUDGET_SECS" -lt 5 ] || [ "$BUDGET_SECS" -gt 25 ]; then
  printf 'fm-notion-check: FM_NOTION_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
  exit 2
fi
BUDGET_MAX=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
[ "$BUDGET_SECS" -le "$BUDGET_MAX" ] || BUDGET_SECS=$BUDGET_MAX

sync_mode() {
  local word=
  [ -f "$CONFIG/notion-sync" ] && IFS= read -r word < "$CONFIG/notion-sync"
  case "$word" in
    apply) printf 'apply\n' ;;
    *) printf 'report\n' ;;
  esac
}

# One key per surfaced item. Answers key on their text so an edited answer
# wakes again; drift keys on the whole line.
keys_from() {
  awk '
    $1 == "ready" { print "ready " $2; next }
    $1 == "answer" { print "answer " $3 " " substr($0, index($0, $4)); next }
    $1 == "orphan" || $1 == "stale" || $1 == "spec" { print $0; next }
  '
}

record_keys() {
  [ -f "$RECORD" ] || return 0
  [ "$(sed -n 1p "$RECORD")" = "$RECORD_SCHEMA" ] || return 0
  sed -n 's/^key=//p' "$RECORD"
}

record_failure() {
  [ -f "$RECORD" ] || return 0
  [ "$(sed -n 1p "$RECORD")" = "$RECORD_SCHEMA" ] || return 0
  sed -n 's/^failure=//p' "$RECORD" | sed -n 1p
}

record_write() {  # <keys-file> <failure-line>
  local keys=$1 failure=$2 tmp
  tmp=$(umask 077; mktemp "$STATE/.notion-check.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'failure=%s\n' "$failure"
    sed 's/^/key=/' "$keys"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

first_error() {  # <output>
  printf '%s\n' "$1" | sed -n 's/^fm-notion: //p' | sed -n 1p
}

action_check() {
  local work out rc mode start elapsed left failure="" line="" prev_failure
  local ready answers drift
  mkdir -p "$STATE" || return 1
  [ -x "$NOTION_BIN" ] || { printf 'notion: fm-notion.sh is missing next to this check\n'; return 0; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-notion-check.XXXXXX") || return 1
  : > "$work/found"
  mode=$(sync_mode)
  start=$(date +%s)

  rc=0
  out=$(fm_run_timed "$BUDGET_SECS" "$NOTION_BIN" down 2>&1) || rc=$?
  if fm_timed_out "$rc"; then
    failure="board read did not finish within the ${BUDGET_SECS}s budget"
  elif [ "$rc" -ne 0 ]; then
    failure="board read failed: $(first_error "$out")"
  else
    printf '%s\n' "$out" >> "$work/found"
    elapsed=$(( $(date +%s) - start ))
    left=$((BUDGET_SECS - elapsed))
    if [ "$left" -lt 2 ]; then
      failure="board reconcile skipped: the read used the whole ${BUDGET_SECS}s budget"
    else
      rc=0
      if [ "$mode" = apply ]; then
        out=$(fm_run_timed "$left" "$NOTION_BIN" up --apply 2>&1) || rc=$?
      else
        out=$(fm_run_timed "$left" "$NOTION_BIN" up 2>&1) || rc=$?
      fi
      if fm_timed_out "$rc"; then
        failure="board reconcile did not finish within the ${BUDGET_SECS}s budget"
      elif [ "$rc" -ne 0 ]; then
        failure="board reconcile failed: $(first_error "$out")"
      else
        printf '%s\n' "$out" >> "$work/found"
      fi
    fi
  fi

  keys_from < "$work/found" | sort -u > "$work/keys"
  record_keys | sort -u > "$work/seen"
  comm -23 "$work/keys" "$work/seen" > "$work/new"
  ready=$(grep -c '^ready ' "$work/new")
  answers=$(grep -c '^answer ' "$work/new")
  drift=$(grep -cE '^(orphan|stale|spec) ' "$work/new")

  if [ -n "$failure" ]; then
    prev_failure=$(record_failure)
    # A failed pass cannot prove anything vanished, so keep what was seen.
    sort -u "$work/seen" "$work/keys" > "$work/keep"
    [ "$failure" = "$prev_failure" ] || line="$failure"
    record_write "$work/keep" "$failure" || true
  else
    record_write "$work/keys" "" || true
  fi
  if [ -z "$line" ] && [ $((ready + answers + drift)) -gt 0 ]; then
    line="board has"
    [ "$ready" -eq 0 ] || line="$line $ready new ready item(s),"
    [ "$answers" -eq 0 ] || line="$line $answers new answer(s),"
    [ "$drift" -eq 0 ] || line="$line $drift new drift finding(s),"
    line="${line%,}; see fm-notion.sh down and fm-notion.sh up"
  fi
  rm -rf -- "$work"
  if [ -n "$line" ]; then
    fm_cap_line_var "notion: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-notion-check.sh - Notion board reconcile shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-notion-check.sh") check"
}

action_arm() {
  local home tmp
  [ -x "$NOTION_BIN" ] || { printf 'fm-notion-check: %s is missing; cannot arm\n' "$NOTION_BIN" >&2; return 1; }
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'fm-notion-check: %s is not a directory\n' "$STATE" >&2; return 1; }
  [ ! -L "$CHECK_SHIM" ] || { printf 'fm-notion-check: refusing a symlink at %s\n' "$CHECK_SHIM" >&2; return 1; }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-notion-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$STATE/.fm-notion-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-notion-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  # An unbound shim is rejected by the watcher on every cycle, so a failed
  # registration removes it rather than leaving the home half armed.
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-notion-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh (%s mode)\n' "$CHECK_ID" "$(sync_mode)"
}

action_disarm() {
  if [ -e "$CHECK_SHIM" ] || [ -e "$STATE/$CHECK_ID.check-trust" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  fi
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) printf 'fm-notion-check: unknown command %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
