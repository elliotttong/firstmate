#!/usr/bin/env bash
# tests/fm-notion.test.sh - the Notion engine and its wrapper, against a local fake.
#
# Drives bin/fm-notion.sh through its public command surface with
# FM_NOTION_API_BASE pointed at tests/notion-fake.py, so no network or real
# credential is involved. Covers: the token stays off argv and out of output,
# narrow queries print simplified rows and follow pagination, a whole-database
# read is refused, the row ceiling truncates loudly, and exit statuses separate
# usage (2) from Notion or network failure (1).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP=$(fm_test_tmproot fm-notion)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"

page() {  # <id> <title> <lane> <ready>
  printf '{"id":"%s","url":"https://notion.so/%s","last_edited_time":"2026-09-26T10:00:00.000Z","properties":{"Action Item":{"type":"title","title":[{"plain_text":"%s"}]},"Lane":{"type":"select","select":{"name":"%s"}},"Ready":{"type":"checkbox","checkbox":%s}}}' \
    "$1" "$1" "$2" "$3" "$4"
}

{
  printf '{"users_me":{"type":"bot","name":"Firstmate board"},"databases":{"db-actions":{"properties":{},"pages":['
  page p1 "Ship the thing" Claude true; printf ','
  page p2 "Buy milk" Personal true; printf ','
  page p3 "Draft spec" Claude false; printf ','
  page p4 "Another ready" Claude true
  printf ']}}}'
} > "$TMP/world.json"

FAKE_PID=
start_fake() {
  rm -f "$TMP/port" "$TMP/requests.log"
  : > "$TMP/requests.log"
  python3 "$ROOT/tests/notion-fake.py" "$TMP/world.json" "$TMP/port" "$TMP/requests.log" &
  FAKE_PID=$!
  local i=0
  while [ ! -s "$TMP/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$TMP/port" ] || fail "fake Notion server did not start"
}
stop_fake() {
  [ -z "$FAKE_PID" ] || { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
  FAKE_PID=
}
trap 'stop_fake; fm_test_cleanup' EXIT

start_fake
BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"

notion() {
  env -u NOTION_TOKEN -u NOTION_ACTION_ITEMS_DB -u NOTION_PROJECTS_DB \
    FM_HOME="$HOME_DIR" FM_NOTION_API_BASE="$BASE" "$ROOT/bin/fm-notion.sh" "$@"
}

printf 'NOTION_TOKEN="fake-notion-token"\nNOTION_ACTION_ITEMS_DB=db-actions\nNOTION_PROJECTS_DB=db-projects\n' > "$HOME_DIR/.env"
chmod 600 "$HOME_DIR/.env"

# 1. whoami reads the token from the home .env and never prints it.
out=$(notion whoami 2>&1); rc=$?
expect_code 0 "$rc" "whoami succeeds with the .env token"
assert_contains "$out" "notion: bot Firstmate board" "whoami names the integration"
assert_not_contains "$out" "fake-notion-token" "whoami never prints the token"

# 2. A narrow query prints simplified rows for the matching pages only.
filter='{"filter":{"and":[{"property":"Lane","select":{"equals":"Claude"}},{"property":"Ready","checkbox":{"equals":true}}]}}'
out=$(printf '%s' "$filter" | notion query actions 2>&1); rc=$?
expect_code 0 "$rc" "narrow query succeeds"
assert_equals "2" "$(printf '%s\n' "$out" | grep -c '"id"')" "query returns exactly the two ready Claude rows"
assert_contains "$out" '"Action Item": "Ship the thing"' "title is reduced to plain text"
assert_contains "$out" '"Lane": "Claude"' "select is reduced to its option name"
assert_contains "$out" '"Ready": true' "checkbox is reduced to a boolean"
assert_not_contains "$out" "Buy milk" "a personal row never matches the lane filter"

# 3. The query addressed the configured database; the token rode the header
# (the fake answers 401 to any request without it).
assert_grep '"path": "/v1/databases/db-actions/query"' "$TMP/requests.log" "query addressed the configured database"

# 4. Pagination: --limit below the match count truncates loudly, not silently.
out=$(printf '%s' "$filter" | notion query actions --limit 1 2>"$TMP/err"); rc=$?
expect_code 0 "$rc" "limited query still succeeds"
assert_equals "1" "$(printf '%s\n' "$out" | grep -c '"id"')" "limit caps the rows printed"
assert_grep "query stopped at 1 rows; more matched" "$TMP/err" "truncation is reported on stderr"

# 5. Pagination across pages: a ceiling above one page follows next_cursor.
out=$(printf '%s' '{"filter":{"property":"Lane","select":{"is_not_empty":true}}}' \
  | FM_NOTION_MAX_ROWS=3 notion query actions 2>"$TMP/err"); rc=$?
expect_code 0 "$rc" "ceilinged query succeeds"
assert_equals "3" "$(printf '%s\n' "$out" | grep -c '"id"')" "row ceiling bounds the whole read"
assert_grep "more matched" "$TMP/err" "ceiling truncation is reported"

# 6. A whole-database read is refused as usage, before any request is sent.
before=$(wc -l < "$TMP/requests.log")
out=$(printf '{}' | notion query actions 2>&1); rc=$?
expect_code 2 "$rc" "an unfiltered query is a usage refusal"
assert_contains "$out" "whole-database read is refused" "refusal names the reason"
assert_equals "$before" "$(wc -l < "$TMP/requests.log")" "refused query sent nothing"

# 7. A wrong database id is a Notion failure (1) with the REST-id hint.
out=$(printf '%s' "$filter" | NOTION_PROJECTS_DB=db-missing FM_HOME="$HOME_DIR" \
  FM_NOTION_API_BASE="$BASE" NOTION_TOKEN=fake-notion-token "$ROOT/bin/fm-notion.sh" query projects 2>&1); rc=$?
expect_code 1 "$rc" "an unknown database is a Notion failure"
assert_contains "$out" "HTTP 404" "failure names the HTTP status"
assert_contains "$out" "not a data source id" "404 carries the REST-id hint"

# 8. A bad token is a Notion failure (1) that does not echo the token.
out=$(NOTION_TOKEN=wrong-token FM_HOME="$HOME_DIR" FM_NOTION_API_BASE="$BASE" \
  "$ROOT/bin/fm-notion.sh" whoami 2>&1); rc=$?
expect_code 1 "$rc" "a rejected token is a Notion failure"
assert_contains "$out" "unauthorized" "failure carries Notion's error code"
assert_not_contains "$out" "wrong-token" "failure never echoes the token"

# 9. Missing configuration and bad arguments are usage (2).
mkdir -p "$TMP/empty-home"
out=$(env -u NOTION_TOKEN FM_HOME="$TMP/empty-home" "$ROOT/bin/fm-notion.sh" whoami 2>&1); rc=$?
expect_code 2 "$rc" "missing token is a usage refusal"
assert_contains "$out" "NOTION_TOKEN is not set" "refusal names the missing key"
out=$(printf '%s' "$filter" | notion query nowhere 2>&1); rc=$?
expect_code 2 "$rc" "unknown database name is usage"
out=$(printf '%s' "$filter" | notion query actions --limit 0 2>&1); rc=$?
expect_code 2 "$rc" "out-of-range limit is usage"

# 10. ensure-schema is additive: a dry run writes nothing, a real run adds
# only the missing fields, and a second run is a no-op.
mkdir -p "$HOME_DIR/projects/alpha"
out=$(notion ensure-schema --dry-run 2>&1); rc=$?
expect_code 0 "$rc" "schema dry run succeeds"
assert_contains "$out" "would add: Dev status" "dry run names the missing Dev status field"
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "dry run sends no write"
out=$(notion ensure-schema 2>&1); rc=$?
expect_code 0 "$rc" "schema apply succeeds"
assert_contains "$out" "add: Needs you" "apply adds the Needs you flag"
assert_grep '"Dev status": {"select": {"options": [{"name": "Queued"}' "$TMP/requests.log" "Dev status is a fixed option list"
assert_grep '{"name": "alpha"}' "$TMP/requests.log" "Repo options come from the cloned projects"
assert_grep '"Blocked by": {"relation": {"database_id": "db-actions", "dual_property": {"synced_property_name": "Blocks"}' "$TMP/requests.log" "dependencies are a two-way self-relation"
assert_grep '"Unblocks": {"rollup": {"function": "count", "relation_property_name": "Blocks"' "$TMP/requests.log" "Unblocks is a derived count, added after its relation"
patches=$(grep -c '"method": "PATCH"' "$TMP/requests.log")
out=$(notion ensure-schema 2>&1); rc=$?
expect_code 0 "$rc" "second schema run succeeds"
assert_contains "$out" "present: Dev status" "second run sees the field"
assert_not_contains "$out" "add:" "second run adds nothing"
assert_equals "$patches" "$(grep -c '"method": "PATCH"' "$TMP/requests.log")" "second run sends no write"

# 11. A field of the wrong type is a conflict: reported, and nothing written.
stop_fake
python3 - "$TMP/world.json" <<'PY'
import json, sys
path = sys.argv[1]
world = json.load(open(path))
world["databases"]["db-actions"]["properties"] = {"Ready": {"type": "rich_text", "rich_text": {}}}
json.dump(world, open(path, "w"))
PY
start_fake
BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"
out=$(notion ensure-schema 2>&1); rc=$?
expect_code 1 "$rc" "a type conflict fails the schema run"
assert_contains "$out" "conflict: Ready is rich_text, expected checkbox" "conflict is named"
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "a conflicting schema run writes nothing"

# 12. down reads only firstmate's lane for new work, and answered decisions.
stop_fake
python3 - "$TMP/world.json" <<'PY'
import json, sys
def row(pid, title, lane=None, ready=False, task="", needs=False, answer=""):
    text = lambda s: [{"plain_text": s}] if s else []
    return {"id": pid, "url": "https://notion.so/" + pid, "properties": {
        "Action Item": {"type": "title", "title": text(title)},
        "Lane": {"type": "select", "select": {"name": lane} if lane else None},
        "Ready": {"type": "checkbox", "checkbox": ready},
        "Task ID": {"type": "rich_text", "rich_text": text(task)},
        "Needs you": {"type": "checkbox", "checkbox": needs},
        "Answer": {"type": "rich_text", "rich_text": text(answer)},
    }}
world = {"databases": {"db-actions": {"properties": {}, "pages": [
    row("new1", "Build the export", "Claude", ready=True),
    row("mine-not-ready", "Someday idea", "Claude"),
    row("taken", "Already dispatched", "Claude", ready=True, task="exportfix"),
    row("personal", "Book dentist", "Personal", ready=True),
    row("both", "Shared chore", "Both", ready=True),
    row("nolane", "Unlabelled", None, ready=True),
    row("asked", "Pick a colour", "Claude", task="colourpick", needs=True, answer="blue, the darker one"),
    row("unanswered", "Waiting on him", "Claude", task="waiting", needs=True),
]}}}
json.dump(world, open(sys.argv[1], "w"))
PY
start_fake
BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"
out=$(notion down 2>&1); rc=$?
expect_code 0 "$rc" "down succeeds"
assert_contains "$out" "ready new1 Build the export" "a ready row in firstmate's lane is new work"
assert_contains "$out" "answer colourpick asked blue, the darker one" "an answered decision is surfaced with its task id"
assert_equals "2" "$(printf '%s\n' "$out" | grep -c .)" "nothing else is surfaced"
for other in Someday dispatched dentist Shared Unlabelled Waiting; do
  assert_not_contains "$out" "$other" "down ignores the row titled '$other'"
done
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "down is read-only"

# 13. up reconciles the board with firstmate's records: report-only by
# default, bounded writes with --apply, drift reported and never resolved.
stop_fake
python3 - "$TMP/world.json" <<'PY'
import json, sys
def text(s):
    return [{"plain_text": s}] if s else []
def row(pid, task, dev, checked, extra=None):
    props = {
        "Action Item": {"type": "title", "title": text(task)},
        "Task ID": {"type": "rich_text", "rich_text": text(task)},
        "Dev status": {"type": "select", "select": {"name": dev} if dev else None},
        "Kind": {"type": "select", "select": {"name": "ship"}},
        "Repo": {"type": "select", "select": {"name": "alpha"}},
        "Needs you": {"type": "checkbox", "checkbox": False},
        "Question": {"type": "rich_text", "rich_text": []},
        "PR": {"type": "url", "url": None},
        "Worker": {"type": "rich_text", "rich_text": []},
        "Last checked": {"type": "date", "date": {"start": checked} if checked else None},
        "Status": {"type": "select", "select": {"name": "Next Up"}},
    }
    props.update(extra or {})
    return {"id": pid, "url": "https://notion.so/" + pid, "properties": props}
fresh = "2026-09-26T11:00:00.000+00:00"
world = {"databases": {"db-actions": {"properties": {}, "pages": [
    row("pg-building", "building", "Queued", fresh),
    row("pg-synced", "synced", "Queued", fresh),
    row("pg-old", "oldcheck", "Queued", "2026-09-20T00:00:00.000+00:00"),
    row("pg-design", "designing", "Needs design", fresh),
    row("pg-orphan", "gone", "Building", fresh),
]}}}
json.dump(world, open(sys.argv[1], "w"))
PY
cat > "$TMP/listing.toon" <<'EOF'
count: 7
tasks[7]{id,state,kind,repo,title,hold_kind,hold_reason}:
  building,in_flight,ship,alpha,Build the thing,-,-
  synced,queued,ship,alpha,Already right,-,-
  oldcheck,queued,ship,alpha,Nothing changed,-,-
  designing,queued,ship,alpha,Needs a design pass,-,-
  fresh,queued,scout,alpha,"A brand new, \"quoted\" item",-,-
  askme,queued,task,-,Pick a colour,captain,"Blue or green? \"Blue\" is the default"
  ghost,in_flight,ship,alpha,Worker died long ago,-,-
EOF
mkdir -p "$HOME_DIR/state"
printf 'kind=ship\nharness=claude\npr=https://github.com/o/r/pull/7\n' > "$HOME_DIR/state/building.meta"
printf 'working [at=1]: started\n' > "$HOME_DIR/state/building.status"
touch -d '2026-09-26 10:00' "$HOME_DIR/state/building.status" "$HOME_DIR/state/building.meta"
start_fake
BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"
up() {
  FM_NOTION_NOW=2026-09-26T12:00:00Z FM_NOTION_BACKLOG_LISTING="$TMP/listing.toon" notion up "$@"
}
out=$(up 2>&1); rc=$?
expect_code 0 "$rc" "report-only up succeeds"
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "report-only up sends no update"
assert_no_grep '"path": "/v1/pages"' "$TMP/requests.log" "report-only up creates nothing"
assert_contains "$out" "orphan gone pg-orphan" "a board row with no local record is an orphan"
assert_contains "$out" "stale ghost no live record" "an in-flight item with no record is stale"
assert_contains "$out" "update building Dev status: Queued -> Building" "an in-flight task moves to Building"
assert_contains "$out" "update building PR: - -> https://github.com/o/r/pull/7" "the PR link comes from the task record"
assert_contains "$out" "update building Worker: - -> claude" "the worker comes from the task record"
assert_contains "$out" "update building Last activity: - -> 2026-09-26" "last activity is the day of the newest status event"
assert_not_contains "$out" "update oldcheck Last activity" "a task with no record gets no invented activity date"
assert_contains "$out" "refresh oldcheck" "an old Last checked is refreshed even with no change"
assert_contains "$out" 'create fresh Queued A brand new, "quoted" item' "a new backlog item is created with its title"
assert_contains "$out" "create askme Queued Pick a colour" "a captain-held item is created"
assert_not_contains "$out" "synced" "a row already in line and freshly checked is left alone"
assert_not_contains "$out" "designing" "a hand-set design stage is not pulled back to Queued"
assert_contains "$out" "report only: 5 write(s) pending" "the report counts the pending writes"
[ "$(printf '%s\n' "$out" | grep -n '^orphan' | cut -d: -f1)" -lt "$(printf '%s\n' "$out" | grep -n '^create' | head -n1 | cut -d: -f1)" ] \
  || fail "drift lines lead the report"

out=$(up --apply --max-writes 2 2>&1); rc=$?
expect_code 0 "$rc" "bounded apply succeeds"
assert_contains "$out" "applied 2 write(s); 3 deferred to the next pass" "apply stops at the write bound"
out=$(up --apply 2>&1); rc=$?
expect_code 0 "$rc" "second apply succeeds"
assert_contains "$out" "applied 3 write(s); 0 deferred" "the next pass finishes the rest"
assert_grep '"Needs you": {"checkbox": true}' "$TMP/requests.log" "a captain-held item is flagged Needs you"
assert_grep 'Blue or green? \"Blue\" is the default' "$TMP/requests.log" "the hold reason becomes the Question"
assert_grep '"Lane": {"select": {"name": "Claude"}}' "$TMP/requests.log" "created rows are in firstmate's lane"
assert_no_grep '"Status":' "$TMP/requests.log" "the captain's Status column is never written"
assert_no_grep '"Priority":' "$TMP/requests.log" "the captain's Priority column is never written"
out=$(up 2>&1); rc=$?
expect_code 0 "$rc" "a converged board reports cleanly"
assert_contains "$out" "report only: 0 write(s) pending" "a converged board has nothing to write"
assert_contains "$out" "orphan gone" "an orphan is still reported, never deleted"

# 14. ensure-projects adds the initiative fields, additions only, and rolls
# Last worked up from the related Action Items' Last activity.
stop_fake
python3 - "$TMP/world.json" <<'PY'
import json, sys
world = {"databases": {
    "db-actions": {"properties": {"Last activity": {"type": "date", "date": {}}}, "pages": []},
    "db-projects": {"properties": {
        "Project": {"type": "title", "title": {}},
        "Rating": {"type": "select", "select": {"options": [{"name": "⭐"}]}},
        "Review Date": {"type": "date", "date": {}},
        "Action Items": {"type": "relation", "relation": {"database_id": "db-actions"}},
    }, "pages": []},
}}
json.dump(world, open(sys.argv[1], "w"))
PY
start_fake
BASE="http://127.0.0.1:$(cat "$TMP/port")/v1"
out=$(notion ensure-projects --dry-run 2>&1); rc=$?
expect_code 0 "$rc" "projects dry run succeeds"
assert_contains "$out" "would add: Automation level" "dry run names Automation level"
assert_no_grep '"method": "PATCH"' "$TMP/requests.log" "projects dry run writes nothing"
out=$(notion ensure-projects 2>&1); rc=$?
expect_code 0 "$rc" "projects apply succeeds"
assert_grep '"Automation level": {"select": {"options": [{"name": "Fully automated"}, {"name": "Needs a human"}, {"name": "Manual"}]}}' "$TMP/requests.log" "Automation level is a fixed three-way list"
assert_grep '"Numbers": {"url": {}}' "$TMP/requests.log" "Numbers is a link, not copied metrics"
assert_grep '"Last worked": {"rollup": {"function": "latest_date", "relation_property_name": "Action Items", "rollup_property_name": "Last activity"}}' "$TMP/requests.log" "Last worked is derived through the existing relation"
assert_no_grep '"Rating":' "$TMP/requests.log" "the existing Rating is never rewritten"
assert_no_grep '"Review Date":' "$TMP/requests.log" "the existing Review Date is never rewritten"
out=$(notion ensure-projects 2>&1); rc=$?
expect_code 0 "$rc" "second projects run succeeds"
assert_not_contains "$out" "add:" "second projects run adds nothing"

# 15. An unreachable API is a network failure (1), not a usage error.
stop_fake
out=$(printf '%s' "$filter" | notion query actions 2>&1); rc=$?
expect_code 1 "$rc" "unreachable Notion is a network failure"
assert_contains "$out" "cannot reach Notion" "failure says Notion was unreachable"

pass "fm-notion engine and wrapper behave against the fake API"
