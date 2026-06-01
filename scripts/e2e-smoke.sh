#!/bin/bash
#
# End-to-end smoke test against the INSTALLED FocusOn daemon and the LIVE
# /etc/hosts. It proves the no-sudo path: it ONLY writes the user-owned state
# file (no sudo, no password) and checks that the root LaunchDaemon reconciles
# /etc/hosts in response.
#
# It snapshots your current state, exercises block -> verify -> unblock ->
# verify, and restores whatever state you started in.
#
# Usage:
#   bash tests/e2e-smoke.sh          # prompts for confirmation
#   bash tests/e2e-smoke.sh --yes    # no prompt (for unattended runs)
#
# Requires: ./install.sh to have been run (daemon + state file in place).

set -uo pipefail

STATE="/usr/local/etc/focus-on/state"
HOSTS="/etc/hosts"
DAEMON_PLIST="/Library/LaunchDaemons/com.focuson.daemon.plist"
MARK="focus-on block start"
PROBE="x.com"   # a domain from the default blocklist

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# --- preflight --------------------------------------------------------------
[ -f "$DAEMON_PLIST" ] || { echo "ERROR: $DAEMON_PLIST missing. Run ./install.sh first." >&2; exit 2; }
[ -f "$STATE" ]        || { echo "ERROR: $STATE missing. Run ./install.sh first." >&2; exit 2; }
if [ ! -w "$STATE" ]; then
    echo "ERROR: $STATE is not writable by you — the no-sudo path won't work." >&2
    exit 2
fi

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1
if [ "$ASSUME_YES" -ne 1 ]; then
    echo "This writes $STATE (no sudo) and lets the daemon change $HOSTS,"
    echo "then restores your starting state."
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# --- snapshot + restore-on-exit --------------------------------------------
ORIGINAL_STATE="$(tr -d '[:space:]' < "$STATE")"
echo "Starting state token: '$ORIGINAL_STATE'"

restore() {
    echo "==> Restoring original state ('$ORIGINAL_STATE')"
    printf '%s\n' "${ORIGINAL_STATE:-block}" > "$STATE"
}
trap restore EXIT

# Wait (up to ~8s) for /etc/hosts to reach the expected state.
# $1 = "blocked" | "unblocked"
wait_for() {
    local want="$1" i
    for i in $(seq 1 40); do
        if [ "$want" = "blocked" ]; then
            grep -qF "$MARK" "$HOSTS" && return 0
        else
            grep -qF "$MARK" "$HOSTS" || return 0
        fi
        sleep 0.2
    done
    return 1
}

# --- block via the state file (NO sudo) -------------------------------------
echo "==> writing 'block' to state file (no sudo)"
printf 'block\n' > "$STATE"
if wait_for blocked; then ok "daemon applied block to $HOSTS"; else bad "daemon did not block within timeout"; fi
grep -qE "^0\.0\.0\.0[[:space:]]+$PROBE\$" "$HOSTS" && ok "$PROBE routed to 0.0.0.0" || bad "$PROBE not routed in $HOSTS"

# --- unblock via the state file (NO sudo) -----------------------------------
echo "==> writing 'unblock' to state file (no sudo)"
printf 'unblock\n' > "$STATE"
if wait_for unblocked; then ok "daemon removed block from $HOSTS"; else bad "daemon did not unblock within timeout"; fi
[ -s "$HOSTS" ] && ok "$HOSTS is non-empty after unblock" || bad "$HOSTS is EMPTY after unblock"

echo "----------------------------------------"
echo "E2E smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
