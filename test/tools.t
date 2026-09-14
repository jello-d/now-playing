#!/bin/sh
# tools.t - the packaged pieces exist and are what the daemon/launcher expect.
. "$(dirname "$0")/lib.sh"
harness_init tools
[ -x "$HERE/libexec/now-playing" ] || fail "libexec/now-playing missing/not +x"
head -1 "$HERE/libexec/now-playing" | grep -q 'python3' \
  || fail "daemon shebang is not python3 (venv-run leftover?)"
[ -x "$HERE/bin/np-ctl" ] || fail "bin/np-ctl missing/not +x"
[ -f "$HERE/libexec/now-playing.reqs" ] || fail "now-playing.reqs missing"
grep -q pychromecast "$HERE/libexec/now-playing.reqs" \
  || fail "reqs missing pychromecast (the cast fallback)"
[ -f "$HERE/libexec/npframe.py" ] || fail "libexec/npframe.py missing"
# npframe is the SINGLE source of truth for the layout: nothing else in the
# package may hardcode an offset, or a change here silently stops agreeing
# with a consumer that mirrors these constants.
grep -q 'now-playing.frame' "$HERE/libexec/npframe.py" \
  || fail "npframe does not name the frame path (the consumer contract)"
grep -q '^import npframe' "$HERE/libexec/now-playing" \
  || fail "daemon does not use npframe (a second layout definition?)"
grep -qE '0x0[0-9A-Fa-f]{3}' "$HERE/libexec/now-playing" \
  && fail "daemon hardcodes a frame offset; use npframe" || :
[ -f "$HERE/docs/contract.md" ] || fail "docs/contract.md missing"
# TRANSITIONAL: the JSON projection still feeds the deployed waybar card until
# it reads the frame. Keep asserting it until that consumer is cut over, so a
# daemon change cannot break the live bar before its replacement is in place.
grep -q 'now-playing.state' "$HERE/libexec/now-playing" \
  || fail "daemon dropped now-playing.state while a consumer still reads it"
grep -q 'ExecStart=%h/.local/bin/now-playing' \
  "$HERE/systemd/now-playing.service" \
  || fail "unit ExecStart is not the ~/.local launcher"
pass
