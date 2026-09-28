#!/usr/bin/env bash
# tests/fm-notion-check.test.sh - the Notion board reconcile as a watcher check.
#
# Drives bin/fm-notion-check.sh through its public command surface against
# tests/notion-fake.py. Covers: a quiet board prints nothing, a new ready row
# and a new answer wake once and not again, an edited answer wakes again,
# drift wakes once, a Notion failure wakes once per distinct failure, the
# default pass writes nothing while config/notion-sync=apply writes, and arm
# and disarm produce a watcher-trusted shim and retire it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP=$(fm_test_tmproot fm-notion-check)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
chmod 700 "$HOME_DIR/state"
printf 'NOTION_TOKEN=fake-notion-token\nNOTION_ACTION_ITEMS_DB=db-actions\n' > "$HOME_DIR/.env"

write_world() {  # <answer-text>
  python3 - "$TMP/world.json" "$1" <<'PY'
import json, sys
def text(s):
    return [{"plain_text": s}] if s else []
def row(pid, title, lane, ready=False, task="", needs=False, answer=""):
    return {"id": pid, "url": "https://notion.so/" + pid, "properties": {
        "Action Item": {"type": "title", "title": text(title)},
        "Lane": {"type": "select", "select": {"name": lane}},
        "Ready": {"type": "checkbox", "checkbox": ready},
        "Task ID": {"type": "rich_text", "rich_text": text(task)},
        "Needs you": {"type": "checkbox", "checkbox": needs},
        "Answer": {"type": "rich_text", "rich_text": text(answer)},
        "Last checked": {"type": "date", "date": {"start": "2026-09-26T11:00:00.000+00:00"}},
    }}
json.dump({"databases": {"db-actions": {"properties": {}, "pages": [
    row("new1", "Build the export", "Claude", ready=True),
    row("asked", "Pick a colour", "Claude", task="askme", needs=True, answer=sys.argv[2]),
    row("personal", "Book dentist", "Personal", ready=True),
]}}}, open(sys.argv[1], "w"))
PY
}

FAKE_PID=
start_fake() {
  rm -f "$TMP/port"
  : > "$TMP/requests.log"
  python3 "$ROOT/tests/notion-fake.py" "$TMP/world.json" "$TMP/port" "$TMP/requests.log" &
  FAKE_PID=$!
  local i=0
  while [ ! -s "$TMP/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$TMP/port" ] || fail "fake Notion server did not start"
  BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"
}
stop_fake() {
  [ -z "$FAKE_PID" ] || { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
  FAKE_PID=
}
trap 'stop_fake; fm_test_cleanup' EXIT

# The askme task is captain-held in the backlog, so the board agrees with it.
cat > "$TMP/listing.toon" <<'EOF'
count: 1
tasks[1]{id,state,kind,repo,title,hold_kind,hold_reason}:
  askme,queued,task,-,Pick a colour,captain,Which colour?
EOF

check() {
  env -u NOTION_TOKEN FM_HOME="$HOME_DIR" FM_NOTION_API_BASE="$BASE" \
    FM_NOTION_BACKLOG_LISTING="$TMP/listing.toon" FM_NOTION_NOW=2026-09-26T12:00:00Z \
    "$ROOT/bin/fm-notion-check.sh" check
}

write_world "blue"
start_fake

# 1. First pass: one wake line naming the new ready item and the answer.
out=$(check 2>&1); rc=$?
expect_code 0 "$rc" "first pass succeeds"
assert_contains "$out" "notion: board has 1 new ready item(s), 1 new answer(s)" "first pass wakes for new work and the answer"
assert_equals "1" "$(printf '%s\n' "$out" | grep -c .)" "a pass prints at most one line"

# 2. The same board again is silent.
out=$(check 2>&1); rc=$?
expect_code 0 "$rc" "second pass succeeds"
assert_equals "" "$out" "an unchanged board does not wake again"

# 3. The default pass is report-only: nothing is written to the board.
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "report-only pass sends no update"
assert_no_grep '"path": "/v1/pages"' "$TMP/requests.log" "report-only pass creates nothing"

# 4. An edited answer wakes again.
stop_fake
write_world "green, actually"
start_fake
out=$(check 2>&1)
assert_contains "$out" "1 new answer(s)" "a changed answer wakes again"
assert_not_contains "$out" "ready" "the already-seen ready row stays quiet"

# 5. Drift wakes once: a board row whose task firstmate no longer has.
cat > "$TMP/listing.toon" <<'EOF'
count: 0
tasks[0]{id,state,kind,repo,title,hold_kind,hold_reason}:
EOF
out=$(check 2>&1)
assert_contains "$out" "1 new drift finding(s)" "an orphaned row is drift"
out=$(check 2>&1)
assert_equals "" "$out" "the same drift does not wake twice"

# 6. Notion unreachable: one wake per distinct failure, and seen items survive.
stop_fake
out=$(check 2>&1)
assert_contains "$out" "notion: board read failed: cannot reach Notion" "an unreachable board is reported"
out=$(check 2>&1)
assert_equals "" "$out" "the same failure is reported once"
start_fake
out=$(check 2>&1)
assert_equals "" "$out" "recovery does not re-announce items already seen"

# 7. config/notion-sync=apply lets the pass write, bounded per pass.
cat > "$TMP/listing.toon" <<'EOF'
count: 2
tasks[2]{id,state,kind,repo,title,hold_kind,hold_reason}:
  askme,queued,task,-,Pick a colour,captain,Which colour?
  brandnew,queued,ship,-,A new backlog item,-,-
EOF
printf 'apply\n' > "$HOME_DIR/config/notion-sync"
check > /dev/null 2>&1
assert_grep '"path": "/v1/pages"' "$TMP/requests.log" "apply mode creates the missing row"
rm -f "$HOME_DIR/config/notion-sync"

# 8. arm writes a watcher-trusted shim; disarm retires it and the record.
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-notion-check.sh" arm 2>&1); rc=$?
expect_code 0 "$rc" "arm succeeds"
assert_contains "$out" "armed: state/notion.check.sh (report mode)" "arm names the shim and its mode"
assert_present "$HOME_DIR/state/notion.check.sh" "arm writes the shim"
assert_present "$HOME_DIR/state/notion.check-trust" "arm binds the shim"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
fm_custom_check_registered "$HOME_DIR/state" notion || fail "the watcher would reject the armed shim"
assert_grep "fm-notion-check.sh" "$HOME_DIR/state/notion.check.sh" "the shim runs this check"
out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-notion-check.sh" disarm 2>&1); rc=$?
expect_code 0 "$rc" "disarm succeeds"
assert_absent "$HOME_DIR/state/notion.check.sh" "disarm removes the shim"
assert_absent "$HOME_DIR/state/notion.check-trust" "disarm removes the binding"
assert_absent "$HOME_DIR/state/.notion-check" "disarm removes the record"

pass "fm-notion-check wakes once per new board item and arms a trusted shim"
