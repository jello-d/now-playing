#!/bin/sh
# spectrum.t - the DAEMON-SIDE DSP (libexec/npspectrum_lib.py).
#
# The analyser was a PORT of waybar-mods overlays/spectrum.hpp, and the whole
# requirement was that a user's existing tuning survive the move: same
# log-spaced edges, same tilt, same dB window, same asymmetric attack/decay.
# That claim went unverified for eleven days. Nothing here needs an audio device
# or a human, because _process() takes samples, so a synthetic sine proves the
# transform.
#
# Deliberately NOT asserted: that high frequencies read HIGHER than low ones.
# The tilt does lift highs, but log-spaced bands get WIDER with frequency and
# the per-band value is a mean over bins, so a pure tone in a wide band reads
# LOWER. Measured: 200 Hz -> 1.000, 1 kHz -> 0.919, 5 kHz -> 0.734 at one
# amplitude. Asserting the intuition instead of the measurement would have
# failed honestly.
. "$(dirname "$0")/harness_lib"
harness_init spectrum

command -v python3 >/dev/null 2>&1 || skip "python3 absent"
python3 -c 'import numpy' 2>/dev/null || skip "numpy absent"

python3 - "$HERE" <<'EOF' || fail "DSP assertions failed"
import sys
sys.path.insert(0, sys.argv[1] + "/libexec")
import numpy as np
import npspectrum_lib as NS

CFG = dict(bands=24, fft=4096, rate=44100.0, fmin=45.0, fmax=16000.0, gain=2.0,
           floor_db=-60.0, tilt=3.5, attack=0.65, decay=0.16)
N, R = CFG["fft"], CFG["rate"]


def tone(freq, amp, hops):
    """Enough samples for `hops` 50%-overlap FFT hops."""
    t = np.arange(int(N * (hops + 1) / 2)) / R
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def fed(freq, amp, hops):
    sp = NS.Spectrum(CFG)
    sp._process(tone(freq, amp, hops))
    return sp.read()


# CONSTRUCTION MUST NOT CAPTURE. The split exists so this file drives the real
# initialisation without opening an audio device; if a thread creeps back into
# __init__, every test below starts racing a live capture.
sp = NS.Spectrum(CFG)
assert sp._thread is None, "__init__ started the capture thread"
assert len(sp.read()) == CFG["bands"], len(sp.read())

# --- BAND MAPPING: a pure tone lights the band that contains it -------------
ratio = CFG["fmax"] / CFG["fmin"]
for freq in (200.0, 1000.0, 5000.0):
    want = int(np.floor(np.log(freq / CFG["fmin"]) / np.log(ratio)
                        * CFG["bands"]))
    b = fed(freq, 0.5, 8)
    got = int(np.argmax(b))
    assert got == want, "%.0f Hz peaked in band %d, expected %d" % (freq, got,
                                                                    want)
    far = [v for i, v in enumerate(b) if abs(i - got) > 1]
    assert max(far) < 0.01, \
        "%.0f Hz leaked into distant bands (max %.4f)" % (freq, max(far))

# --- AMPLITUDE: monotonic, clamped at 1.0, silent below the floor -----------
vals = [max(fed(1000.0, a, 40)) for a in (0.002, 0.02, 0.2, 0.9)]
assert all(x <= y + 1e-9 for x, y in zip(vals, vals[1:])), \
    "band level not monotonic in amplitude: %s" % vals
assert vals[-1] == 1.0, "a loud tone did not clamp at 1.0 (got %r)" % vals[-1]
assert max(fed(1000.0, 1e-6, 40)) == 0.0, "signal under floor_db was not zero"

# --- SMOOTHING: the asymmetry is the point, and it is exact -----------------
target = max(fed(1000.0, 0.2, 40))
assert 0.0 < target < 1.0, target

one = max(fed(1000.0, 0.2, 1))
assert abs(one - target * CFG["attack"]) < 1e-4, \
    "one rising hop gave %.5f, expected target*attack %.5f" % (
        one, target * CFG["attack"])

sp = NS.Spectrum(CFG)
sp._process(tone(1000.0, 0.2, 40))
before = max(sp.read())
sp._acc = np.zeros(0, dtype=np.float32)      # drop the overlap tail
sp._process(np.zeros(N, dtype=np.float32))
after = max(sp.read())
assert abs(after - before * (1 - CFG["decay"])) < 1e-4, \
    "one falling hop gave %.5f, expected target*(1-decay) %.5f" % (
        after, before * (1 - CFG["decay"]))
assert one > (before - after), \
    "attack is not faster than decay (rise %.4f, fall %.4f)" % (
        one, before - after)

# --- SILENCE settles to zero, and never below it ----------------------------
# This is the ONLY expression of silence now: the active-rms gate was removed
# because blanking the band array makes a consumer fall back to its own DSP.
sp._process(np.zeros(N * 60, dtype=np.float32))
q = sp.read()
assert max(q) < 0.01, "silence did not settle (max %.4f)" % max(q)
assert min(q) >= 0.0, "a band went negative: %r" % min(q)

# --- BAND EDGES: ascending, inside the spectrum, none empty -----------------
sp = NS.Spectrum(CFG)
half = CFG["fft"] // 2
assert sp._lo[0] >= 1 and sp._hi[-1] <= half, "bins outside the spectrum"
assert all(sp._lo[i] < sp._hi[i] for i in range(CFG["bands"])), "empty band"
assert all(sp._lo[i] <= sp._lo[i + 1] for i in range(CFG["bands"] - 1)), \
    "band edges not ascending"
# the tilt crosses zero at the geometric-mean pivot: lows trimmed, highs lifted
assert sp._tiltdb[0] < 0 < sp._tiltdb[-1], "tilt does not straddle the pivot"
pivot = (CFG["fmin"] * CFG["fmax"]) ** 0.5
f0 = CFG["fmin"] * ratio ** (0 / CFG["bands"])
f1 = CFG["fmin"] * ratio ** (1 / CFG["bands"])
want0 = CFG["tilt"] * np.log2(((f0 * f1) ** 0.5) / pivot)
assert abs(sp._tiltdb[0] - want0) < 1e-9, "tilt formula drifted"

# --- A NARROWER CONFIG still works (the knobs are real) --------------------
narrow = dict(CFG, bands=8, fft=1024, fmin=100.0, fmax=8000.0)
sp2 = NS.Spectrum(narrow)
assert len(sp2.read()) == 8
sp2._process(tone(1000.0, 0.5, 8).astype(np.float32))
assert max(sp2.read()) > 0.0, "a non-default config produced no signal"
EOF

pass
