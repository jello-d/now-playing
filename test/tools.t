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
grep -q 'now-playing.state' "$HERE/libexec/now-playing" \
  || fail "daemon does not publish now-playing.state (the widget contract)"
grep -q 'ExecStart=%h/.local/bin/now-playing' \
  "$HERE/systemd/now-playing.service" \
  || fail "unit ExecStart is not the ~/.local launcher"
pass
