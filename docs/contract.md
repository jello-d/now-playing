# now-playing: the consumer contract

What a renderer is given, and what it is expected to do with it. Everything
here is public and stable within a layout version; everything about HOW the
daemon learns any of it (MPRIS, playerctl, pychromecast, a cloned local
playback for cast spectrum) is private and may change without notice.

The guiding split: the daemon is the model and the controller, a consumer is
the view. A consumer renders what it is handed and forwards input verbatim.
It does not derive facts, and it never consults a second source of truth.

## Two directions, two mechanisms

Output and input have different natures, so they use different transports.
This asymmetry is deliberate, not an accident of history.

- OUT (daemon -> consumers): a shared-memory frame. Continuous, lossy,
  latest-wins, many readers. A consumer that misses a thousand updates and
  reads the next one is fully correct, because every frame is a complete
  picture rather than a delta.
- IN (consumer -> daemon): the control FIFO (`np-ctl`). Discrete, rare, and
  must not be dropped. A missed play/pause is a bug; a missed frame is not.

There is no state file. The earlier JSON at `now-playing.state` is REMOVED: it
forced one publish rate on every consumer, and a second projection of the same
facts is a second thing free to drift from the first. `now-playing status` is
its replacement (see CLI) and reads this same frame, so a shell consumer and a
bar cannot disagree about what is playing.

## The frame

A single page at a fixed path:

    ${XDG_RUNTIME_DIR:-/tmp}/now-playing.frame

4096 bytes, native byte order (little-endian on every supported platform;
the magic doubles as an endianness check). All fields naturally aligned.

    off     type      field         meaning
    0x0000  u32       magic         0x5246504e ("NPFR" in memory order)
    0x0004  u32       version       layout version; 1 today
    0x0008  u32       frame_bytes   total mapped size (4096)
    0x000c  u32       seq           seqlock counter; odd = write in flight
    0x0010  u64       heartbeat_ns  CLOCK_MONOTONIC ns at publish
    0x0018  u32       daemon_pid    publisher pid (diagnostics only)
    0x001c  u32       flags         bit0 spectrum_enabled; rest reserved

    0x0020  u32       status        0 idle, 1 playing, 2 paused
    0x0024  u32       source        0 none, 1 local, 2 cast
    0x0028  f64       position      seconds into the track
    0x0030  f64       length        seconds; 0 = unknown or not applicable
    0x0038  f64       rate          playback rate; 1.0 = normal
    0x0040  u32       caps          bit0 pause, bit1 next, bit2 prev,
                                    bit3 seek. A clear bit means the control
                                    WILL NOT work on the live source.
    0x0044  u32       track_id      bumped on every track change

    0x0080  char[256] title         UTF-8, NUL-terminated, truncated to fit
    0x0180  char[256] artist
    0x0280  char[256] album
    0x0380  char[128] device        cast device name; empty when local
    0x0400  char[512] art_path      local filesystem path; empty if none

    0x0600  u32       band_count    live bands; 0 = no spectrum available
    0x0604  u32       reserved
    0x0608  f32[64]   bands         0.0..1.0; only band_count are valid

    0x0708..0x0fff    reserved      zero-filled; do not interpret

Strings are truncated at the slot boundary, always NUL-terminated. Bounded
truncation is deliberate: a fixed slot cannot be overrun, and a consumer
never has to allocate.

`art_path` is always a LOCAL FILE PATH, never a URL. The daemon downloads
remote art once and publishes where it landed, so a consumer only ever opens
a file. This is model work by definition and does not belong in a renderer.

### status vs title

`status` is authoritative and complete. A consumer MUST NOT re-derive
idleness from an empty title or a zero length; if the daemon says playing,
it is playing. There is exactly one definition of idle and it lives in the
daemon.

### caps

`caps` says what the live source can actually do. A Chromecast app that
cannot honour previous-track reports bit2 clear, and a renderer should draw
that control inert rather than offering an affordance that does nothing.

## The seqlock

One writer (the daemon), any number of readers, no OS locking primitive.
This is not a lock: there is no mutex, no futex, nothing to acquire, and no
recovery problem if a holder dies. It is a counter and a retry.

Writer, per publish:

    seq += 1                  # now odd: a write is in flight
    <store barrier>
    write every payload field
    <store barrier>
    seq += 1                  # now even: frame is complete

Reader, per sample:

    for attempt in 1..N:
        s1 = load(seq)              # acquire
        if s1 is odd: retry
        copy the payload out
        s2 = load(seq)              # acquire
        if s1 == s2: accept
    treat as UNAVAILABLE            # retries exhausted

The bounded retry matters. A daemon killed between the two counter bumps
leaves `seq` odd forever, and an unbounded reader would spin on it. After N
attempts a consumer must fall back to the stale path below rather than
block. Recommended N is small; contention here is microseconds against a
sample interval of milliseconds, so a legitimate retry succeeds immediately.

ORDERING IS THE LOAD-BEARING PART. The payload stores must land before the
final counter store, or a reader accepts a half-written frame with a
matching counter. Readers should use acquire/release atomics, which cost
nothing on x86-64 and are correct everywhere.

The Python writer has no explicit barriers available. It relies on x86-64
store-store ordering (TSO), which is correct on every machine this currently
runs on. It would NOT be correct on a weakly ordered architecture such as
ARM without a real fence. Anyone porting this must fix the writer first;
the reader side is already portable.

A reader MUST validate `magic` and `version` inside the accepted read, not
only at map time, because a restarted daemon may have published a different
layout into the same page. An unrecognised version is a loud failure, never
a best-effort parse.

## Liveness, restart, and staleness

`heartbeat_ns` advances on every publish. Both the daemon and its consumers
read CLOCK_MONOTONIC, which is system-wide on Linux, so the values are
directly comparable across processes.

A consumer treats the frame as STALE when `now - heartbeat_ns` exceeds a few
publish intervals (two seconds is a sane default), or when the seqlock read
gives up. Stale means the daemon is gone or wedged: render the idle state.
Do not render the last known track as though it were still playing.

The daemon NEVER unlinks the segment. On restart it reopens the same path,
so every existing mapping keeps working and a restart is invisible to
consumers. Unlink-and-recreate would leave readers mapped to an orphaned
inode, silently watching a frame that will never advance again; that failure
mode is why this rule exists.

Should the path itself ever change, a stale reader recovers by re-running
discovery (below) and re-mapping. That path is cheap, rare, and requires no
coordination: the daemon does not know how many consumers exist, and that
ignorance is a feature.

## The command-line tool

The stable entry point. A consumer that does not want to speak the binary
format never has to.

    now-playing status                     one-shot, human-readable, exit
    now-playing status --json              one-shot, machine-readable, exit
    now-playing status --follow            stream, emitting on change
    now-playing status --interval SECS     stream at a fixed cadence instead
    now-playing shm-info                   path, version, geometry, liveness

`--follow` is what a shell consumer should use. It maps once and streams, so
a script never picks a poll interval and never pays a process spawn per
sample:

    now-playing status --follow --json | while IFS= read -r line; do ...; done

CHANGE, for `--follow`, means the EVENTFUL half of the frame: status, source,
title, artist, album, device, art, caps, track_id, or a liveness transition.
Position deliberately does not count. It moves every frame, so reacting to it
would turn a script consumer into a firehose. When a caller genuinely wants
the motion, `--interval SECS` emits on a clock instead, position included.

Exit status: 0 a live frame was read, 1 no live frame (absent, stale, or
incoherent), 2 usage, 3 the frame is a layout version this build cannot
parse. `shm-info` reports a version mismatch rather than failing on it, which
is the entire reason it reads the header outside the seqlock.

`shm-info` reports the segment path, the layout version, `frame_bytes`, the
maximum band count, and whether the frame is currently live. A native
consumer calls it once at startup, then talks to the memory directly.

Its real job is VERSION NEGOTIATION. Path discovery is nearly free; knowing
that a reader built against version 1 is looking at version 2 is what stops
a silent misparse. The name says `shm` on purpose: the segment is part of
the public contract, not an implementation detail hidden behind the tool, so
a name that concealed it would be the misleading one.

## Configuration

    ${XDG_CONFIG_HOME:-$HOME/.config}/now-playing/config

`KEY=VALUE`, one per line. `#` begins a comment. Values are read LITERALLY:
no quoting, no expansion, nothing executed. An UNKNOWN KEY IS A LOUD ERROR,
not a shrug. A silently ignored typo in a tunable is the failure this format
exists to prevent: it would simply never take effect, and be discovered
months later.

Every key may be overridden by an environment variable of the same name for
one-off testing. `NP_PLAYERS` keeps working as the override for `players`.

EVERY KEY BELOW IS LIVE. The spectrum keys were previously refused as unknown,
because the analyser still lived in the renderer and accepting an inert key is
the silent no-op this format exists to prevent. The analyser now runs in the
daemon, so they took effect in the same change that made them mean something.
An out-of-range value is refused at startup with the reason, not clamped.

    key            default                       meaning
    players        YoutubeMusic,chrome,chromium  playerctl player list
    publish_hz     30                            frame publish rate
    spectrum       off                           on = capture and analyse
    bands          24                            log-spaced bands, max 64
    fft            4096                          FFT size, power of two
    rate           44100                         capture sample rate
    fmin           45                            lowest band edge (Hz)
    fmax           16000                         highest band edge (Hz)
    gain           2.0                           lifts normalised magnitude
    floor_db       -60                           dB mapped to zero
    tilt           3.5                           dB/octave lift toward highs
    attack         0.65                          rise smoothing per hop
    decay          0.16                          fall smoothing per hop
    active_rms     4e-4                          RMS above this = audio live

`spectrum = on` publishes `bands` for LOCAL playback only. While a cast is the
source the daemon publishes `band_count = 0`, because a Chromecast decodes on
the device and there is no local PCM to analyse. The sink monitor would still
carry whatever this box happens to be playing, and publishing that against a
cast track would describe audio the listener is not hearing. A consumer needs
no special case: `band_count = 0` already means "no spectrum available".

Every key above describes the SIGNAL, so it lives with the producer. How the
signal LOOKS (cap physics, dot size, colours, opacity, scrim, outline) is
the renderer's business and belongs in the renderer's own config.

## What a consumer may compute

ALLOWED, because it is presentation:

- Layout, colour, typography, glyph shapes, hit rectangles.
- Marquee scroll phase, peak-hold cap physics, fades and easing.
- Decoding and scaling `art_path`.
- Sub-frame smoothing of `position` between samples.
- Which input gesture maps to which command.

NOT ALLOWED, because the daemon already decided it:

- Whether something is playing. Read `status`.
- Whether a control is usable. Read `caps`.
- Where the playhead is, from any wall clock. Read `position`.
- Band values, from any audio source. Read `bands`.
- Whether the daemon is alive. Read `heartbeat_ns`.

The test for a new field is simple. If a consumer has to look anywhere other
than this frame to answer a question, the frame is missing a field. Add it
here rather than teaching the view to go find out.
