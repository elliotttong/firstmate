#!/usr/bin/env bash
# Behavior tests for the verified jcode crewmate adapter.
#
# jcode is the ONLY verified adapter whose interrupt key is not Escape and whose
# interrupt doubles as quit when idle, so the control-fact assertions here are
# load-bearing safety checks rather than documentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry; drop ambient
# ones so a suite run from inside another harness cannot skew the verdict.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

TMP_ROOT=$(fm_test_tmproot fm-jcode-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT
command -v jq >/dev/null || fail "test needs jq"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# --------------------------------------------------------------- control facts
[ "$(fm_control_interrupt_key jcode)" = C-c ] \
  || fail "jcode must interrupt on C-c, never the shared Escape default"
pass "jcode interrupts on C-c, not Escape"

[ "$(fm_control_interrupt_repeat jcode)" = 1 ] || fail "jcode interrupt repeat must be 1"
[ -z "$(fm_control_interrupt_clear_key jcode)" ] || fail "jcode needs no composer clear key"
[ "$(fm_control_interrupt_ack_source jcode)" = none ] \
  || fail "jcode must not claim a cancellation ack it has not verified"
pass "jcode interrupt mechanics: single press, no clear key, no ack claim"

[ "$(fm_control_exit_command jcode)" = /quit ] || fail "jcode exits on /quit"
[ "$(fm_control_harness_family jcode)" = jcode ] || fail "jcode resolves to its own family"
fm_control_harness_supported jcode || fail "jcode must be a supported harness"
pass "jcode exit command, family, and supported status"

fm_control_harness_supports_kind jcode ship || fail "jcode must run a ship"
fm_control_harness_supports_kind jcode scout || fail "jcode must run a scout"
if fm_control_harness_supports_kind jcode secondmate; then
  fail "jcode has no primary supervision protocol and must be refused as a secondmate"
fi
pass "jcode is a crewmate/scout adapter and is refused as a secondmate"

case "$(fm_control_harness_wiring_paths jcode /wt /state tid)" in
  */state/tid.jcode-bridge.pid) ;;
  *) fail "jcode per-task wiring must be the bridge pidfile so relaunch can clear it" ;;
esac
pass "jcode per-task wiring path is the bridge pidfile"

# ----------------------------------------------------------------- busy source
case " $(fm_busy_sources_for_harness jcode) " in
  *" jcode-debug "*) ;;
  *) fail "jcode semantic source must be jcode-debug" ;;
esac
fm_busy_source_trusted jcode jcode-debug || fail "jcode must trust jcode-debug"
if fm_busy_source_trusted claude jcode-debug; then
  fail "jcode-debug must never classify another harness task"
fi
if fm_busy_source_trusted jcode claude-hook; then
  fail "jcode must not trust another adapter source"
fi
pass "jcode-debug is trusted for jcode only, in both directions"

STATE="$TMP_ROOT/state"; mkdir -p "$STATE"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" t1 --state idle --source fm-spawn --event launch-brief) \
  || fail "could not arm a jcode task"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 busy --gen "$GEN" --source jcode-debug --event turn-start >/dev/null \
  || fail "jcode-debug busy event refused"
[ "$(fm_busy_classify herdr no-ep jcode t1 "$STATE")" = "busy jcode-debug" ] \
  || fail "a jcode-debug busy record must classify busy"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 idle --gen "$GEN" --source jcode-debug --event turn-end >/dev/null \
  || fail "jcode-debug idle event refused"
[ "$(fm_busy_classify herdr no-ep jcode t1 "$STATE")" = "idle jcode-debug" ] \
  || fail "a jcode-debug idle record must classify idle"
case "$(fm_busy_classify herdr no-ep claude t1 "$STATE")" in
  unknown*) ;;
  *) fail "a jcode record must never classify a claude task" ;;
esac
pass "jcode-debug records classify busy and idle, and never cross adapters"

if "$ROOT/bin/fm-busy-event.sh" apply "$STATE" t1 busy --gen g-stale-000 \
     --source jcode-debug --event turn-start >/dev/null 2>&1; then
  fail "a superseded incarnation bridge must be refused"
fi
pass "a stale-gen jcode-debug event is refused"

# -------------------------------------------------- composer delivery guard
JCODE_SPIN_ROW=$(printf '\xe2\xa0\xbc 1s')
JCODE_SEND_ROW=$(printf '\xe2\xa0\xb8 sending context 9s')
for row in "$JCODE_SPIN_ROW" "$JCODE_SEND_ROW"; do
  printf '%s\0' "$row" | fm_busy_lines_match jcode \
    || fail "jcode in-flight row must read busy: $row"
done
for row in '   6.2s  107.4 tps' '   write DONE.txt (+1 -0)' '2>'; do
  if printf '%s\0' "$row" | fm_busy_lines_match jcode; then
    fail "jcode settled row must not read busy: $row"
  fi
done
if printf '%s\0' "$JCODE_SPIN_ROW" | fm_busy_lines_match claude; then
  fail "a jcode spinner row must not read busy for another harness"
fi
pass "jcode composer guard matches only in-flight rows, and only for jcode"

# ------------------------------------------- numbered composer classification
# jcode numbers its composer prompt (`1>`, `2>`, `1<>` once submitted) and
# draws a context meter and a status glyph at the row's far right. Left
# unrecognized, every jcode composer reads `unknown`, and bin/fm-control.sh
# refuses to type an exit command unless the composer is PROVEN empty - which
# is how two stalled jcode workers became unrecoverable through the guarded
# path on 2026-09-23. These are the shapes captured live from jcode v0.86.0.
JC_CAPS=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')
JC_METER='3.1k/1.0M ▱▱▱▱▱▱ 0%'
JC_GLYPH=$(printf '\xf3\xb0\x96\x9f')  # U+F059F, jcode's right-hand status glyph

jc_verdict() {  # <composer-row> -> verdict
  local screen
  screen=$(printf 'transcript row\n%s\n' "$1" | fm_composer_jcode_normalize_screen)
  fm_composer_classify_screen "$JC_CAPS" "$screen" 1
}

[ "$(jc_verdict "1>                                   $JC_METER")" = empty ] \
  || fail "an EMPTY jcode composer must classify empty, or the guarded exit path can never stop a jcode agent"
[ "$(jc_verdict "1>                                   $JC_GLYPH")" = empty ] \
  || fail "an empty jcode composer carrying only the status glyph must classify empty"
[ "$(jc_verdict "12>")" = empty ] \
  || fail "a multi-digit jcode turn index must classify empty: the index grows with the conversation"
[ "$(jc_verdict "1<> already submitted")" = pending ] \
  || fail "a submitted jcode row still carries text and must not read empty"
pass "an empty jcode composer classifies empty rather than unknown"

[ "$(jc_verdict "1> draft text here                   $JC_METER")" = pending ] \
  || fail "a jcode composer holding typed text must classify pending so an exit cannot concatenate onto it"
[ "$(jc_verdict "1> draft text here                   $JC_GLYPH")" = pending ] \
  || fail "typed text must still read pending when the row ends in the status glyph"
[ "$(jc_verdict "1> 3.1k/1.0M")" = pending ] \
  || fail "meter-shaped text the operator actually TYPED is content: only the row's furniture tail is stripped"
pass "a typed jcode composer classifies pending, and meter-like typed text is not eaten"

# The dead-shell rule is the reason this is scoped to an identified jcode pane.
# It must survive: an agent that exited leaves a real shell prompt behind, and
# typing an exit command into that shell is exactly what the rule prevents.
[ "$(jc_verdict "> ")" = unknown ] \
  || fail "a bare shell prompt must still read unknown even on a jcode pane: the agent may have exited"
[ "$(jc_verdict "$ ")" = unknown ] \
  || fail "a dollar shell prompt must still read unknown"
pass "the dead-shell rule survives for a bare prompt on a jcode pane"

# The normalization must be a no-op on every other harness's shape, because a
# jcode pane is identified structurally and this must not drift into a
# fleet-wide rewrite if that gate is ever reached wrongly.
for other in '❯ claude row' '› codex row' '⟩ muse row' '2 > 1 is true' '$ x'; do
  jc_row=$other
  fm_composer_jcode_row_normalize_var jc_row
  [ "$jc_row" = "$other" ] \
    || fail "jcode normalization must not touch another harness's row: [$other] became [$jc_row]"
done
pass "jcode composer normalization leaves every other harness's row byte-identical"

# ------------------------------------ measured v0.88.0 screens, shared verdict
# tests/captures/jcode-v0.88.0 holds raw tmux captures of a real jcode v0.88.0
# pane (its README names each state). fm_composer_jcode_verdict is what every
# backend returns for an identified jcode pane, so these pin the verdict to
# measured bytes. A false `empty` types /quit onto somebody's draft; a false
# `unknown` only costs a turn. Every assertion below leans that way.
JC_CAP_DIR="$ROOT/tests/captures/jcode-v0.88.0"
[ -d "$JC_CAP_DIR" ] || fail "missing $JC_CAP_DIR"

jc_capture_verdicts() {  # <state> <structural> -> "<styled-cursor> <plain-cursorless>"
  local state=$1 structural=$2 cy
  cy=$(cut -d' ' -f2 "$JC_CAP_DIR/$state.cursor")
  printf '%s %s' \
    "$(fm_composer_jcode_verdict "$(printf 'styled=1\ncursor=1\nidentity=0\nrows=0')" \
        "$(cat "$JC_CAP_DIR/$state.styled")" "$structural")" \
    "$(fm_composer_jcode_verdict "$(printf 'styled=0\ncursor=0\nidentity=0\nrows=0')" \
        "$(cat "$JC_CAP_DIR/$state.plain")" "$structural")"
  : "$cy"  # the cursor row is deliberately ignored; see fm_composer_jcode_verdict
}

# A genuinely empty composer, fresh, after a reply (the case the cursor-anchored
# read called `unknown` because of jcode's info box), and after a turn with the
# status glyph, is `empty` only when jcode's own report agrees.
for state in idle-empty post-response-empty busy4; do
  [ "$(jc_capture_verdicts "$state" empty)" = "empty empty" ] \
    || fail "measured empty jcode composer '$state' must read empty when jcode agrees: got $(jc_capture_verdicts "$state" empty)"
  [ "$(jc_capture_verdicts "$state" unknown)" = "unknown unknown" ] \
    || fail "measured empty jcode composer '$state' must NOT read empty without jcode's own report: got $(jc_capture_verdicts "$state" unknown)"
  [ "$(jc_capture_verdicts "$state" pending)" = "pending pending" ] \
    || fail "jcode reporting text under an empty-looking '$state' must read pending"
done
pass "a measured empty jcode composer reads empty only when the render and jcode's own report agree"

# Every measured draft - including ones that look like a prompt glyph, a digit,
# a shell glyph, a wrapped line, a real newline, and a blank FIRST line with the
# cursor parked on it - must never read `empty`, whatever the structural read
# claims, because the render already shows the text.
for state in idle-typed wrap multiline-alt blankfirst-alt-top adv-agentglyph adv-digit adv-shellglyph; do
  for structural in empty pending unknown; do
    got=$(jc_capture_verdicts "$state" "$structural")
    case "$got" in
      *empty*) fail "measured jcode draft '$state' read empty (structural=$structural): $got" ;;
    esac
  done
done
pass "no measured jcode draft ever reads empty, even when the structural read is wrong"

# A draft of spaces renders exactly like an empty composer; only jcode's report
# can tell, and it does.
[ "$(jc_capture_verdicts ws-spaces pending)" = "pending pending" ] \
  || fail "a whitespace-only jcode draft must read pending when jcode reports it"
pass "a whitespace-only jcode draft is caught by jcode's own report"

# Mid-turn (`2…`) is never a composer the exit command may be typed into.
for structural in empty pending unknown; do
  case "$(jc_capture_verdicts busy2 "$structural")" in
    *empty*) fail "a mid-turn jcode pane must never read empty (structural=$structural)" ;;
  esac
done
pass "a mid-turn jcode pane never reads empty"

# ------------------------------------------------ the structural composer read
PROBE="$ROOT/bin/fm-jcode-composer-input.sh"
JC_FAKE="$TMP_ROOT/fake-jcode"
JC_WD="$TMP_ROOT/wd"
mkdir -p "$JC_WD"
JC_WD_REAL=$(cd "$JC_WD" && pwd -P)
# The fake answers `debug sessions` and `debug -S <id> client:state` from files,
# so each case controls exactly what the daemon claims.
cat > "$JC_FAKE" <<'EOF'
#!/usr/bin/env bash
[ "${JCODE_DEBUG_CONTROL:-}" = 1 ] || { echo "debug control off" >&2; exit 1; }
[ "$1" = debug ] || exit 1
case "$2" in
  sessions) cat "$FAKE_DIR/sessions" ;;
  -S) [ "$4" = client:state ] || exit 1; cat "$FAKE_DIR/state.$3" 2>/dev/null || { echo "Error: no client" ; } ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$JC_FAKE"
export FAKE_DIR="$TMP_ROOT/fake"
mkdir -p "$FAKE_DIR"
jc_probe() { FM_JCODE_BIN="$JC_FAKE" "$PROBE" "$JC_WD"; }
jc_sessions() {  # <session-id>...
  local id first=1
  printf '['
  for id in "$@"; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"session_id":"%s","working_dir":"%s","status":"ready","is_processing":false}' "$id" "$JC_WD_REAL"
  done
  printf ']'
}

jc_sessions session_a > "$FAKE_DIR/sessions"
printf '{"input":"","processing":false}' > "$FAKE_DIR/state.session_a"
[ "$(jc_probe)" = empty ] || fail "an empty client input must read empty"
printf '{"input":"   ","processing":false}' > "$FAKE_DIR/state.session_a"
[ "$(jc_probe)" = pending ] || fail "whitespace in the client input is a draft and must read pending"
printf '{"input":"\\nhidden","processing":false}' > "$FAKE_DIR/state.session_a"
[ "$(jc_probe)" = pending ] || fail "a blank-first-line draft must read pending"
pass "the structural read reports empty only for an empty input string"

printf '{"processing":false}' > "$FAKE_DIR/state.session_a"
[ "$(jc_probe)" = unknown ] || fail "a client state with no input field must read unknown"
printf 'Error: Session does not have a connected TUI client' > "$FAKE_DIR/state.session_a"
[ "$(jc_probe)" = unknown ] || fail "a session with no connected client must read unknown"
printf '{"input":"","processing":false}' > "$FAKE_DIR/state.session_a"
jc_sessions session_a session_b > "$FAKE_DIR/sessions"
[ "$(jc_probe)" = unknown ] || fail "two sessions in one working directory must read unknown, never guess"
printf '[]' > "$FAKE_DIR/sessions"
[ "$(jc_probe)" = unknown ] || fail "no session for the working directory must read unknown"
[ "$(FM_JCODE_BIN="$TMP_ROOT/absent" "$PROBE" "$JC_WD")" = unknown ] \
  || fail "a missing jcode executable must read unknown"
[ "$(FM_JCODE_BIN="$JC_FAKE" "$PROBE" "$TMP_ROOT/no-such-dir")" = unknown ] \
  || fail "an unreadable working directory must read unknown"
pass "every structural read the probe cannot prove reads unknown"

# --------------------------------------------------------- quota and detection
grep -qE "^[[:space:]]+jcode\)[[:space:]]+printf 'claude" "$ROOT/bin/fm-quota-axi-lib.sh" \
  || fail "jcode must share the claude quota family: it spends the same subscription windows"
pass "jcode shares the claude quota family"

grep -qE '^[[:space:]]+jcode\) echo "comm jcode"; return ;;' "$ROOT/bin/fm-harness.sh" \
  || fail "bin/fm-harness.sh must detect an anchored jcode process name"
pass "jcode is detected by its own anchored process name"

# ------------------------------------------------------------------- the bridge
BRIDGE="$ROOT/bin/fm-jcode-busy-bridge.sh"
[ -x "$BRIDGE" ] || fail "the jcode busy bridge must be executable"
WT="$TMP_ROOT/wt"; mkdir -p "$WT"
WT_REAL=$(cd "$WT" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SESS_FILE="$TMP_ROOT/sessions.json"
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
{
  echo '#!/usr/bin/env bash'
  echo '[ "${1:-}" = debug ] || exit 0'
  echo "cat '$SESS_FILE' 2>/dev/null || echo '[]'"
} > "$FAKEBIN/jcode"
chmod +x "$FAKEBIN/jcode"
PATH="$FAKEBIN:$PATH"; export PATH

S2="$TMP_ROOT/state2"; mkdir -p "$S2"
GEN2=$("$ROOT/bin/fm-busy-event.sh" arm "$S2" t2 --state idle --source fm-spawn --event launch-brief)

printf '[{"working_dir":"%s","is_processing":true,"status":"running"}]' "$WT_REAL" > "$SESS_FILE"
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'state=busy source=jcode-debug' "$S2/t2.busy-state" \
  || fail "the bridge must publish busy while is_processing is true"

printf '[{"working_dir":"%s","is_processing":false,"status":"ready"}]' "$WT_REAL" > "$SESS_FILE"
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'state=idle source=jcode-debug' "$S2/t2.busy-state" \
  || fail "the bridge must publish idle when is_processing goes false"
pass "the bridge maps is_processing onto busy and idle for the matching worktree"

SEQ_BEFORE=$(sed -n 's/.*seq=\([0-9]*\).*/\1/p' "$S2/t2.busy-state")
"$BRIDGE" "$S2" t2 --gen "$GEN2" --working-dir "$WT_REAL" --once >/dev/null 2>&1
SEQ_AFTER=$(sed -n 's/.*seq=\([0-9]*\).*/\1/p' "$S2/t2.busy-state")
[ "$SEQ_BEFORE" = "$SEQ_AFTER" ] \
  || fail "the bridge must publish only on transition, never once per poll"
pass "the bridge writes only on a state transition"

OTHER="$TMP_ROOT/other"; mkdir -p "$OTHER"
OTHER_REAL=$(cd "$OTHER" && pwd -P)
printf '[{"working_dir":"%s","is_processing":true,"status":"running"}]' "$OTHER_REAL" > "$SESS_FILE"
S3="$TMP_ROOT/state3"; mkdir -p "$S3"
GEN3=$("$ROOT/bin/fm-busy-event.sh" arm "$S3" t3 --state idle --source fm-spawn --event launch-brief)
"$BRIDGE" "$S3" t3 --gen "$GEN3" --working-dir "$WT_REAL" --once >/dev/null 2>&1
grep -q 'source=fm-spawn' "$S3/t3.busy-state" \
  || fail "a session in a DIFFERENT worktree must not drive this task state"
pass "the bridge attributes state only by matching working_dir"

# ------------------------------------------------------------ refusal behaviour
PRE="$ROOT/bin/fm-jcode-preflight.sh"
[ -x "$PRE" ] || fail "the jcode preflight must be executable"
if JCODE_HOME="$TMP_ROOT/empty-home" "$PRE" >/dev/null 2>&1; then
  fail "preflight must refuse a home whose onboarding has never been completed"
fi
pass "preflight refuses an un-onboarded jcode home rather than wedging a crewmate"

SEED="$ROOT/bin/fm-jcode-seed.sh"
[ -x "$SEED" ] || fail "the jcode seeder must be executable"
if "$SEED" tmux tgt "$WT_REAL" "$TMP_ROOT/no-such-brief.md" >/dev/null 2>&1; then
  fail "the seeder must refuse a missing brief"
fi
pass "the seeder refuses a missing brief rather than launching an uninstructed crewmate"

grep -q 'jcode is a verified crewmate/scout adapter only' "$ROOT/bin/fm-spawn.sh" \
  || fail "fm-spawn must refuse a jcode secondmate at launch"
pass "fm-spawn refuses a jcode secondmate"

grep -q 'stop_jcode_bridge' "$ROOT/bin/fm-teardown.sh" \
  || fail "teardown must stop the jcode bridge or it outlives the task"
pass "teardown stops the jcode bridge"




# ------------------------------------------------ jcode as a PRIMARY harness
# A primary is not spawned by fm-spawn: the captain types it in the pane. What
# it needs is a verified supervision protocol, or it falls back to the generic
# unknown contract and a bounded foreground wait instead of a background arm.

SUPI="$ROOT/bin/fm-supervision-instructions.sh"
[ -x "$SUPI" ] || fail "fm-supervision-instructions.sh must be executable"

JC_SNIPPET="$ROOT/docs/supervision-protocols/jcode.md"
[ -f "$JC_SNIPPET" ] || fail "jcode needs its own supervision protocol snippet"
pass "jcode has a supervision protocol snippet"

JC_RENDER=$("$SUPI" --harness jcode 2>&1)
case "$JC_RENDER" in
  *"Mode: jcode background-notify supervision."*) ;;
  *) fail "jcode must render its OWN supervision mode, not the unknown fallback" ;;
esac
case "$JC_RENDER" in
  *"Unknown harness fallback"*)
    fail "jcode must not fall through to the unknown harness contract" ;;
esac
pass "jcode renders its own supervision mode rather than the unknown fallback"

# wake: true is the whole protocol. Verified on v0.84.0 that jcode's wake field
# carries no default and a prose instruction produced wake=false with no wake
# ever firing, so the snippet must prescribe it literally.
case "$JC_RENDER" in
  *"run_in_background: true"*) ;;
  *) fail "the jcode arm must prescribe run_in_background: true" ;;
esac
case "$JC_RENDER" in
  *"wake: true"*) ;;
  *) fail "the jcode arm must prescribe wake: true explicitly" ;;
esac
case "$JC_RENDER" in
  *"LOAD-BEARING"*) ;;
  *) fail "the snippet must state why wake: true cannot be omitted" ;;
esac
pass "the jcode arm prescribes run_in_background and an explicit wake: true"

case "$JC_RENDER" in
  *"bin/fm-watch-arm.sh"*) ;;
  *) fail "jcode must arm the background watcher, not a foreground wait" ;;
esac
case "$JC_RENDER" in
  *"Never use shell \`&\`"*) ;;
  *) fail "the jcode protocol must forbid shell & for supervision" ;;
esac
pass "jcode arms bin/fm-watch-arm.sh as a tracked background task, never shell &"

JC_REPAIR=$("$SUPI" --harness jcode --repair-line 2>&1)
case "$JC_REPAIR" in
  *jcode*wake:\ true*) ;;
  *) fail "the jcode repair line must name the wake: true requirement: $JC_REPAIR" ;;
esac
pass "the jcode repair line names the wake: true requirement"

case "$JC_RENDER" in
  *"Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh jcode background bash task"*) ;;
  *) fail "jcode needs its own ordinary-wake line; the generic one arms nothing" ;;
esac
pass "jcode has its own ordinary-wake line"

# Registering jcode must not have disturbed any other primary.
for h in claude codex opencode pi grok cursor omp; do
  m=$("$SUPI" --harness "$h" 2>&1 | grep -m1 '^Mode:')
  case "$m" in
    *"Unknown harness fallback"*) fail "$h lost its supervision snippet" ;;
    "") fail "$h rendered no supervision mode" ;;
  esac
done
for h in muse rovo gemini bogus; do
  m=$("$SUPI" --harness "$h" 2>&1 | grep -m1 '^Mode:')
  case "$m" in
    *"Unknown harness fallback"*) ;;
    *) fail "$h must still fall back to the unknown contract, got: $m" ;;
  esac
done
pass "every other harness keeps its own protocol, and unverified ones still fall back"

# ------------------------------------------------- firstmate owns dispatch
# jcode can spawn and coordinate its OWN swarm workers, queue future runs
# (schedule / initiative), and run unattended (ambient). Every one of those
# produces agents with no task record, no worktree, and no supervision, so the
# adapter must make them unreachable and REFUSE rather than quietly repair.

grep -qE 'jcode" then \(\["none","minimal","low","medium","high","xhigh","max"\]' "$ROOT/bin/fm-bootstrap.sh" \
  || fail "jcode's effort set must not offer swarm levels: they hand dispatch to jcode"
if grep -qE 'jcode".*swarm' "$ROOT/bin/fm-bootstrap.sh"; then
  fail "swarm efforts must not be selectable for a jcode crewmate"
fi
pass "jcode's dispatch-profile effort axis offers no swarm level"

JC_TH="$TMP_ROOT/dispatch-home"
mkdir -p "$JC_TH"
printf '{"launch_count":5}\n' > "$JC_TH/setup_hints.json"
printf '{"account":"fake"}\n' > "$JC_TH/auth.json"

write_jcode_cfg() {  # <swarm> <disabled-list> <ambient>
  printf '[display]\ndebug_socket = true\n\n[features]\nswarm = %s\n\n[tools]\ndisabled = %s\n\n[ambient]\nenabled = %s\n' \
    "$1" "$2" "$3" > "$JC_TH/config.toml"
}
DENIED='["swarm", "schedule", "initiative"]'

write_jcode_cfg true "$DENIED" false
if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
  fail "preflight must refuse a spawn while [features] swarm = true"
fi
pass "preflight refuses a jcode spawn while swarm is enabled"

for denied_tool in swarm schedule initiative; do
  write_jcode_cfg false '[]' false
  if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
    fail "preflight must refuse when [tools] disabled does not deny $denied_tool"
  fi
done
pass "preflight refuses unless swarm, schedule and initiative are all denied tools"

write_jcode_cfg false "$DENIED" true
if JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1; then
  fail "preflight must refuse while [ambient] enabled = true: it runs turns outside dispatch"
fi
pass "preflight refuses a jcode spawn while ambient mode is enabled"

write_jcode_cfg false "$DENIED" false
JCODE_HOME="$JC_TH" "$ROOT/bin/fm-jcode-preflight.sh" >/dev/null 2>&1 \
  || fail "preflight must accept a home where firstmate owns dispatch"
pass "preflight accepts a home where firstmate owns dispatch"

if "$ROOT/bin/fm-jcode-seed.sh" tmux tgt "$WT_REAL" "$TMP_ROOT/nope.md" --effort swarm >/dev/null 2>&1; then
  fail "the seeder must refuse a swarm effort"
fi
grep -q 'firstmate owns dispatch' "$ROOT/bin/fm-jcode-seed.sh" \
  || fail "the seeder must state why swarm efforts are refused"
pass "the seeder refuses swarm efforts and says why"

# ============================================================================
# END-TO-END: the REAL bin/fm-spawn.sh against a fake tmux pane and a stateful
# fake jcode, so the launch shape, the preflight gate, the typed brief, and the
# busy arming are all exercised together with no live harness session.
# ============================================================================

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# A fake jcode whose `debug sessions` answer FLIPS: it reports a ready session
# until the brief is typed, then reports one that is processing. That is exactly
# the sequence bin/fm-jcode-seed.sh depends on - wait for ready, type, then
# require is_processing as proof the brief actually started a turn - so a seeder
# that skipped either half would fail here.
write_fake_jcode() {  # <fakebin> <wd-file> <marker>
  local fakebin=$1 wdfile=$2 marker=$3
  # shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
  {
    echo '#!/usr/bin/env bash'
    echo 'if [ "${1:-}" != debug ]; then exit 0; fi'
    echo "wd=\$(cat '$wdfile' 2>/dev/null || true)"
    echo 'if [ -z "$wd" ]; then echo "[]"; exit 0; fi'
    echo "if [ -f '$marker' ]; then proc=true; st=running; else proc=false; st=ready; fi"
    echo 'printf "[{\"working_dir\":\"%s\",\"is_processing\":%s,\"status\":\"%s\",\"session_id\":\"s1\"}]" "$wd" "$proc" "$st"'
  } > "$fakebin/jcode"
  chmod +x "$fakebin/jcode"
}

# The tmux wrapper drops the marker when the BRIEF is typed - matched on the
# operational-input prefix every firstmate brief carries - standing in for the
# turn the composer would start. Matching a bare `send-keys -l` instead fired
# on the LAUNCH COMMAND itself, so the fake reported a busy session before the
# seeder had even polled for a ready one. It deliberately does NOT try to learn
# the worktree from `new-window -c`: fm-spawn issues several -c calls (the
# project dir among them) and the LAST one is not the task worktree, so reading
# it there captured the wrong directory. fm-spawn passes the task worktree to
# the seeder directly, and the fixture seeds that same path.
wrap_fake_tmux_marker() {  # <fakebin> <marker>
  local fakebin=$1 marker=$2 inner
  inner="$fakebin/tmux-inner"
  mv "$fakebin/tmux" "$inner"
  # shellcheck disable=SC2016  # single quotes are deliberate: these lines are the GENERATED script body, expanded by the fake when it runs, not here.
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '  case "$a" in'
    echo "    *FIRSTMATE_OP*) : > '$marker' ;;"
    echo '  esac'
    echo 'done'
    echo "exec '$inner' \"\$@\""
  } > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
}

seed_fake_jcode_home() {  # <spawn-home-dir>
  local jh="$1/.jcode"
  mkdir -p "$jh"
  printf '{"launch_count":7}
' > "$jh/setup_hints.json"
  printf '{"anthropic_accounts":[{"label":"fake"}]}
' > "$jh/auth.json"
  # A home firstmate will actually accept: debug control on for the busy bridge,
  # and dispatch owned by firstmate - swarm off, the spawning tools denied, and
  # ambient off. Preflight refuses anything less, which is the point.
  {
    printf '[display]
debug_socket = true

'
    printf '[features]
swarm = false

'
    printf '[tools]
disabled = ["swarm", "schedule", "initiative"]

'
    printf '[ambient]
enabled = false
'
  } > "$jh/config.toml"
}

e2e_case() {  # <name> <id> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR MARKER
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  MARKER="$CASE_DIR/typed.marker"
  WDFILE="$CASE_DIR/wd.txt"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake" claude pi)
  fm_test_spawn_home "$HOME_DIR" jcode
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  seed_fake_jcode_home "$HOME_DIR/user-home"
  # Seed the worktree the seeder will ask about. fm-spawn passes its task
  # worktree, which for this fixture is WT_DIR; the tmux -c capture in the
  # wrapper below overrides it if fm-spawn ever creates a different one.
  (cd "$WT_DIR" && pwd -P) > "$WDFILE"
  write_fake_jcode "$FAKEBIN_DIR" "$WDFILE" "$MARKER"
  wrap_fake_tmux_marker "$FAKEBIN_DIR" "$MARKER"
}

E2E_ID=jcode-e2e-1
e2e_case jcode-e2e "$E2E_ID"
LAUNCH_LOG="$CASE_DIR/launch.log"
: > "$LAUNCH_LOG"

E2E_OUT=$(GROK_HOME="$HOME_DIR/grok-home" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$E2E_ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
E2E_STATUS=$?

if [ "$E2E_STATUS" -ne 0 ]; then
  printf 'jcode e2e spawn output:\n%s\n' "$E2E_OUT" >&2
  fail "a real fm-spawn of a jcode ship must succeed"
fi
pass "a real fm-spawn of a jcode crewmate succeeds end to end"

# The log records every literal send: line 1 is the LAUNCH COMMAND, line 2 is
# the typed brief. They are asserted separately - checking the whole log for a
# brief path would match the pointer on line 2 and hide a positional on line 1.
E2E_LAUNCH=$(sed -n '1p' "$LAUNCH_LOG" 2>/dev/null || true)
E2E_TYPED=$(sed -n '2p' "$LAUNCH_LOG" 2>/dev/null || true)

case "$E2E_LAUNCH" in
  *jcode*) ;;
  *) fail "the launch command must invoke a resolved jcode binary: $E2E_LAUNCH" ;;
esac
case "$E2E_LAUNCH" in
  *"--provider claude"*) ;;
  *) fail "the launch must pin --provider claude to match the quota family: $E2E_LAUNCH" ;;
esac
case "$E2E_LAUNCH" in
  *"--no-update"*) ;;
  *) fail "the launch must pass --no-update so a crewmate cannot restart itself mid-task" ;;
esac
case "$E2E_LAUNCH" in
  *launch-brief*|*brief.md*|*FIRSTMATE_OP*)
    fail "jcode must NOT receive the brief on the command line; a positional parses as a subcommand: $E2E_LAUNCH" ;;
esac
pass "the jcode launch command is correctly shaped and carries no positional brief"

case "$E2E_TYPED" in
  *FIRSTMATE_OP*launch-brief*) ;;
  *) fail "the brief must be TYPED as an operational-input launch-brief: $E2E_TYPED" ;;
esac
case "$E2E_TYPED" in
  *launch-brief.md*) ;;
  *) fail "the typed pointer must name the brief file on disk: $E2E_TYPED" ;;
esac
pass "the brief is typed as an operational-input pointer at the on-disk brief"

E2E_STATE="$HOME_DIR/state"
[ -f "$E2E_STATE/$E2E_ID.busy-state" ] \
  || fail "a jcode spawn must arm the busy-state contract"
E2E_CLASS=$(fm_busy_classify tmux fake:w jcode "$E2E_ID" "$E2E_STATE")
case "$E2E_CLASS" in
  busy\ fm-spawn|busy\ jcode-debug|idle\ jcode-debug) ;;
  *) fail "a jcode spawn must leave a trusted busy record, got '$E2E_CLASS'" ;;
esac
pass "a jcode spawn arms the busy contract and classifies from a trusted source"

[ -f "$MARKER" ] || fail "the launch brief was never typed into the pane"
pass "the launch brief is typed into the crewmate pane"

echo "all fm-jcode-harness tests passed"
