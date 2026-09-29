"""npmpris_lib - read the MPRIS PLAYER interface directly over D-Bus.

TWO PROBLEMS, ONE CLIENT.

1. COST. Position came from `playerctl position`, a PROCESS SPAWN every
   POLL_SECS: 57,600 spawns a day to read one float, measured at roughly
   1.0-1.3% of a core sustained. A held-open bus connection costs 0.24 ms a
   read against 6.6 ms a spawn, so about 28x less per sample.

2. TRUTH. CanPause / CanGoNext / CanGoPrevious / CanSeek are PLAYER-INTERFACE
   properties, not metadata, and playerctl 2.4.1's --format reaches only
   metadata (confirmed: it answers {{canGoNext}} with an empty string). So local
   caps were a CONSTANT claiming pause|next|prev, and on a real player that
   constant is WRONG -- a Chromium podcast tab reports CanGoNext False,
   CanGoPrevious False, CanSeek True. The card drew skip controls as usable when
   they did nothing, which docs/contract.md promises will not happen.

PLAYER SELECTION IS NOT OURS. playerctl already resolves a priority list to one
live player, and choosing again here would be a second definition of "which
player", free to disagree with the follower's. So the follower reports
`{{playerInstance}}` and every call here takes that exact instance.

Pure jeepney: no compiled extension. Nothing here knows the frame layout; it
returns MPRIS booleans and the caller maps them to caps bits.
"""
import threading

from jeepney import DBusAddress, MessageType, Properties
from jeepney.io.blocking import open_dbus_connection

MPRIS_PATH = "/org/mpris/MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
BUS_PREFIX = "org.mpris.MediaPlayer2."

# MPRIS reports Position in MICROSECONDS, while playerctl's `position` command
# handed back seconds. That is exactly the units bug a careless swap invites.
USEC = 1e6


class Client:
    """One held-open session-bus connection, shared by the follower thread and
    the position poll. jeepney's blocking connection is not safe for concurrent
    use, so every exchange takes the lock."""

    def __init__(self):
        self._conn = None
        self._lock = threading.Lock()

    def _ensure(self):
        """Connect if there is no connection. Raises on failure, so a caller
        treats a dead bus exactly like a failed call and skips the sample."""
        if self._conn is None:
            self._conn = open_dbus_connection(bus="SESSION")
        return self._conn

    def _drop(self):
        c, self._conn = self._conn, None
        if c is not None:
            try:
                c.close()
            except Exception:
                pass

    @staticmethod
    def _addr_for(instance):
        return DBusAddress(MPRIS_PATH, bus_name=BUS_PREFIX + instance,
                           interface=PLAYER_IFACE)

    def _call(self, msg):
        """One exchange under the lock. A failure DROPS the connection so the
        next call reconnects, rather than pinning a wedged socket forever.

        The message TYPE is checked explicitly because JEEPNEY DOES NOT RAISE on
        a D-Bus error: it returns an error Message whose body[0] is the error
        STRING. Reading that as a value is how an unknown player yielded a str
        where a properties dict belonged, and position() only appeared to cope
        because float() happened to choke on the text."""
        with self._lock:
            try:
                conn = self._ensure()
                reply = conn.send_and_get_reply(msg)
                if reply.header.message_type is MessageType.error:
                    err = reply.body[0] if reply.body else "?"
                    raise RuntimeError("D-Bus error: %s" % (err,))
                return reply.body[0]
            except Exception:
                self._drop()
                raise

    def position(self, instance):
        """Seconds into the track, or None when it could not be read.

        None is load-bearing: a caller must NOT read failure as position zero.
        The old playerctl path returned 0.0 on any error and the caller wrote
        that straight into the interpolation anchor, so one transient failure
        yanked the scrubber back to the start of the track."""
        try:
            addr = self._addr_for(instance)
            val = self._call(Properties(addr).get("Position"))
            return float(val[1]) / USEC
        except Exception:
            return None

    def caps(self, instance):
        """What the player says it can do, or None when unreadable.

        One GetAll rather than four Gets: a single round trip, and it is called
        on a metadata change rather than on the position poll. A property the
        player omits reads as False, which is the safe direction -- the contract
        says a CLEAR bit means the control will not work, so guessing True is
        the one thing this must never do."""
        try:
            addr = self._addr_for(instance)
            props = self._call(Properties(addr).get_all())
        except Exception:
            return None

        def flag(name):
            v = props.get(name)
            return bool(v[1]) if v else False

        return {"pause": flag("CanPause"), "next": flag("CanGoNext"),
                "prev": flag("CanGoPrevious"), "seek": flag("CanSeek"),
                "control": flag("CanControl")}

    def close(self):
        with self._lock:
            self._drop()
