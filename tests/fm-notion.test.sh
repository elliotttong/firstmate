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

# 10. An unreachable API is a network failure (1), not a usage error.
stop_fake
out=$(printf '%s' "$filter" | notion query actions 2>&1); rc=$?
expect_code 1 "$rc" "unreachable Notion is a network failure"
assert_contains "$out" "cannot reach Notion" "failure says Notion was unreachable"

pass "fm-notion engine and wrapper behave against the fake API"
