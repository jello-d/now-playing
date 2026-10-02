#!/bin/sh
# check.t - the service-state logic in `setup.sh check`. The point is the gap
# that once hid a crash-loop: an ENABLED but failing unit must NOT read green
# when a session bus is present, yet a headless provision (no bus) must still
# pass on enabled alone. A stub systemctl supplies is-enabled (always here) and
# a scripted is-active; the rest of the check is satisfied by a small fixture.
. "$(dirname "$0")/harness_lib"
harness_init check

# A PAYLOAD-SHAPED fixture: the install is a copy into one tree now, with the
# bin link and the launcher both pointing INSIDE it, so a fixture built the old
# way (links into the source tree) fails check's containment assertions before
# it ever reaches the service-state logic this file exists to test.
PAY=$T/local/share/now-playing
mkdir -p "$T/local/bin" "$T/bin" "$PAY/bin" "$PAY/libexec" "$PAY/venv/bin"
: > "$PAY/bin/np-ctl"
: > "$PAY/libexec/now-playing"
: > "$PAY/libexec/npframe_lib.py"
: > "$PAY/venv/bin/python"; chmod +x "$PAY/venv/bin/python"
ln -sfn "$PAY/bin/np-ctl" "$T/local/bin/np-ctl"
# A launcher matching what `service` would write for this payload.
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' \
  "$PAY/venv/bin/python" "$PAY/libexec/now-playing" > "$T/local/bin/now-playing"

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

# XDG_RUNTIME_DIR points at the scratch dir so the frame-liveness step finds
# NOTHING and stays silent. Without that this test reads the REAL runtime frame,
# so whether it passes depends on whether the box's daemon happens to be
# publishing, and a stale frame on a stopped daemon fails it for no reason.
# The venv is NOT overridden: it lives inside the payload by default now, and
# the default is the thing worth testing.
ck() {   # $1 = FAKE_ACTIVE ("" for no bus)
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" PREFIX="$T/local" \
    XDG_DATA_HOME="$T/local/share" XDG_RUNTIME_DIR="$T" \
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

# A LINK BACK INTO A SOURCE TREE must FAIL, which is the regression this layout
# exists to prevent: that is what the old install did, and for a departed
# package the target is a clone that is re-cloned every sweep, so the link
# dangles and only a transport click ever reveals it.
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' \
  "$PAY/venv/bin/python" "$PAY/libexec/now-playing" > "$T/local/bin/now-playing"
ln -sfn "$HERE/bin/np-ctl" "$T/local/bin/np-ctl"
ck active >/dev/null 2>&1 \
  && fail "check passed with np-ctl outside the payload" || :
out=$(ck active 2>&1 || :)
echo "$out" | grep -q 'resolve outside' || fail "no containment report: $out"

pass
