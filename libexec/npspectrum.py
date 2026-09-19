"""npspectrum - the audio analyser, daemon-side.

MOVED HERE FROM THE VIEW. This logic used to live in waybar-mods'
overlays/spectrum.hpp: 231 lines of PulseAudio capture, FFT, banding and
smoothing inside a RENDERER. That was the one concentrated violation of the
contract (docs/contract.md): a view does not acquire signal, and it certainly
does not own audio routing. The bands ride the frame now, so every consumer
gets them for free and none of them needs to know where audio comes from.

The DSP is a deliberate PORT, not a redesign: same log-spaced band edges, same
per-band tilt, same dB window, same asymmetric attack/decay smoothing. A user's
tuning should survive the move, so the numbers must come out the same.

LOCAL ONLY, by design. A Chromecast decodes on the device, so there is no local
PCM to analyse while casting and the honest answer is NO BANDS AT ALL
(band_count 0, which the contract already defines). Measured on 2026-09-18: the
daemon's published position leads the actual acoustic output by +1.7 s on
YouTube Music and +8.0 s on the Default Media Receiver, so even a reconstructed
cast spectrum could not be synced from position without a per-path delay. This
never fakes a signal.

Capture is `parecord` on the default sink's monitor: ONE long-lived subprocess
for the life of the stream, not a per-sample spawn, reopened only when the
default sink actually changes.
"""
import os
import subprocess
import threading
import time

import numpy as np

BLOCK_HOP = 2                   # read half an FFT at a time (50% overlap)
MONITOR_POLL = 2.0              # how often to notice the default sink moving


def default_monitor():
    """The default sink's monitor source, or "" when it cannot be resolved.
    Resolved by NAME each time rather than cached, so a sink switch is picked
    up; @DEFAULT_MONITOR@ is not used because we need to SEE the change to
    know a reopen is due."""
    try:
        out = subprocess.run(["pactl", "get-default-sink"],
                             capture_output=True, text=True, timeout=2)
        name = (out.stdout or "").strip()
        return name + ".monitor" if name else ""
    except Exception:
        return ""


class Spectrum:
    """One capture thread publishing smoothed band levels 0..1.

    read() is the only thing the daemon touches, and it never blocks on the
    capture: the worker owns the PCM and hands over a copy under a lock."""

    def __init__(self, cfg):
        self.bands_n = max(1, min(int(cfg["bands"]), 64))
        self.fft = int(cfg["fft"])
        self.rate = float(cfg["rate"])
        self.fmin, self.fmax = float(cfg["fmin"]), float(cfg["fmax"])
        self.gain, self.floor_db = float(cfg["gain"]), float(cfg["floor_db"])
        self.tilt = float(cfg["tilt"])
        self.attack, self.decay = float(cfg["attack"]), float(cfg["decay"])
        self.active_rms = float(cfg["active_rms"])

        self._win = np.hanning(self.fft)
        self._acc = np.zeros(0, dtype=np.float32)
        self._bands = np.zeros(self.bands_n, dtype=np.float32)
        self._active = False
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._proc = None
        self._build_bands()
        self._thread = threading.Thread(target=self._capture_loop, daemon=True)
        self._thread.start()

    def _build_bands(self):
        """Log-spaced edges plus a per-band dB tilt, mirroring spectrum.hpp.
        The tilt lifts highs and trims lows about the geometric-mean pivot;
        without it music's bass-heavy energy pins the low bands and the highs
        never move."""
        half = self.fft // 2
        nyq = self.rate / 2.0
        pivot = (self.fmin * self.fmax) ** 0.5
        self._lo = np.empty(self.bands_n, dtype=int)
        self._hi = np.empty(self.bands_n, dtype=int)
        self._tiltdb = np.empty(self.bands_n)
        ratio = self.fmax / self.fmin
        for b in range(self.bands_n):
            f0 = self.fmin * ratio ** (b / self.bands_n)
            f1 = self.fmin * ratio ** ((b + 1) / self.bands_n)
            lo = int(np.floor(f0 / nyq * half))
            hi = int(np.ceil(f1 / nyq * half))
            lo = max(1, min(lo, half - 1))
            hi = max(lo + 1, min(hi, half))
            self._lo[b], self._hi[b] = lo, hi
            self._tiltdb[b] = self.tilt * np.log2(((f0 * f1) ** 0.5) / pivot)

    def read(self):
        """(bands, active). A COPY, so the caller can publish it without
        holding the capture lock across a frame write."""
        with self._lock:
            return self._bands.tolist(), self._active

    def close(self):
        self._stop.set()
        p = self._proc
        if p is not None and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    def _process(self, samples):
        """Consume PCM in 50%-overlapping hops, publishing bands per hop."""
        self._acc = np.concatenate((self._acc, samples))
        n = self.fft
        span = 0.0 - self.floor_db
        while self._acc.size >= n:
            frame = self._acc[:n]
            rms = float(np.sqrt(np.mean(frame.astype(np.float64) ** 2)))
            spec = np.abs(np.fft.rfft(frame * self._win)) / (n / 2.0)
            with self._lock:
                for b in range(self.bands_n):
                    seg = spec[self._lo[b]:self._hi[b]]
                    m = float(seg.mean()) if seg.size else 0.0
                    db = 20.0 * np.log10(m + 1e-9) + self._tiltdb[b]
                    v = (db - self.floor_db) / span
                    v = min(1.0, max(0.0, v) * self.gain)
                    cur = float(self._bands[b])
                    c = self.attack if v > cur else self.decay
                    self._bands[b] = cur + (v - cur) * c
                self._active = rms > self.active_rms
            self._acc = self._acc[n // 2:]

    def _capture_loop(self):
        """Record until the default sink moves or the read fails, then reopen.
        Bands are zeroed between streams so a stale picture never lingers."""
        while not self._stop.is_set():
            src = default_monitor()
            if not src:
                self._stop.wait(0.5)
                continue
            try:
                self._proc = subprocess.Popen(
                    ["parecord", "--device=" + src, "--format=float32le",
                     "--rate=%d" % int(self.rate), "--channels=1", "--raw"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except FileNotFoundError:
                return                      # no parecord: no spectrum, quietly
            nbytes = (self.fft // BLOCK_HOP) * 4
            last_check = time.monotonic()
            while not self._stop.is_set():
                buf = self._proc.stdout.read(nbytes)
                if not buf or len(buf) < nbytes:
                    break
                self._process(np.frombuffer(buf, dtype="<f4"))
                if time.monotonic() - last_check > MONITOR_POLL:
                    last_check = time.monotonic()
                    if default_monitor() != src:
                        break               # sink moved; reopen on the new one
            try:
                self._proc.terminate()
            except Exception:
                pass
            with self._lock:
                self._bands[:] = 0.0
                self._active = False
