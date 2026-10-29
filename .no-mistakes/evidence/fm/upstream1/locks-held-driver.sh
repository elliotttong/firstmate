#!/usr/bin/env bash
# locks-held-driver.sh <code-root> <workdir> <label>: hold every registered board's
# source lock from another process, then run the real reconcile and see if it completes.
CODE=$1; W=$2; LABEL=$3; H=$W/home
ROOT=/Users/elliotttong/.no-mistakes/worktrees/77b84f82a564/01M645MVA7K3V8C6S6MHS1NPJC
export FM_PROCEVENT_CLAIM_ROOT="$W/claims" LAVISH_AXI_STATE_DIR="$W/lavish-state"
for _ in $(seq 1 100); do ls "$FM_PROCEVENT_CLAIM_ROOT"/*.claim >/dev/null 2>&1 || break; sleep 0.1; done
REL="$W/release-locks"; pids=()
for s in $(find "$H/state/procevent" -name '*.source'); do
  id=${s##*/}; id=${id%.source}
  FM_HOME="$W/lockhome" "$EV_HOLDER" "$ROOT" "$id" "$REL" & pids+=($!)
done
sleep 1.5
echo "[$LABEL] boards whose source lock is held by another process: $(ls "$REL".*.ready 2>/dev/null | wc -l | tr -d ' ')"
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
PATH="$W/fakebin:$PATH" FM_HOME="$H" "$CODE/bin/fm-procevent.sh" reconcile > "$W/held.out" 2>&1 & r=$!
for _ in $(seq 1 150); do kill -0 $r 2>/dev/null || break; sleep 0.1; done
if kill -0 $r 2>/dev/null; then echo "[$LABEL] reconcile STILL BLOCKED after 15s behind busy source locks"
else echo "[$LABEL] reconcile finished in $(perl -MTime::HiRes=time -e "printf '%.2f', time-$s")s while locks held: $(cat "$W/held.out")"; fi
: > "$REL"; wait $r; wait "${pids[@]}"
echo "[$LABEL] after release: $(cat "$W/held.out")"
