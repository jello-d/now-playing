#!/bin/sh
# check.t - the service-state logic in `setup.sh check`. The point is the gap
# that once hid a crash-loop: an ENABLED but failing unit must NOT read green
# when a session bus is present, yet a headless provision (no bus) must still
# pass on enabled alone. A stub systemctl supplies is-enabled (always here) and
# a scripted is-active; the rest of the check is satisfied by a small fixture.
. "$(dirname "$0")/lib.sh"
harness_init check

mkdir -p "$T/local/bin" "$T/bin" "$T/venv/bin"
ln -sfn "$HERE/bin/np-ctl" "$T/local/bin/np-ctl"   # np-ctl linked
: > "$T/venv/bin/python"; chmod +x "$T/venv/bin/python"   # venv present
# A launcher matching what `service` would write for THIS tree + venv.
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' \
  "$T/venv/bin/python" "$HERE/libexec/now-playing" > "$T/local/bin/now-playing"

# stub systemctl: enabled always; is-active echoes $FAKE_ACTIVE (empty = the
# bus does not answer, i.e. a headless provision -> print nothing, non-zero).
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
_c=
for a in "$@"; do
  case "$a" in is-enabled) _c=en ;; is-active) _c=ac ;; esac
done
[ "$_c" = en ] && exit 0
if [ "$_c" = ac ]; then
  [ -n "${FAKE_ACTIVE:-}" ] && { echo "$FAKE_ACTIVE"; exit 0; }
  exit 1
fi
exit 0
EOF
chmod +x "$T/bin/systemctl"

ck() {   # $1 = FAKE_ACTIVE ("" for no bus)
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" PREFIX="$T/local" \
    XDG_DATA_HOME="$T/local/share" NOW_PLAYING_VENV="$T/venv" \
    ${1:+FAKE_ACTIVE="$1"} sh "$HERE/setup.sh" check
}

# active -> check passes and says so
out=$(ck active) || fail "check failed while the service was active"
echo "$out" | grep -q 'service active' || fail "did not report the active state"

# crash-loop (activating) with a live bus -> check MUST fail (this is the gap)
ck activating >/dev/null 2>&1 \
  && fail "check passed on a crash-looping (activating) service" || :

# no session bus -> pass on enabled alone, and do NOT claim active
out=$(ck "") || fail "check failed with no session bus (want enabled-only pass)"
echo "$out" | grep -q 'service enabled' || fail "no enabled report (headless)"
echo "$out" | grep -q 'service active' && fail "claimed active with no bus" || :

# A launcher pointing somewhere ELSE must FAIL, even though every other
# assertion is green and a still-running daemon keeps the service active. This
# is the stale-launcher trap: it only bites on the next restart, so a check that
# merely tests existence reports a healthy box that is one restart from a
# crash-loop.
out=$(ck active) || fail "check failed on a good launcher"
echo "$out" | grep -q 'launcher current' || fail "no launcher report: $out"

printf '#!/bin/sh\nexec /nowhere/python /nowhere/daemon "$@"\n' \
  > "$T/local/bin/now-playing"
ck active >/dev/null 2>&1 && fail "check passed with a FOREIGN launcher" || :
out=$(ck active 2>&1 || :)
echo "$out" | grep -q 'launcher STALE or foreign' || fail "bad report: $out"

pass
