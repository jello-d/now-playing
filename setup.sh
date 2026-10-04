#!/bin/sh
# setup.sh - install / uninstall / check the now-playing media suite: the
# now-playing daemon (a local MPRIS reader over playerctl, with a read-only-
# gated Chromecast fallback for when casting) that publishes the now-playing
# frame, plus np-ctl (the transport command a media widget calls). The SINGLE
# entry point a consumer or provisioning layer uses.
#
#   ./setup.sh install     copy the payload to ~/.local/share/now-playing and
#                          link np-ctl (+ man) into ~/.local
#   ./setup.sh service     build the venv IN the payload + enable the --user
#                          service
#   ./setup.sh all         install + service
#   ./setup.sh uninstall   remove the payload, the links and the --user service
#   ./setup.sh check       command + deps present, venv + service up; markers
#   ./setup.sh test        run the in-repo suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. INSTALLS BY COPYING into a single payload tree at
# ~/.local/share/now-playing (bin, libexec, man, venv), with bin and man links
# pointing into it. Nothing under ~/.local resolves back into this source tree,
# because a departed package's source is a clone that is re-cloned on every
# sweep: a link into it dangles, and the daemon's launcher pointing into it is a
# crash-loop one restart later. See shared-notes/_install-placement.md.
#
# The daemon publishes a SHARED-MEMORY FRAME at
# $XDG_RUNTIME_DIR/now-playing.frame (the contract a widget reads, specified
# in docs/contract.md), and takes transport on now-playing.ctl (np-ctl writes
# it). `now-playing status` is the shell-facing reader of the same frame, so a
# script needs no special support. playerctl is a SYSTEM binary, not a venv dep;
# the venv carries only pychromecast (the cast fallback), like bt-sane's tray
# venv.
set -eu

PKG=now-playing
VERSION=0.1.0
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [ -n "$HOME" ] || { echo "$PKG: HOME unset" >&2; exit 1; }
  export HOME
fi

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
_usr=$_cfg/systemd/user

# THE PAYLOAD: a self-contained COPY of what this repo ships, with the installed
# bin and man links pointing INTO it. Nothing under ~/.local may resolve back
# into the source tree, because a departed package's source is a clone that is
# re-cloned on every sweep and wiped on demand, so every such link dangles.
_pay=$_shr/$PKG

# The venv folds INTO the payload, so the whole install is one tree. The old
# location is retired on sight: a layout switch removes the layout it replaces,
# or the two coexist and the stale one rots behind the live one.
VENV=${NOW_PLAYING_VENV:-$_pay/venv}
_oldvenv=$HOME/.venvs/$PKG

DEPS="playerctl"          # the system MPRIS CLI the daemon shells out to
DEPS_SOFT="python3"
RC=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

# _payload_stage: build the new payload beside the live one, then swap it in.
#
# STAGED AND SWAPPED, never emptied in place. Two renames is as close to atomic
# as a directory gets, and the alternative would leave the daemon's launcher
# pointing at a half-copied tree for the length of a copy.
#
# THE VENV IS CARRIED ACROSS, which is a deliberate departure from mux's
# template. mux rebuilds its indicator venv on a re-stage; here the --user
# service's launcher execs `$VENV/bin/python`, so wiping the venv would
# CRASH-LOOP the running daemon from the Install phase until the Configure phase
# re-ran `service`, and those are minutes apart in a sweep with several domains
# between them. Carrying it also keeps a provision working without a network.
_payload_stage() {
  _ps_new=$_pay.new
  _ps_old=$_pay.old
  # Expanded and CHECKED before anything is removed, per the standing rm rule:
  # an empty or wrong value must never be able to reach `rm -rf`.
  case $_pay in
  "$HOME"/*/?*|/*/*/?*) ;;
  *) echo "$PKG: refusing to stage a payload at '$_pay'" >&2; return 1 ;;
  esac
  rm -rf -- "$_ps_new" "$_ps_old"
  mkdir -p "$_ps_new" || { echo "$PKG: cannot create $_ps_new" >&2; return 1; }
  for _d in bin lib libexec share man; do
    [ -d "$_root/$_d" ] || continue
    cp -R "$_root/$_d" "$_ps_new/" || {
      echo "$PKG: cannot copy $_d" >&2; rm -rf -- "$_ps_new"; return 1; }
  done
  # DROP BUILD DETRITUS. The repo gitignores __pycache__, so a clean clone has
  # none, but the venv python RUNS from the clone's lib and writes it there,
  # so a copy would ship it. A payload is what the repo ships, not what running
  # it produced; stale bytecode for a module that has since been renamed is the
  # kind of thing that only ever confuses a later diagnosis.
  find "$_ps_new" -name __pycache__ -type d -prune \
    -exec rm -rf -- {} + 2>/dev/null || :
  # Fail LOUD on a payload that would install but not work, rather than linking
  # into an empty tree and discovering it at the next daemon restart.
  for _f in bin/np-ctl libexec/now-playing lib/npframe_lib.py; do
    [ -f "$_ps_new/$_f" ] || {
      echo "$PKG: staged payload has no $_f" >&2
      rm -rf -- "$_ps_new"; return 1; }
  done
  # CARRY the venv. `if`, not `[ ] && mv`: as the last command of a block the
  # false test makes the block non-zero, which under set -e is the documented
  # way this family of scripts kills itself.
  if [ -d "$_pay/venv" ]; then mv -- "$_pay/venv" "$_ps_new/venv"; fi
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    mv -- "$_pay" "$_ps_old" || {
      echo "$PKG: cannot move the old payload" >&2; return 1; }
  fi
  mv -- "$_ps_new" "$_pay" || {
    echo "$PKG: cannot swap in the new payload" >&2
    if [ -e "$_ps_old" ]; then mv -- "$_ps_old" "$_pay"; fi
    return 1; }
  rm -rf -- "$_ps_old"
}

_retire_old_venv() {
  [ -d "$_oldvenv" ] || return 0
  case $_oldvenv in
  "$HOME"/.venvs/?*) rm -rf -- "$_oldvenv"
                     echo "$PKG: retired the old venv at $_oldvenv" ;;
  *) echo "$PKG: refusing to remove '$_oldvenv'" >&2 ;;
  esac
}

do_install() {
  _payload_stage || return 1
  mkdir -p "$_bin"
  ln -sfn "$_pay/bin/np-ctl" "$_bin/np-ctl"
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    _rel=man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    mkdir -p "$_d"; ln -sfn "$_pay/$_rel" "$_d/$(basename "$_m")"; done
  echo "$PKG: installed to $_pay (+ np-ctl and man links in $PREFIX)"
}

# The launcher's EXACT content, in one place, so `check` can assert byte
# equality instead of keeping a second, driftable description of it. Both paths
# are now inside the PAYLOAD, so the running daemon no longer depends on the
# source tree existing: that dependency is what made a re-cloned package a
# crash-loop one restart later.
_launcher_body() {
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' \
    "$VENV/bin/python" "$_pay/libexec/now-playing"
}

do_service() {
  command -v python3 >/dev/null 2>&1 || {
    echo "$PKG: python3 absent; no daemon venv" >&2; return 1; }
  # The venv lives inside the payload, so the payload has to exist first. Say so
  # rather than building a venv into a tree that is about to be staged over.
  [ -f "$_pay/libexec/now-playing" ] || {
    echo "$PKG: no payload at $_pay; run 'setup.sh install' first" >&2
    return 1; }
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$_pay/share/now-playing.reqs"
  mkdir -p "$_bin"
  _launcher_body > "$_bin/now-playing"
  chmod +x "$_bin/now-playing"
  mkdir -p "$_usr"
  cp "$_root/systemd/now-playing.service" "$_usr/now-playing.service"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable now-playing.service 2>/dev/null || true
  systemctl --user restart now-playing.service 2>/dev/null || true
  _retire_old_venv
  echo "$PKG: daemon venv + --user service installed + enabled"
}

do_uninstall() {
  if [ -e "$_usr/now-playing.service" ]; then
    systemctl --user disable --now now-playing.service 2>/dev/null || true
    rm -f "$_usr/now-playing.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  for _l in "$_bin/np-ctl" "$_bin/now-playing"; do
    if [ -e "$_l" ] || [ -L "$_l" ]; then rm -f "$_l"; fi
  done
  # Only unlink a man page that points at OUR payload, so a hand-placed or
  # distro-packaged page of the same name is left alone.
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    _rel=man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    if [ "$(readlink "$_l" 2>/dev/null)" = "$_pay/$_rel" ]; then rm -f "$_l"; fi
  done
  # The payload goes, venv and all, which is the point of it being one tree.
  # Shape-guarded for the same reason staging is.
  if [ -d "$_pay" ] || [ -L "$_pay" ]; then
    case $_pay in
    "$HOME"/*/?*|/*/*/?*) rm -rf -- "$_pay" ;;
    *) echo "$PKG: refusing to remove '$_pay'" >&2 ;;
    esac
  fi
  _retire_old_venv
  echo "$PKG: removed the payload, the links and the --user service"
}

do_check() {
  echo "== $PKG (media state daemon + transport) =="
  # THE PAYLOAD IS THE WHOLE POINT, so assert its shape before anything else. A
  # SYMLINK here means the install still depends on a source tree, which is the
  # exact state this layout replaced.
  if [ -L "$_pay" ]; then
    bad "$_pay is a SYMLINK: this install still depends on a source tree"
  elif [ -d "$_pay" ] && [ -f "$_pay/bin/np-ctl" ] \
      && [ -f "$_pay/libexec/now-playing" ]; then
    ok "payload is a self-contained tree ($_pay)"
  else
    bad "no payload tree at $_pay (setup.sh install)"
  fi
  if [ "$(readlink "$_bin/np-ctl" 2>/dev/null)" = "$_pay/bin/np-ctl" ]; then
    ok "np-ctl links into the payload"
  else bad "np-ctl does not link to $_pay/bin/np-ctl (setup.sh install)"; fi
  # NOTHING INSTALLED MAY RESOLVE OUTSIDE THE PAYLOAD. This is the assertion the
  # old layout could not make: np-ctl pointed into a clone that is re-cloned
  # every sweep, so the link dangled and only a transport click revealed it.
  _esc=
  for _l in "$_bin/np-ctl" "$_bin/now-playing"; do
    [ -e "$_l" ] || [ -L "$_l" ] || continue
    _rp=$(readlink -f "$_l" 2>/dev/null || true)
    case "$_rp" in
      "$_pay"/*) ;;
      "")        _esc="$_esc $_l(dangling)" ;;
      *)         if [ -L "$_l" ]; then _esc="$_esc $_l"; fi ;;
    esac
  done
  if [ -z "$_esc" ]; then ok "no installed link escapes the payload"
  else bad "these resolve outside $_pay:$_esc"; fi
  if [ -d "$_oldvenv" ]; then
    bad "the pre-payload venv survives at $_oldvenv (setup.sh service)"
  else ok "no stale pre-payload venv"; fi
  for _d in $DEPS; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (transport/MPRIS needs it)"; fi
  done
  for _d in $DEPS_SOFT; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (a feature degrades)"; fi
  done
  if [ -e "$_bin/now-playing" ]; then
    # The launcher is GENERATED, not a symlink, so readlink cannot audit it:
    # compare it byte-for-byte with what `service` would write right now. A
    # launcher left pointing at a tree that has since moved (a staged checkout,
    # or a source dir borrowed for testing) keeps a RUNNING daemon alive and
    # only bites on the NEXT restart, so every other assertion here stays green
    # while the box is one restart away from a crash-loop. That is exactly how
    # this hid for days once; asserted-vs-actual drift is the thing to detect.
    if [ "$(cat "$_bin/now-playing" 2>/dev/null)" = "$(_launcher_body)" ]; then
      ok "launcher current (execs the payload's daemon)"
    else
      bad "launcher STALE or foreign, not $_pay (setup.sh service)"
    fi
    if [ -x "$VENV/bin/python" ]; then ok "daemon venv present (in payload)"
    else bad "launcher present but venv missing (setup.sh service)"; fi
    # enabled = will start next login (headless-safe: reads the unit file).
    if systemctl --user is-enabled --quiet now-playing.service 2>/dev/null; then
      ok "now-playing.service enabled"
    else bad "now-playing.service not enabled (setup.sh service)"; fi
    # active = actually running NOW. This needs a session bus, which a headless
    # TTY provision lacks, so only assert it when the bus answers, and otherwise
    # skip. Without this an ENABLED-but-crash-looping service (e.g. a launcher
    # pointing at a moved path) reads green forever; is-enabled cannot see it.
    _st=$(systemctl --user is-active now-playing.service 2>/dev/null || true)
    case "$_st" in
      active) ok "now-playing.service active" ;;
      "")     : ;;   # no session bus (headless) -- runtime state unknowable
      *)      bad "now-playing.service '$_st', not active (crash-loop?)" ;;
    esac
    # A LIVE frame is a STRONGER claim than an active unit: it proves the
    # daemon is actually PUBLISHING, not merely running. Same session gate:
    # no frame at all means the daemon has never run in this session (a
    # headless provision), which is unknowable rather than wrong. The reader
    # is stdlib-only, so the system python3 runs it without the venv.
    if command -v python3 >/dev/null 2>&1; then
      _fr=$(python3 "$_root/libexec/now-playing" shm-info --json \
            2>/dev/null || true)
      case "$_fr" in
        *'"live": true'*)    ok "frame live (daemon publishing)" ;;
        *'"present": true'*) bad "frame STALE; daemon up but not publishing" ;;
        *)                   : ;;
      esac
    fi
  else
    warn "daemon not installed (run setup.sh service for it)"
  fi
}

_U="usage: setup.sh [install|service|all|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  service)   do_service ;;
  all)       do_install; do_service ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
