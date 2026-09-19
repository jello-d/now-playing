#!/bin/sh
# cli.t - the command-line reader verbs (status / shm-info) and the config
# loader. These are the package's own reference CONSUMER, so they prove the
# frame contract is usable without building a renderer. The config assertions
# are the fail-loud ones: an unknown key and a malformed line must ABORT, not
# be quietly skipped, because a silently ignored tunable is found months later.
. "$(dirname "$0")/lib.sh"
harness_init cli

command -v python3 >/dev/null 2>&1 || skip "python3 absent"

NP="$HERE/libexec/now-playing"
mkdir -p "$T/cfg/now-playing"
run() { env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" python3 "$NP" "$@"; }

# A frame with no daemon behind it: every verb must cope, not crash.
out=$(run status 2>&1) && fail "status passed with no frame at all"
echo "$out" | grep -q unavailable || fail "no 'unavailable' report: $out"
run shm-info >/dev/null 2>&1 && fail "shm-info passed with no frame" || :

# Lay down a live frame, then assert the verbs read it.
XDG_RUNTIME_DIR=$T python3 - "$HERE" <<'EOF' || fail "could not write a frame"
import sys
sys.path.insert(0, sys.argv[1] + "/libexec")
import npframe as F
F.Writer().publish(status=F.STATUS_PLAYING, source=F.SOURCE_LOCAL,
                   position=30.0, length=240.0, caps=F.CAP_PAUSE | F.CAP_NEXT,
                   track_id=4, title="Song", artist="Band", album="Record")
EOF

out=$(run status) || fail "status failed on a live frame"
echo "$out" | grep -q '^status    playing' || fail "status wrong: $out"
echo "$out" | grep -q '^title     Song' || fail "title missing: $out"
echo "$out" | grep -q '^caps      pause next' || fail "caps wrong: $out"
echo "$out" | grep -q '^position  0:30 / 4:00' || fail "position wrong: $out"

run status --json | python3 -c '
import json, sys
f = json.load(sys.stdin)
for k in ("status", "title", "caps_names", "track_id", "live", "age", "bands"):
    assert k in f, "missing key " + k
assert f["status"] == "playing", f["status"]
assert f["caps_names"] == ["pause", "next"], f["caps_names"]
assert f["live"] is True
' || fail "status --json shape is wrong"

out=$(run shm-info) || fail "shm-info failed on a live frame"
echo "$out" | grep -q '^live                True' || fail "not live: $out"
echo "$out" | grep -q '^version             1' || fail "version wrong: $out"
run shm-info --json | python3 -c '
import json, sys
i = json.load(sys.stdin)
assert i["present"] and i["live"], i
assert i["version"] == i["understands_version"], i
assert i["path"].endswith("/now-playing.frame"), i["path"]
' || fail "shm-info --json shape is wrong"

# --follow --interval streams at a cadence (and survives its reader leaving).
n=$(run status --follow --interval 0.05 2>/dev/null | head -3 | wc -l)
[ "$n" -eq 3 ] || fail "--follow --interval did not stream (got $n lines)"

# A STALE frame is not a live one: the daemon is gone, so report and exit 1.
XDG_RUNTIME_DIR=$T python3 - "$HERE" <<'EOF' || fail "could not age the frame"
import struct, sys, time
sys.path.insert(0, sys.argv[1] + "/libexec")
import npframe as F
w = F.Writer(); w.publish(status=F.STATUS_PLAYING, title="Song")
struct.pack_into("<Q", w._mm, F.O_HEARTBEAT,
                 time.monotonic_ns() - int(10e9))     # 10s old
EOF
out=$(run status 2>&1) && fail "status called a 10s-old frame live"
echo "$out" | grep -q unavailable || fail "stale frame not reported: $out"

# Unknown options abort rather than being ignored.
run status --bogus >/dev/null 2>&1 && fail "status took an unknown option" || :
run shm-info --bogus >/dev/null 2>&1 && fail "shm-info took an option" || :
run bogus-verb >/dev/null 2>&1 && fail "took an unknown verb" || :

# Config: an unknown key and a malformed line are LOUD, and the message names
# the offending key so it is actionable.
printf 'players=a,b\nbogus_key=1\n' > "$T/cfg/now-playing/config"
out=$(timeout 5 env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" \
  python3 "$NP" 2>&1) && fail "daemon started with an unknown config key"
echo "$out" | grep -q "unknown key 'bogus_key'" || fail "bad message: $out"

# The spectrum keys are LIVE now that the analyser is daemon-side, so they must
# NOT read as unknown -- that was the deliberate refusal before the move, and a
# stale refusal would be just as wrong as a silent accept.
printf 'spectrum=off\nbands=24\ntilt=3.5\n' > "$T/cfg/now-playing/config"
out=$(timeout 3 env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" \
  python3 "$NP" 2>&1 || :)
echo "$out" | grep -q "unknown key" && fail "spectrum keys still refused: $out" || :

# ...but an out-of-range DSP value is refused LOUDLY and names the key. Clamping
# would silently redefine what was asked for.
cfg_fails() {   # <config line> <expected message fragment>
  printf '%s\n' "$1" > "$T/cfg/now-playing/config"
  out=$(timeout 5 env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" \
    python3 "$NP" 2>&1) && fail "accepted bad config: $1"
  echo "$out" | grep -q "$2" || fail "bad message for '$1': $out"
}
cfg_fails 'spectrum=maybe' "must be 'on' or 'off'"
cfg_fails 'bands=999'      'bands must be 1\.\.64'
cfg_fails 'fft=1000'       'power of two'
cfg_fails 'fmin=900
fmax=400'                  'fmin < fmax'
cfg_fails 'attack=0'       'attack must be in'

printf 'players\n' > "$T/cfg/now-playing/config"
out=$(timeout 5 env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" \
  python3 "$NP" 2>&1) && fail "daemon started on a malformed config line"
echo "$out" | grep -q 'not KEY=VALUE' || fail "bad message: $out"

printf 'publish_hz=0\n' > "$T/cfg/now-playing/config"
timeout 5 env XDG_RUNTIME_DIR="$T" XDG_CONFIG_HOME="$T/cfg" \
  python3 "$NP" >/dev/null 2>&1 && fail "accepted publish_hz=0" || :

pass
