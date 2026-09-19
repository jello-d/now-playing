#!/bin/sh
# daemon.t - the daemon's own MODEL logic, which every other test talks around:
# source arbitration, position interpolation, track-id bumping, cast capability
# derivation, and -- the one that matters most -- what happens when the MPRIS
# follower DIES. A dead follower used to leave the last track published forever
# with a fresh heartbeat, which is the single lie this design must not tell: a
# consumer is instructed to trust a fresh heartbeat, so frozen data behind one
# is worse than no data at all.
. "$(dirname "$0")/lib.sh"
harness_init daemon

command -v python3 >/dev/null 2>&1 || skip "python3 absent"

# --- unit: the model functions, imported directly -------------------------
XDG_RUNTIME_DIR=$T python3 - "$HERE" <<'EOF' || fail "model assertions failed"
import importlib.util, sys, time
from importlib.machinery import SourceFileLoader
here = sys.argv[1]
sys.path.insert(0, here + "/libexec")
# The daemon has no .py extension, so it needs an explicit source loader.
ldr = SourceFileLoader("npd", here + "/libexec/now-playing")
d = importlib.util.module_from_spec(importlib.util.spec_from_loader("npd", ldr))
ldr.exec_module(d)                  # safe: main() is behind __main__
import npframe as F

def local(**kw):
    base = dict(status="playing", title="T", artist="A", album="B", art="",
                length=100.0, position=10.0, mono=time.monotonic(), caps=7)
    base.update(kw); return base

# LOCAL WINS whenever it has a track; cast fills the gap only when it does not.
d._local, d._cast = local(), local(title="C", device="TV")
m = d._merged_locked()
assert m["source"] == "local", m["source"]
d._local = None
m = d._merged_locked()
assert m["source"] == "cast" and m["device"] == "TV", m
d._cast = None
assert d._merged_locked() is None, "idle must be None, not a stub"
# A stopped local source is NOT a live one, even with a title present.
d._local = local(status="stopped")
assert d._merged_locked() is None, "stopped counted as live"

# INTERPOLATION happens here and nowhere else.
now = time.monotonic()
p = d._live_position(dict(status="playing", position=10.0, length=100.0,
                          mono=now - 2.0))
assert 11.9 < p < 12.2, p                      # advanced by ~2s
p = d._live_position(dict(status="paused", position=10.0, length=100.0,
                          mono=now - 2.0))
assert p == 10.0, p                            # paused does NOT advance
p = d._live_position(dict(status="playing", position=99.0, length=100.0,
                          mono=now - 60.0))
assert p == 100.0, p                           # clamped at the track length
p = d._live_position(dict(status="playing", position=5.0, length=0.0,
                          mono=now - 1.0))
assert p > 5.0, p                              # unknown length does not clamp

# CAST CAPS come from the device's own status, not from a guess.
class MS:
    def __init__(self, **kw): self.__dict__.update(kw)
caps = d._cast_caps(MS(supports_pause=True, supports_skip_forward=True,
                       supports_queue_prev=False, supports_seek=False))
assert caps & F.CAP_PAUSE and caps & F.CAP_NEXT, caps
assert not (caps & F.CAP_PREV), "prev set with no backward support"
assert not (caps & F.CAP_SEEK), "seek set with no seek support"
assert d._cast_caps(MS()) == 0, "absent flags must read as absent, not present"

# CAST CLASSIFICATION is THREE-way. The whole point is that "not a media
# receiver" and "not a media receiver YET" are different answers: a receiver
# publishes its namespaces asynchronously after launch, so a probe landing in
# that window sees a valid app id and no media namespace. Calling that a
# refusal is what let one early probe blind the daemon to a LIVE cast for a
# whole session (measured on manifold 2026-09-18).
class CS:
    def __init__(self, app_id=None, namespaces=None):
        self.app_id = app_id; self.namespaces = namespaces or []
MEDIA = d.MEDIA_NS
assert d._classify_cast(CS("CC1AD845", [MEDIA])) == d.CAST_MEDIA
assert d._classify_cast(CS("2DB7CC49", [MEDIA])) == d.CAST_MEDIA
# a genuine native app: never drive it, and it IS cacheable
assert d._classify_cast(CS("AndroidNativeApp", [MEDIA])) == d.CAST_NATIVE
# still launching: a valid id, namespaces not published yet -> RETRY, not a
# refusal. This is the case the old two-way gate got wrong.
assert d._classify_cast(CS("CC1AD845", [])) == d.CAST_PENDING
assert d._classify_cast(CS("CC1AD845", ["urn:x-cast:com.google.cast.tp"])) \
    == d.CAST_PENDING
# nothing running at all is also inconclusive, never a refusal
assert d._classify_cast(CS(None, [])) == d.CAST_PENDING
assert d._classify_cast(CS("", [MEDIA])) == d.CAST_PENDING
# the strict boolean still means exactly what its callers think it means
assert d._is_cast_media(CS("CC1AD845", [MEDIA])) is True
assert d._is_cast_media(CS("CC1AD845", [])) is False
assert d._is_cast_media(CS("AndroidNativeApp", [MEDIA])) is False
# and the negative cache must be BOUNDED, or one bad probe is forever
assert d.NOTCAST_TTL > 0, "negative probe cache must expire"

# THE BLACKLIST POLICY is the half that actually broke. Classifying correctly
# is useless if the caller still remembers an inconclusive answer.
assert d._notcast_entry(d.CAST_PENDING, "YouTube Music", 100.0) is None, \
    "a still-launching receiver must NOT be blacklisted (this was the bug)"
assert d._notcast_entry(d.CAST_MEDIA, "YouTube Music", 100.0) is None, \
    "a live media receiver must never be blacklisted"
e = d._notcast_entry(d.CAST_NATIVE, "HBO Max", 100.0)
assert e is not None and e[0] == "HBO Max", e
assert e[1] == 100.0 + d.NOTCAST_TTL, "native entry must carry a DEADLINE"

# TRACK ID bumps on a track change and holds otherwise -- it is what a view
# uses to restart a marquee, so a spurious bump is a visible glitch.
d._frame = F.Writer()
d._local, d._cast, d._art_now = local(), None, ""
d._frame_publish()
r = F.Reader(); first = r.read()["track_id"]
d._frame_publish()
assert r.read()["track_id"] == first, "track_id bumped without a track change"
d._local = local(title="OTHER")
d._frame_publish()
assert r.read()["track_id"] == first + 1, "track_id did not bump on a new track"

# NO SOURCE publishes a complete IDLE frame, not a stale one.
d._local = None
d._frame_publish()
f = r.read()
assert f["status"] == "idle" and f["title"] == "", f
EOF

# --- integration: a follower that DIES must not leave a phantom track -----
# A stub playerctl emits one metadata line and exits, standing in for a
# playerctl killed by a D-Bus restart or a crash.
mkdir -p "$T/stub"
cat > "$T/stub/playerctl" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = position ] && { echo 12.0; exit 0; }; done
case " \$* " in
  # Count FOLLOWER runs only: the position poll also calls playerctl, and
  # lumping them together would let a single-shot follower look restarted.
  *--follow*) echo run >> "$T/runs"
              printf 'playing\037Band\037Song\037Album\037\03760000000\n'
              exit 0 ;;                 # ONE line, then die
esac
exit 0
EOF
chmod +x "$T/stub/playerctl"

env -i PATH="$T/stub:/usr/bin:/bin" HOME="$T" XDG_RUNTIME_DIR="$T" \
  XDG_CONFIG_HOME="$T/cfg" python3 "$HERE/libexec/now-playing" \
  >/dev/null 2>"$T/daemon.err" &
DPID=$!
sleep 4                        # first run, its death, and a restart or two
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null

runs=$(wc -l < "$T/runs" 2>/dev/null || echo 0)
[ "$runs" -ge 2 ] || fail "follower not restarted after it exited (runs=$runs)"
grep -q 'follower exited' "$T/daemon.err" \
  || fail "the follower's death was not reported: $(cat "$T/daemon.err")"

# The decisive assertion: the LAST published frame must be idle, not the track
# the dead follower last reported.
XDG_RUNTIME_DIR=$T python3 - "$HERE" <<'EOF' || fail "phantom track survived"
import sys; sys.path.insert(0, sys.argv[1] + "/libexec")
import npframe as F
f = F.Reader().read()
assert f is not None, "no frame at all"
assert f["status"] == "idle", \
    "a dead follower left %r published as %s" % (f["title"], f["status"])
assert f["title"] == "", "stale title %r survived the follower" % f["title"]
EOF

pass
