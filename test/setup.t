#!/bin/sh
# setup.t - the PAYLOAD install contract, against a sandbox PREFIX.
#
# The install used to SYMLINK ~/.local/bin/np-ctl into this source tree, which
# for a departed package means into a clone that is re-cloned on every sweep and
# wiped on demand: the link dangles and only a transport click reveals it. The
# install is a COPY into one payload tree now, with the links pointing into
# that, so the assertions below are about containment rather than about which
# file a link happens to name.
#
# `service` is still out of this test (it needs python3, pip and systemd, which
# belong to the slow path), so the venv is FAKED where its handling matters.
. "$(dirname "$0")/harness_lib"
harness_init setup

PAY=$T/local/share/now-playing
sup() { env HOME="$T" PREFIX="$T/local" XDG_DATA_HOME="$T/local/share" \
  XDG_BIN_HOME="$T/local/bin" XDG_CONFIG_HOME="$T/cfg" \
  sh "$HERE/setup.sh" "$@"; }

sup install >/dev/null 2>&1 || fail "install exited non-zero"

# THE PAYLOAD IS A REAL TREE. A symlink here would mean the install still
# depends on a source tree, which is the whole thing this layout replaced.
[ -L "$PAY" ] && fail "payload is a SYMLINK, not a copied tree" || :
[ -d "$PAY" ] || fail "no payload directory at $PAY"
for _f in bin/np-ctl libexec/now-playing lib/npframe_lib.py \
          share/now-playing.reqs man/man1/now-playing.1; do
  [ -f "$PAY/$_f" ] || fail "payload is missing $_f"
done

# BUILD DETRITUS MUST NOT SHIP. The venv python runs from the clone's libexec
# and writes __pycache__ there, so a copy would carry it.
find "$PAY" -name __pycache__ -print | grep -q . \
  && fail "payload ships __pycache__" || :

# NOTHING INSTALLED MAY RESOLVE OUTSIDE THE PAYLOAD. This is the assertion the
# old layout could not make at all.
for _l in "$T/local/bin/np-ctl" "$T/local/share/man/man1/now-playing.1"; do
  [ -L "$_l" ] || fail "$_l is not a symlink"
  _rp=$(readlink -f "$_l" 2>/dev/null || true)
  [ -n "$_rp" ] || fail "$_l dangles"
  case "$_rp" in
    "$PAY"/*) ;;
    *) fail "$_l resolves OUTSIDE the payload: $_rp" ;;
  esac
done
case "$(readlink "$T/local/bin/np-ctl")" in
  "$PAY/bin/np-ctl") ;;
  *) fail "np-ctl does not link to the payload's copy" ;;
esac

# IDEMPOTENT, and the venv SURVIVES a re-stage. That carry is what keeps the
# --user service from crash-looping between the Install and Configure phases of
# a sweep, since its launcher execs the venv inside the payload.
mkdir -p "$PAY/venv/bin"
echo marker > "$PAY/venv/keep"
sup install >/dev/null 2>&1 || fail "second install exited non-zero"
[ -f "$PAY/venv/keep" ] || fail "a re-install destroyed the venv in the payload"
[ "$(cat "$PAY/venv/keep")" = marker ] || fail "the venv was replaced, not kept"

# NO STAGING LEFTOVERS: a failed or interrupted swap must not leave these.
for _d in "$PAY.new" "$PAY.old"; do
  [ -e "$_d" ] && fail "staging leftover: $_d" || :
done

# A PAYLOAD-LESS `service` FAILS LOUD rather than building a venv into a tree
# that is about to be staged over.
rm -rf "$PAY"
sup service >/dev/null 2>&1 && fail "service passed with no payload" || :

sup install >/dev/null 2>&1 || fail "reinstall after removal failed"
sup uninstall >/dev/null 2>&1 || fail "uninstall non-zero"
[ -e "$PAY" ] && fail "uninstall left the payload" || :
[ -e "$T/local/bin/np-ctl" ] && fail "uninstall left np-ctl" || :
[ -e "$T/local/share/man/man1/now-playing.1" ] \
  && fail "uninstall left the man link" || :

sh "$HERE/setup.sh" bogus >/dev/null 2>&1 && fail "unknown verb ok'd" || :
pass
