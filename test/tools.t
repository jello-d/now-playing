#!/bin/sh
# tools.t - the packaged pieces exist and are what the daemon/launcher expect.
. "$(dirname "$0")/harness_lib"
harness_init tools
[ -x "$HERE/libexec/now-playing" ] || fail "libexec/now-playing missing/not +x"
head -1 "$HERE/libexec/now-playing" | grep -q 'python3' \
  || fail "daemon shebang is not python3 (venv-run leftover?)"
[ -x "$HERE/bin/np-ctl" ] || fail "bin/np-ctl missing/not +x"
[ -f "$HERE/libexec/now-playing.reqs" ] || fail "now-playing.reqs missing"
grep -q pychromecast "$HERE/libexec/now-playing.reqs" \
  || fail "reqs missing pychromecast (the cast fallback)"
[ -f "$HERE/libexec/npframe_lib.py" ] || fail "libexec/npframe_lib.py missing"
# npframe is the SINGLE source of truth for the layout: nothing else in the
# package may hardcode an offset, or a change here silently stops agreeing
# with a consumer that mirrors these constants.
grep -q 'now-playing.frame' "$HERE/libexec/npframe_lib.py" \
  || fail "npframe does not name the frame path (the consumer contract)"
grep -q '^import npframe_lib' "$HERE/libexec/now-playing" \
  || fail "daemon does not use npframe_lib (a second layout definition?)"
grep -qE '0x0[0-9A-Fa-f]{3}' "$HERE/libexec/now-playing" \
  && fail "daemon hardcodes a frame offset; use npframe" || :
[ -f "$HERE/docs/contract.md" ] || fail "docs/contract.md missing"
# POSITION COMES OVER D-BUS, not from a process spawn per sample. The old path
# cost 57,600 playerctl spawns a day; assert it cannot creep back, and that the
# dep it needs is actually declared so a fresh venv gets it.
[ -f "$HERE/libexec/npmpris_lib.py" ] || fail "libexec/npmpris_lib.py missing"
grep -q '^jeepney' "$HERE/libexec/now-playing.reqs" \
  || fail "reqs does not declare jeepney (the MPRIS reader needs it)"
grep -q '_playerctl_position' "$HERE/libexec/now-playing" \
  && fail "the per-sample playerctl position spawn is back" || :
grep -q 'LOCAL_CAPS' "$HERE/libexec/now-playing" \
  && fail "local caps are a CONSTANT again; read them from the player" || :
grep -q 'playerInstance' "$HERE/libexec/now-playing" \
  || fail "the follower stopped reporting the instance the D-Bus reader needs"
# The JSON projection is RETIRED: the frame is the only published state. Assert
# it stays gone, so it cannot creep back as a second source of truth that is
# free to disagree with the frame.
grep -q 'os.unlink(os.path.join(RUN, "now-playing.state"))' \
  "$HERE/libexec/now-playing" \
  || fail "daemon no longer sweeps the retired state file (it would go stale)"
grep -q 'STATE_FILE\|_write_state' "$HERE/libexec/now-playing" \
  && fail "the retired JSON state writer is back" || :
grep -q 'ExecStart=%h/.local/bin/now-playing' \
  "$HERE/systemd/now-playing.service" \
  || fail "unit ExecStart is not the ~/.local launcher"
pass
