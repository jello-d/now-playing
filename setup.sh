#!/bin/sh
# setup.sh - install / uninstall / check the now-playing media suite: the
# now-playing daemon (a local MPRIS reader over playerctl, with a read-only-
# gated Chromecast fallback for when casting) that publishes now-playing.state,
# plus np-ctl (the transport command a media widget calls). The SINGLE entry
# point a consumer or provisioning layer uses.
#
#   ./setup.sh install     link np-ctl (+ man) into ~/.local
#   ./setup.sh service     build the daemon venv + enable its --user service
#   ./setup.sh all         install + service
#   ./setup.sh uninstall   remove the links + the --user service
#   ./setup.sh check       command + deps present, venv + service up; markers
#   ./setup.sh test        run the in-repo suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. The daemon publishes $XDG_RUNTIME_DIR/now-playing.
# state (JSON) and reads transport from now-playing.ctl (np-ctl writes it) --
# that state-file path is the CONTRACT a widget reads (e.g. a waybar media card
# pointed at it via its state-path/ctl-cmd config). playerctl is a SYSTEM
# binary, not a venv dep; the venv carries only pychromecast (the cast
# fallback), like bt-sane's tray venv.
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
VENV=${NOW_PLAYING_VENV:-$HOME/.venvs/now-playing}
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

do_install() {
  mkdir -p "$_bin"
  ln -sfn "$_root/bin/np-ctl" "$_bin/np-ctl"
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; ln -sfn "$_m" "$_d/$(basename "$_m")"; done
  echo "$PKG: linked np-ctl (+ man) into $PREFIX"
}

do_service() {
  command -v python3 >/dev/null 2>&1 || {
    echo "$PKG: python3 absent; no daemon venv" >&2; return 1; }
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$_root/libexec/now-playing.reqs"
  # A launcher: exec the venv python on the packaged daemon (replaces the old
  # venv-run shebang; this launcher is all the --user unit needs on PATH).
  mkdir -p "$_bin"
  cat > "$_bin/now-playing" <<EOF
#!/bin/sh
exec "$VENV/bin/python" "$_root/libexec/now-playing" "\$@"
EOF
  chmod +x "$_bin/now-playing"
  mkdir -p "$_usr"
  cp "$_root/systemd/now-playing.service" "$_usr/now-playing.service"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable now-playing.service 2>/dev/null || true
  systemctl --user restart now-playing.service 2>/dev/null || true
  echo "$PKG: daemon venv + --user service installed + enabled"
}

do_uninstall() {
  if [ -e "$_usr/now-playing.service" ]; then
    systemctl --user disable --now now-playing.service 2>/dev/null || true
    rm -f "$_usr/now-playing.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  for _l in "$_bin/np-ctl" "$_bin/now-playing"; do
    [ -e "$_l" ] && rm -f "$_l" || :; done
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_m" ] && rm -f "$_l" || :; done
  echo "$PKG: removed the links + the daemon (venv left)"
}

do_check() {
  echo "== $PKG (media state daemon + transport) =="
  if [ "$(readlink "$_bin/np-ctl" 2>/dev/null)" = "$_root/bin/np-ctl" ]; then
    ok "np-ctl linked"
  else bad "np-ctl not linked ($_bin/np-ctl)"; fi
  for _d in $DEPS; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (transport/MPRIS needs it)"; done
  for _d in $DEPS_SOFT; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (a feature degrades)"; done
  if [ -e "$_bin/now-playing" ]; then
    [ -x "$VENV/bin/python" ] && ok "daemon venv present" \
      || bad "launcher present but venv missing (setup.sh service)"
    # enabled = will start next login (headless-safe: reads the unit file).
    systemctl --user is-enabled --quiet now-playing.service 2>/dev/null \
      && ok "now-playing.service enabled" \
      || bad "now-playing.service not enabled (setup.sh service)"
    # active = actually running NOW. This needs a session bus, which a headless
    # TTY provision lacks, so only assert it when the bus answers -- otherwise
    # skip. Without this an ENABLED-but-crash-looping service (e.g. a launcher
    # pointing at a moved path) reads green forever; is-enabled cannot see it.
    _st=$(systemctl --user is-active now-playing.service 2>/dev/null || true)
    case "$_st" in
      active) ok "now-playing.service active" ;;
      "")     : ;;   # no session bus (headless) -- runtime state unknowable
      *)      bad "now-playing.service '$_st', not active (crash-loop?)" ;;
    esac
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
