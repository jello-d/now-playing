#!/bin/sh
# frame.t - the shared-memory frame contract (libexec/npframe.py). Covers the
# roundtrip and, more importantly, the FAILURE modes docs/contract.md commits
# to: a bounded seqlock retry (so a daemon killed mid-write cannot make a
# reader spin forever), version mismatch as a loud error rather than a
# best-effort parse, staleness, bounded string truncation on a codepoint
# boundary, and a restart continuing the counter past an odd leftover.
. "$(dirname "$0")/lib.sh"
harness_init frame

command -v python3 >/dev/null 2>&1 || skip "python3 absent"

XDG_RUNTIME_DIR=$T python3 - "$HERE" <<'EOF' || fail "frame assertions failed"
import struct, sys, time
sys.path.insert(0, sys.argv[1] + "/libexec")
import npframe as F

w = F.Writer()

# --- roundtrip: every field survives, exactly -----------------------------
w.publish(status=F.STATUS_PAUSED, source=F.SOURCE_CAST, position=61.25,
          length=183.5, rate=1.25, caps=F.CAP_PAUSE | F.CAP_SEEK, track_id=9,
          title="Title", artist="Artist", album="Album", device="Living Room",
          art="/tmp/cover.png", bands=[0.0, 0.25, 1.0], flags=F.FLAG_SPECTRUM)
r = F.Reader()
f = r.read()
assert f is not None, "no coherent frame"
assert f["status"] == "paused", f["status"]
assert f["source"] == "cast", f["source"]
assert abs(f["position"] - 61.25) < 1e-12, f["position"]
assert abs(f["length"] - 183.5) < 1e-12, f["length"]
assert abs(f["rate"] - 1.25) < 1e-12, f["rate"]
assert f["caps_names"] == ["pause", "seek"], f["caps_names"]
assert f["track_id"] == 9, f["track_id"]
assert f["device"] == "Living Room", f["device"]
assert f["art"] == "/tmp/cover.png", f["art"]
assert f["spectrum_enabled"] is True
assert [round(b, 3) for b in f["bands"]] == [0.0, 0.25, 1.0], f["bands"]

# --- strings: bounded, NUL-terminated, never a split codepoint -------------
w.publish(title="A" * 5000, artist="e" + "é" * 400)
f = r.read()
assert len(f["title"].encode()) <= F.N_TITLE - 1, len(f["title"])
assert f["title"] == "A" * (F.N_TITLE - 1), "title not truncated to the slot"
a = f["artist"]
assert a.encode("utf-8").decode("utf-8") == a, "artist split a codepoint"
assert len(a.encode()) <= F.N_ARTIST - 1, len(a.encode())

# --- bands clamp to the slot, never overrun --------------------------------
w.publish(bands=[0.5] * (F.MAX_BANDS + 40))
f = r.read()
assert len(f["bands"]) == F.MAX_BANDS, len(f["bands"])

# --- a write left in flight is refused, and the retry is BOUNDED -----------
# A daemon SIGKILLed between the two counter stores leaves the counter odd for
# good; an unbounded reader would spin on it forever.
w.publish(title="wedged")
struct.pack_into("<I", w._mm, F.O_SEQ, 7)          # odd: write in flight
t0 = time.monotonic()
assert r.read() is None, "accepted a frame mid-write"
assert time.monotonic() - t0 < 1.0, "unbounded retry (it spun)"

# --- a restart continues PAST an odd leftover, landing even ---------------
w2 = F.Writer()
seq = struct.unpack_from("<I", w2._mm, F.O_SEQ)[0]
assert seq % 2 == 0, "restart left the counter odd (%d)" % seq
assert seq > 7, "restart reused a counter a reader may have seen (%d)" % seq
assert r.read() is not None, "no coherent frame after restart"

# --- an unreadable layout is LOUD, never a best-effort parse --------------
struct.pack_into("<I", w2._mm, F.O_VERSION, F.VERSION + 1)
try:
    r.read()
    raise AssertionError("parsed an unknown layout version")
except F.FrameVersionError:
    pass
# peek_header must still REPORT it: that is shm-info's whole job.
assert F.peek_header()[1] == F.VERSION + 1, "peek_header hid the mismatch"
struct.pack_into("<I", w2._mm, F.O_VERSION, F.VERSION)

# --- staleness is decided from the heartbeat, not from a guess ------------
f = r.read()
assert F.is_live(f), "a fresh frame read as stale"
old = dict(f)
old["heartbeat_ns"] = time.monotonic_ns() - int(3.0 * 1e9)
assert not F.is_live(old), "a 3s-old frame read as live"
assert F.age_secs(old) >= 3.0, F.age_secs(old)
assert F.age_secs(None) == float("inf")
EOF

pass
