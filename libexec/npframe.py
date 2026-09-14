"""
npframe - the now-playing shared-memory frame: layout, writer, reader.

THE SINGLE SOURCE OF TRUTH for the wire format described in docs/contract.md.
Every offset a consumer needs is defined here once; nothing else in this
package may hardcode one. A C++ or other-language reader mirrors these
constants, so a change here is a LAYOUT VERSION change, not an edit.

The frame is one page at $XDG_RUNTIME_DIR/now-playing.frame, published by a
single writer (the daemon) and read by any number of consumers. Every frame is
COMPLETE: there are no deltas, so a reader that misses a thousand updates and
takes the next one is fully correct. That is what makes the channel safely
lossy, and why a slow consumer costs the daemon nothing.

Coherence is a SEQLOCK, which is not a lock: no mutex, no futex, nothing to
acquire, and no recovery problem when a holder dies. The writer bumps a counter
to odd, writes, and bumps it to even; a reader retries while the counter is odd
or moved under it. See Writer.publish for the ordering requirement, which is
the load-bearing part.
"""
import mmap
import os
import struct
import time

MAGIC = 0x5246504E          # "NPFR" read as a little-endian u32
VERSION = 1
FRAME_BYTES = 4096
MAX_BANDS = 64

# --- header ---------------------------------------------------------------
O_MAGIC = 0x0000
O_VERSION = 0x0004
O_FRAME_BYTES = 0x0008
O_SEQ = 0x000C              # the seqlock counter; odd = write in flight

# --- payload (everything after the counter, written as ONE memcpy) --------
O_HEARTBEAT = 0x0010
O_PID = 0x0018
O_FLAGS = 0x001C
O_STATUS = 0x0020
O_SOURCE = 0x0024
O_POSITION = 0x0028
O_LENGTH = 0x0030
O_RATE = 0x0038
O_CAPS = 0x0040
O_TRACK_ID = 0x0044
O_TITLE = 0x0080
O_ARTIST = 0x0180
O_ALBUM = 0x0280
O_DEVICE = 0x0380
O_ART = 0x0400
O_BAND_COUNT = 0x0600
O_BANDS = 0x0608

O_PAYLOAD = O_HEARTBEAT     # the payload begins immediately after the counter
O_PAYLOAD_END = 0x0708
PAYLOAD_BYTES = O_PAYLOAD_END - O_PAYLOAD

N_TITLE = 256
N_ARTIST = 256
N_ALBUM = 256
N_DEVICE = 128
N_ART = 512

STATUS_IDLE, STATUS_PLAYING, STATUS_PAUSED = 0, 1, 2
STATUS_NAME = {0: "idle", 1: "playing", 2: "paused"}
STATUS_CODE = {v: k for k, v in STATUS_NAME.items()}

SOURCE_NONE, SOURCE_LOCAL, SOURCE_CAST = 0, 1, 2
SOURCE_NAME = {0: "", 1: "local", 2: "cast"}
SOURCE_CODE = {v: k for k, v in SOURCE_NAME.items()}

CAP_PAUSE, CAP_NEXT, CAP_PREV, CAP_SEEK = 1, 2, 4, 8
CAP_NAMES = (("pause", CAP_PAUSE), ("next", CAP_NEXT),
             ("prev", CAP_PREV), ("seek", CAP_SEEK))

FLAG_SPECTRUM = 1

# A frame older than this is treated as dead rather than current. Several
# publish intervals, so an ordinary scheduling hiccup never reads as a death.
STALE_SECS = 2.0


class FrameVersionError(Exception):
    """The mapped frame is a layout this build does not understand."""


def frame_path():
    """The one well-known path. Fixed, so no consumer needs discovery to
    FIND it; `shm-info` exists to negotiate the VERSION, not the location."""
    run = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(run, "now-playing.frame")


def _fixed(s, n):
    """`s` as exactly n bytes, NUL-terminated, truncated at a codepoint
    boundary (decode-ignore drops a sequence split by the cut, so a slot can
    never hold half a character)."""
    b = (s or "").encode("utf-8", "replace")[: n - 1]
    b = b.decode("utf-8", "ignore").encode("utf-8")
    return b + b"\0" * (n - len(b))


def _text(buf, off, n):
    raw = buf[off : off + n]
    end = raw.find(b"\0")
    if end >= 0:
        raw = raw[:end]
    return raw.decode("utf-8", "replace")


def caps_names(caps):
    return [name for name, bit in CAP_NAMES if caps & bit]


def peek_header(path=None):
    """(magic, version, frame_bytes) straight off the page, WITHOUT the
    seqlock. Legitimate only because the header is constant for the life of a
    publisher; never read payload this way. This is how `shm-info` reports a
    version it deliberately cannot parse."""
    p = path or frame_path()
    with open(p, "rb") as f:
        head = f.read(12)
    if len(head) < 12:
        raise OSError("frame is short (%s)" % p)
    return struct.unpack("<III", head)


class Writer:
    """The daemon's publishing end. One writer, ever."""

    def __init__(self, path=None):
        self.path = path or frame_path()
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            if os.fstat(fd).st_size < FRAME_BYTES:
                os.ftruncate(fd, FRAME_BYTES)
            self._mm = mmap.mmap(fd, FRAME_BYTES)
        finally:
            os.close(fd)

        # Continue the counter past whatever a previous daemon left, landing
        # EVEN. A predecessor killed mid-write leaves it odd; starting above it
        # means a reader straddling the restart sees the counter move and
        # retries, instead of matching a stale value.
        prev = struct.unpack_from("<I", self._mm, O_SEQ)[0]
        self._seq = (prev + 2) & 0xFFFFFFFE

        # The header is constant and sits OUTSIDE the payload, so write it
        # before any new counter value is published: by the time a reader can
        # accept a frame from this daemon, the version it validates is current.
        struct.pack_into("<III", self._mm, O_MAGIC, MAGIC, VERSION, FRAME_BYTES)

        self._pay = bytearray(PAYLOAD_BYTES)
        self._strs = {}
        self._pid = os.getpid()
        self.publish()          # an idle frame, so the page is never stale

    # The segment is NEVER unlinked. Unlink-and-recreate would leave every
    # existing consumer mapped to an orphaned inode, silently watching a frame
    # that can never advance again; reopening the same path makes a daemon
    # restart invisible instead.
    def close(self):
        try:
            self._mm.close()
        except Exception:
            pass

    def _put_str(self, off, n, s):
        if self._strs.get(off) == s:
            return              # discrete fields change per track, not per
        self._strs[off] = s     # frame: re-encode only when they actually move
        p = off - O_PAYLOAD
        self._pay[p : p + n] = _fixed(s, n)

    def _put_bands(self, bands):
        n = 0 if not bands else min(len(bands), MAX_BANDS)
        struct.pack_into("<I", self._pay, O_BAND_COUNT - O_PAYLOAD, n)
        if n:
            struct.pack_into("<%df" % n, self._pay, O_BANDS - O_PAYLOAD,
                             *[float(x) for x in bands[:n]])

    def publish(self, status=STATUS_IDLE, source=SOURCE_NONE, position=0.0,
                length=0.0, rate=1.0, caps=0, track_id=0, title="", artist="",
                album="", device="", art="", bands=None, flags=0):
        p = self._pay
        struct.pack_into("<Q", p, O_HEARTBEAT - O_PAYLOAD, time.monotonic_ns())
        struct.pack_into("<II", p, O_PID - O_PAYLOAD, self._pid, flags)
        struct.pack_into("<II", p, O_STATUS - O_PAYLOAD, status, source)
        struct.pack_into("<ddd", p, O_POSITION - O_PAYLOAD, position, length,
                         rate)
        struct.pack_into("<II", p, O_CAPS - O_PAYLOAD, caps, track_id)
        self._put_str(O_TITLE, N_TITLE, title)
        self._put_str(O_ARTIST, N_ARTIST, artist)
        self._put_str(O_ALBUM, N_ALBUM, album)
        self._put_str(O_DEVICE, N_DEVICE, device)
        self._put_str(O_ART, N_ART, art)
        self._put_bands(bands)

        # ORDERING IS LOAD-BEARING. The payload must land before the closing
        # counter store, or a reader accepts a half-written frame whose counter
        # matches. Python offers no explicit barrier; this relies on x86-64
        # store-store ordering (TSO), which holds on every machine this runs
        # on. It would NOT hold on a weakly ordered target such as ARM, where
        # this writer needs a real fence before the final store. The reader
        # side is already portable. See docs/contract.md.
        seq = self._seq + 1
        struct.pack_into("<I", self._mm, O_SEQ, seq)            # odd: in flight
        self._mm[O_PAYLOAD:O_PAYLOAD_END] = p                   # one memcpy
        struct.pack_into("<I", self._mm, O_SEQ, seq + 1)        # even: complete
        self._seq = seq + 1


class Reader:
    """A consumer's end. Any number of these, each on its own clock."""

    def __init__(self, path=None):
        self.path = path or frame_path()
        fd = os.open(self.path, os.O_RDONLY)
        try:
            if os.fstat(fd).st_size < FRAME_BYTES:
                raise OSError("frame is short (%s)" % self.path)
            self._mm = mmap.mmap(fd, FRAME_BYTES, prot=mmap.PROT_READ)
        finally:
            os.close(fd)

    def close(self):
        try:
            self._mm.close()
        except Exception:
            pass

    def read(self, attempts=8):
        """A coherent frame as a dict, or None if one could not be taken.

        The attempt bound matters: a daemon killed between the two counter
        stores leaves the counter ODD for good, and an unbounded reader would
        spin on it forever. Exhausting attempts means "unavailable", which the
        caller treats exactly like a stale frame."""
        mm = self._mm
        for _ in range(attempts):
            s1 = struct.unpack_from("<I", mm, O_SEQ)[0]
            if s1 & 1:
                continue                        # a write is in flight
            buf = mm[O_PAYLOAD:O_PAYLOAD_END]   # copy out, then re-validate
            magic, ver, _fb = struct.unpack_from("<III", mm, O_MAGIC)
            if struct.unpack_from("<I", mm, O_SEQ)[0] != s1:
                continue                        # it moved under us
            if magic != MAGIC:
                return None
            # Validated INSIDE the accepted read, not merely at map time: a
            # restarted daemon may have published a different layout into this
            # same page, and a best-effort parse of it would be silent garbage.
            if ver != VERSION:
                raise FrameVersionError(
                    "frame layout v%d, this build understands v%d"
                    % (ver, VERSION))
            return self._decode(buf, s1)
        return None

    @staticmethod
    def _decode(buf, seq):
        hb, pid, flags = struct.unpack_from("<QII", buf,
                                            O_HEARTBEAT - O_PAYLOAD)
        status, source = struct.unpack_from("<II", buf, O_STATUS - O_PAYLOAD)
        position, length, rate = struct.unpack_from("<ddd", buf,
                                                    O_POSITION - O_PAYLOAD)
        caps, track_id = struct.unpack_from("<II", buf, O_CAPS - O_PAYLOAD)
        nb = struct.unpack_from("<I", buf, O_BAND_COUNT - O_PAYLOAD)[0]
        nb = min(nb, MAX_BANDS)
        bands = list(struct.unpack_from("<%df" % nb, buf,
                                        O_BANDS - O_PAYLOAD)) if nb else []
        return {
            "seq": seq, "heartbeat_ns": hb, "pid": pid, "flags": flags,
            "spectrum_enabled": bool(flags & FLAG_SPECTRUM),
            "status": STATUS_NAME.get(status, "idle"),
            "source": SOURCE_NAME.get(source, ""),
            "position": position, "length": length, "rate": rate,
            "caps": caps, "caps_names": caps_names(caps),
            "track_id": track_id,
            "title": _text(buf, O_TITLE - O_PAYLOAD, N_TITLE),
            "artist": _text(buf, O_ARTIST - O_PAYLOAD, N_ARTIST),
            "album": _text(buf, O_ALBUM - O_PAYLOAD, N_ALBUM),
            "device": _text(buf, O_DEVICE - O_PAYLOAD, N_DEVICE),
            "art": _text(buf, O_ART - O_PAYLOAD, N_ART),
            "bands": bands,
        }


def age_secs(frame):
    """Seconds since the frame was published. Both ends read CLOCK_MONOTONIC,
    which is system-wide on Linux, so this compares across processes."""
    if not frame:
        return float("inf")
    return max(0.0, (time.monotonic_ns() - frame["heartbeat_ns"]) / 1e9)


def is_live(frame, stale=STALE_SECS):
    return frame is not None and age_secs(frame) <= stale
