#!/usr/bin/env bash
# scale-driver.sh <code-root> <n-boards> <label>
# Arms N real worker-owned Lavish boards (fake lavish-axi CLI standing in for the
# review server) in a disposable FM_HOME, then times the real `fm-procevent.sh reconcile`.
set -u
CODE=$1; N=$2; LABEL=$3
WT=/Users/elliotttong/.no-mistakes/worktrees/77b84f82a564/01M645MVA7K3V8C6S6MHS1NPJC
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-scale.XXXXXX"); W=$(cd -P "$W" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$W/claims" LAVISH_AXI_STATE_DIR="$W/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR" "$W/home/state" "$W/fakebin"
H="$W/home"
cat > "$W/fakebin/lavish-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/lavish-calls"
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","board note","","message",""\n'
SH
chmod +x "$W/fakebin/lavish-axi"
lavish_session() {
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV; my $real = realpath($artifact);
    my $key = substr(sha256_hex($real), 0, 16); my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = { key => $key, file => decode("UTF-8", $real), status => "open", url => $url };
    open my $out, ">", $path or die $!; print $out encode_json($state);' \
    "$LAVISH_AXI_STATE_DIR/state.json" "$1" "http://127.0.0.1:14387/session/0123456789abcdef"
}
for n in $(seq 1 "$N"); do
  printf '<h1>board %s</h1>\n' "$n" > "$W/board-$n.html"; lavish_session "$W/board-$n.html"
  printf 'window=fmtest:fm-t%s\nworktree=%s/wt-%s\nproject=fmtest\n' "$n" "$H" "$n" > "$H/state/t$n.meta"
  PATH="$W/fakebin:$PATH" FM_HOME="$H" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 \
    "$CODE/bin/fm-procevent-lavish.sh" arm "$W/board-$n.html" --for "t$n" >/dev/null || echo "arm $n failed"
done
for n in $(seq 1 "$N"); do
  for _ in $(seq 1 200); do [ -s "$H/state/t$n.inbox/001.msg" ] && break; sleep 0.1; done
done
for _ in $(seq 1 200); do ls "$FM_PROCEVENT_CLAIM_ROOT"/*.claim >/dev/null 2>&1 || break; sleep 0.1; done
delivered=$(ls "$H/state/t"*.inbox/001.msg 2>/dev/null | wc -l | tr -d ' ')
mkdir -p "$W/aroot/bin"
cat > "$W/aroot/bin/fm-procevent-lavish.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${1-}" >> "$W/adapter-calls"
exec "$CODE/bin/fm-procevent-lavish.sh" "\$@"
SH
chmod +x "$W/aroot/bin/fm-procevent-lavish.sh"
echo "[$LABEL] boards=$N delivered-to-worker-inbox=$delivered"
for pass in 1 2; do
  : > "$W/adapter-calls"; : > "$W/lavish-calls"
  s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  out=$(env -u FM_ROOT_OVERRIDE PATH="$W/fakebin:$PATH" FM_ROOT_OVERRIDE="$W/aroot" FM_HOME="$H" "$CODE/bin/fm-procevent.sh" reconcile 2>&1)
  e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  v=$(grep -cE '^(terminal|silent)$' "$W/adapter-calls" || true)
  echo "[$LABEL] reconcile pass $pass: $(perl -e "printf '%.2f', $e-$s")s  adapter terminal/silent verdicts=$v  out: $out"
done
msgs=$(find "$H/state" -path '*t*.inbox*' -name '*.msg' | wc -l | tr -d ' ')
echo "[$LABEL] total worker inbox records after reconciles=$msgs (expected $N, no re-delivery)"
echo "$W" > "$W.path"; echo "WORKDIR=$W"
