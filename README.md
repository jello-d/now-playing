# now-playing

A media "now playing" state daemon. It reads the current player — local MPRIS
via [playerctl](https://github.com/altdesktop/playerctl), or a Chromecast via
[pychromecast](https://github.com/home-assistant-libs/pychromecast) when
casting — and publishes it as a **shared-memory frame** at
`$XDG_RUNTIME_DIR/now-playing.frame`. A widget (a bar's media card, say) maps
that page and renders title/artist/art, a progress scrubber, which transport
controls are usable, and an audio spectrum. `np-ctl` sends transport commands
(playpause/next/previous) to the daemon's control FIFO, so play/pause/skip work
while casting too.

The daemon is the **model**; a consumer is a **view**. Every frame is complete,
so a consumer renders what it is handed and derives no playback facts of its
own: it does not decide what "idle" means, does not extrapolate the playhead
from a clock, and does not learn where the audio came from. Read
**[docs/contract.md](docs/contract.md)** before writing one.

Any number of consumers may map the frame at once, each on its own clock, and
the daemon neither knows nor cares how many there are. `now-playing status`
is one such consumer, so a shell needs no special support:

```sh
now-playing status              # the current frame, once
now-playing status --follow     # stream, emitting on change
now-playing shm-info            # path, layout version, geometry, liveness
```

## Layout

- `libexec/now-playing` — the daemon, and the `status` / `shm-info` readers
  (Python; runs from the packaged venv).
- `libexec/npframe.py` — the frame layout, writer and reader: the single
  source of truth for the wire format.
- `libexec/now-playing.reqs` — the venv requirements (pychromecast).
- `bin/np-ctl` — the transport command (POSIX sh; writes the control FIFO).
- `systemd/now-playing.service` — the `--user` unit (runs the launcher).
- `docs/contract.md` — the consumer contract.

## Use

```sh
./setup.sh install    # link np-ctl (+ man) into ~/.local
./setup.sh service    # build the venv + enable the --user daemon
./setup.sh all        # both
./setup.sh check      # command + deps + venv + service; [OK]/[FAIL]
./setup.sh uninstall  # remove the links + the daemon (venv left)
```

`service` builds `~/.venvs/now-playing` (pychromecast only), writes a launcher
that execs the venv python on the daemon, and enables the `--user` service.
`playerctl` is a **system** binary (an apt/pkg dependency), not a venv dep —
local playback needs no venv at all; the venv is only for the cast fallback.

## License

Apache-2.0.
