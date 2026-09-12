# now-playing

A media "now playing" state daemon. It reads the current player — local MPRIS
via [playerctl](https://github.com/altdesktop/playerctl), or a Chromecast via
[pychromecast](https://github.com/home-assistant-libs/pychromecast) when
casting — and publishes it as JSON to `$XDG_RUNTIME_DIR/now-playing.state`. A
widget (a bar's media card, say) reads that file to render title/artist/art and
a progress scrubber. `np-ctl` sends transport commands (playpause/next/previous)
to the daemon's control FIFO, so play/pause/skip work while casting too.

The daemon and any widget are **decoupled**: the only contract is the state-file
path and the `np-ctl` command. A consumer points its widget at
`$XDG_RUNTIME_DIR/now-playing.state` and invokes `np-ctl` for transport; neither
imports the other, and the widget degrades gracefully when the daemon is absent.

## Layout

- `libexec/now-playing` — the daemon (Python; runs from the packaged venv).
- `libexec/now-playing.reqs` — the venv requirements (pychromecast).
- `bin/np-ctl` — the transport command (POSIX sh; writes the control FIFO).
- `systemd/now-playing.service` — the `--user` unit (runs the launcher).

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
