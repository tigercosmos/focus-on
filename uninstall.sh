#!/bin/bash
#
# Removes everything install.sh added and restores /etc/hosts.
# Run normally (NOT with sudo): ./uninstall.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Root phase.
# ---------------------------------------------------------------------------
if [ "${FOCUSON_ROOT_PHASE:-}" = "1" ]; then
    # Stop the root LaunchDaemon first so it can't re-apply the block while we
    # tear things down.
    launchctl bootout system/com.focuson.daemon 2>/dev/null \
        || launchctl unload /Library/LaunchDaemons/com.focuson.daemon.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/com.focuson.daemon.plist

    # Clean the managed block out of /etc/hosts before removing the helper.
    HELPER=/Library/PrivilegedHelperTools/com.focuson.helper
    if [ -x "$HELPER" ]; then
        "$HELPER" unblock 2>/dev/null || true
    else
        # Helper missing/broken: strip the managed block directly so we never
        # leave a stale block behind in /etc/hosts.
        MARK_START="# >>> focus-on block start (managed by FocusOn) >>>"
        MARK_END="# <<< focus-on block end <<<"
        if grep -qF "$MARK_START" /etc/hosts 2>/dev/null; then
            TMP="$(mktemp /etc/hosts.focuson.XXXXXX)"
            awk -v s="$MARK_START" -v e="$MARK_END" '
                $0 == s { skip = 1; next }
                $0 == e { skip = 0; next }
                skip != 1 { print }
            ' /etc/hosts > "$TMP"
            # Same safety net as the helper: never write an empty hosts file.
            if [ ! -s "$TMP" ]; then
                printf '##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1\tlocalhost\n' > "$TMP"
            fi
            chown root:wheel "$TMP" 2>/dev/null || true
            chmod 644 "$TMP"
            mv -f "$TMP" /etc/hosts
            dscacheutil -flushcache 2>/dev/null || true
            killall -HUP mDNSResponder 2>/dev/null || true
        fi
    fi
    rm -f "$HELPER"
    rm -f /usr/local/bin/focus-blocker   # remove binary left by older installs
    # Remove any sudoers rule left by older (sudo-based) installs.
    rm -f /etc/sudoers.d/focus-on
    if [ -e /etc/sudoers.d/focus-on ]; then
        echo "WARNING: could not remove /etc/sudoers.d/focus-on — please delete it manually." >&2
    fi
    rm -rf /usr/local/etc/focus-on
    rm -f /var/log/focus-on.daemon.log
    rm -rf /Applications/FocusOn.app
    exit 0
fi

# ---------------------------------------------------------------------------
# User phase.
# ---------------------------------------------------------------------------
PLIST="$HOME/Library/LaunchAgents/com.focuson.app.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

osascript -e 'quit app "FocusOn"' 2>/dev/null || true
killall FocusOn 2>/dev/null || true

echo "==> Removing privileged components (you'll be asked for your password)"
sudo env FOCUSON_ROOT_PHASE=1 bash "${BASH_SOURCE[0]}"

echo "Uninstalled FocusOn. Your hosts file has been restored."
