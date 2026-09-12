#!/bin/sh
# setup.t - install/uninstall roundtrip against a sandbox PREFIX (no venv/daemon
# -- `service` needs python3 + systemd, out of the fast suite).
. "$(dirname "$0")/lib.sh"
harness_init setup
env HOME="$T" PREFIX="$T/local" XDG_DATA_HOME="$T/local/share" \
  sh "$HERE/setup.sh" install >/dev/null 2>&1 || fail "install exited non-zero"
[ "$(readlink "$T/local/bin/np-ctl")" = "$HERE/bin/np-ctl" ] \
  || fail "install did not link np-ctl"
env HOME="$T" PREFIX="$T/local" XDG_DATA_HOME="$T/local/share" \
  sh "$HERE/setup.sh" uninstall >/dev/null 2>&1 || fail "uninstall non-zero"
[ -e "$T/local/bin/np-ctl" ] && fail "uninstall left np-ctl" || :
sh "$HERE/setup.sh" bogus >/dev/null 2>&1 && fail "unknown verb ok'd" || :
pass
