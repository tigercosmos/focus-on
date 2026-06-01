#!/bin/bash
#
# Unit/integration tests for helper/focus-blocker.
# Fully automated, no root and no system changes: it points the helper at a
# sandbox hosts file via the FOCUS_BLOCKER_* env overrides.
#
# Usage: bash tests/test-helper.sh   (exits non-zero if any test fails)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$DIR/helper/focus-blocker"

SANDBOX="$(mktemp -d)"
export FOCUS_BLOCKER_HOSTS="$SANDBOX/hosts"
export FOCUS_BLOCKER_BLOCKLIST="$SANDBOX/blocklist"
export FOCUS_BLOCKER_LOCKDIR="$SANDBOX/lock.d"
export FOCUS_BLOCKER_STATE="$SANDBOX/state"

MARK="focus-on block start"
PASS=0
FAIL=0

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_eq() { # name  actual  expected
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$3' got='$2')"; fi
}
assert_contains() { # name  file  needle
    if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 (missing '$3')"; fi
}
assert_not_contains() { # name  file  needle
    if grep -qF "$3" "$2"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi
}

reset_hosts() {
    printf '##\n# Host Database\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1\tlocalhost\n' \
        > "$FOCUS_BLOCKER_HOSTS"
    rm -rf "$FOCUS_BLOCKER_LOCKDIR"
    rm -f "$FOCUS_BLOCKER_HOSTS".focuson.* 2>/dev/null || true
}

default_blocklist() {
    printf '# comment line\nx.com\nwww.x.com\nbad domain with spaces\ninstagram.com\n' \
        > "$FOCUS_BLOCKER_BLOCKLIST"
}

run() { "$HELPER" "$@"; }

echo "Running helper tests against sandbox: $SANDBOX"
default_blocklist

# --- status / block / unblock basics ---------------------------------------
reset_hosts
assert_eq "status: initially unblocked" "$(run status)" "unblocked"

assert_eq "block: prints 'blocked'" "$(run block)" "blocked"
assert_eq "status: blocked after block" "$(run status)" "blocked"
assert_contains "block: adds IPv4 entry for x.com" "$FOCUS_BLOCKER_HOSTS" "0.0.0.0 x.com"
assert_contains "block: adds IPv6 entry for x.com" "$FOCUS_BLOCKER_HOSTS" ":: x.com"
assert_contains "block: includes instagram.com" "$FOCUS_BLOCKER_HOSTS" "0.0.0.0 instagram.com"

# --- input sanitation -------------------------------------------------------
assert_not_contains "block: drops malformed line" "$FOCUS_BLOCKER_HOSTS" "bad domain"
assert_not_contains "block: drops comment line" "$FOCUS_BLOCKER_HOSTS" "comment line"

# --- idempotency ------------------------------------------------------------
run block >/dev/null
n=$(grep -c '^0.0.0.0 x.com$' "$FOCUS_BLOCKER_HOSTS")
assert_eq "block: idempotent (one x.com entry after 2 blocks)" "$n" "1"
starts=$(grep -c "$MARK" "$FOCUS_BLOCKER_HOSTS")
assert_eq "block: exactly one managed section" "$starts" "1"

# --- round-trip restores the original file ----------------------------------
reset_hosts
cp "$FOCUS_BLOCKER_HOSTS" "$SANDBOX/orig"
run block >/dev/null
run unblock >/dev/null
if diff -q "$SANDBOX/orig" "$FOCUS_BLOCKER_HOSTS" >/dev/null; then
    ok "unblock: round-trip is byte-identical to original"
else
    bad "unblock: round-trip differs from original"
fi

# --- empty-base unblock writes a safe default, never empty / never blocked --
{ echo "# >>> focus-on block start (managed by FocusOn) >>>"
  echo "0.0.0.0 x.com"
  echo "# <<< focus-on block end <<<"; } > "$FOCUS_BLOCKER_HOSTS"
rm -rf "$FOCUS_BLOCKER_LOCKDIR"
run unblock >/dev/null
if [ -s "$FOCUS_BLOCKER_HOSTS" ]; then ok "unblock(empty-base): file is non-empty"; else bad "unblock(empty-base): file is EMPTY"; fi
assert_not_contains "unblock(empty-base): block removed" "$FOCUS_BLOCKER_HOSTS" "$MARK"
assert_contains "unblock(empty-base): restored localhost" "$FOCUS_BLOCKER_HOSTS" "localhost"

# --- stale lock (dead PID) is reclaimed -------------------------------------
reset_hosts
mkdir -p "$FOCUS_BLOCKER_LOCKDIR"
echo 999999 > "$FOCUS_BLOCKER_LOCKDIR/pid"   # a PID that is not alive
if run block >/dev/null 2>&1; then
    assert_contains "stale-lock: reclaimed and blocked" "$FOCUS_BLOCKER_HOSTS" "0.0.0.0 x.com"
else
    bad "stale-lock: helper failed instead of reclaiming"
fi
if [ -d "$FOCUS_BLOCKER_LOCKDIR" ]; then bad "stale-lock: lockdir leaked"; else ok "stale-lock: lockdir released"; fi

# --- live lock (alive PID) is respected; hosts untouched --------------------
reset_hosts
cp "$FOCUS_BLOCKER_HOSTS" "$SANDBOX/origLive"
mkdir -p "$FOCUS_BLOCKER_LOCKDIR"
echo "$$" > "$FOCUS_BLOCKER_LOCKDIR/pid"      # this shell is alive
if run block >/dev/null 2>&1; then
    bad "live-lock: helper ran despite a held lock"
else
    ok "live-lock: helper refused (exit non-zero)"
fi
if diff -q "$SANDBOX/origLive" "$FOCUS_BLOCKER_HOSTS" >/dev/null; then
    ok "live-lock: hosts left untouched"
else
    bad "live-lock: hosts was modified"
fi
rm -rf "$FOCUS_BLOCKER_LOCKDIR"

# --- stale temp files are swept --------------------------------------------
reset_hosts
touch "$FOCUS_BLOCKER_HOSTS.focuson.OLD1" "$FOCUS_BLOCKER_HOSTS.focuson.OLD2"
run block >/dev/null
if ls "$FOCUS_BLOCKER_HOSTS".focuson.* >/dev/null 2>&1; then
    bad "sweep: orphaned temp files remain"
else
    ok "sweep: orphaned temp files removed"
fi

# --- reconcile reads the state file (this is what the LaunchDaemon runs) ----
reset_hosts
printf 'block\n' > "$FOCUS_BLOCKER_STATE"
run reconcile >/dev/null
assert_eq "reconcile(state=block): blocked" "$(run status)" "blocked"

printf 'unblock\n' > "$FOCUS_BLOCKER_STATE"
run reconcile >/dev/null
assert_eq "reconcile(state=unblock): unblocked" "$(run status)" "unblocked"

rm -f "$FOCUS_BLOCKER_STATE"
reset_hosts
run reconcile >/dev/null
assert_eq "reconcile(no state file): defaults to blocked" "$(run status)" "blocked"

printf '   garbage \n' > "$FOCUS_BLOCKER_STATE"
reset_hosts
run reconcile >/dev/null
assert_eq "reconcile(garbage state): defaults to blocked" "$(run status)" "blocked"
rm -f "$FOCUS_BLOCKER_STATE"

# --- security: refuse a symlinked blocklist (don't follow into other files) -
reset_hosts
printf 'secrettoken123\n' > "$SANDBOX/secret"
rm -f "$FOCUS_BLOCKER_BLOCKLIST"
ln -s "$SANDBOX/secret" "$FOCUS_BLOCKER_BLOCKLIST"
run block >/dev/null
assert_not_contains "symlink blocklist: secret token NOT leaked into hosts" "$FOCUS_BLOCKER_HOSTS" "secrettoken123"
rm -f "$FOCUS_BLOCKER_BLOCKLIST"
default_blocklist   # restore a real file

# --- security: refuse a symlinked state file (reconcile -> default block) ---
reset_hosts
printf 'unblock\n' > "$SANDBOX/state-target"
rm -f "$FOCUS_BLOCKER_STATE"
ln -s "$SANDBOX/state-target" "$FOCUS_BLOCKER_STATE"
run reconcile >/dev/null
assert_eq "symlink state: refused -> defaults to blocked" "$(run status)" "blocked"
rm -f "$FOCUS_BLOCKER_STATE"

# --- security: a FIFO blocklist must not hang the root reader ---------------
reset_hosts
rm -f "$FOCUS_BLOCKER_BLOCKLIST"
mkfifo "$FOCUS_BLOCKER_BLOCKLIST"
run block >/dev/null 2>&1 &
bpid=$!
done_fifo=0
for _ in $(seq 1 50); do            # up to ~5s; O_NONBLOCK should finish instantly
    if ! kill -0 "$bpid" 2>/dev/null; then done_fifo=1; break; fi
    sleep 0.1
done
if [ "$done_fifo" = "1" ]; then
    wait "$bpid" 2>/dev/null || true
    ok "FIFO blocklist: helper finished without hanging"
    assert_not_contains "FIFO blocklist: no host entries added" "$FOCUS_BLOCKER_HOSTS" "0.0.0.0 "
else
    kill "$bpid" 2>/dev/null || true
    pkill -P "$bpid" 2>/dev/null || true
    bad "FIFO blocklist: helper hung (>5s)"
fi
rm -f "$FOCUS_BLOCKER_BLOCKLIST"
default_blocklist

# --- DoS guard: accepted host count is capped at MAX_HOSTS (5000) -----------
reset_hosts
awk 'BEGIN { for (i = 0; i < 6000; i++) print "h" i ".example.com" }' > "$FOCUS_BLOCKER_BLOCKLIST"
run block >/dev/null
n=$(grep -c '^0.0.0.0 ' "$FOCUS_BLOCKER_HOSTS")
if [ "$n" -le 5000 ]; then ok "host cap: accepted $n hosts (<= 5000)"; else bad "host cap: accepted $n hosts (> 5000)"; fi
default_blocklist

# --- idempotency: re-running block when already blocked is a no-op ----------
reset_hosts
run block >/dev/null
second="$(run block)"   # should still report blocked and not error out
assert_eq "block idempotent: second block still reports 'blocked'" "$second" "blocked"

# --- bad usage --------------------------------------------------------------
if run bogus >/dev/null 2>&1; then bad "usage: bogus command should fail"; else ok "usage: bogus command exits non-zero"; fi

echo "----------------------------------------"
echo "Helper tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
