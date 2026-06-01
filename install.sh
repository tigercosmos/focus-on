#!/bin/bash
#
# Installs FocusOn:
#   - builds and copies FocusOn.app to /Applications
#   - installs the helper to /Library/PrivilegedHelperTools/com.focuson.helper
#   - installs the editable blocklist + a user-owned state file to
#     /usr/local/etc/focus-on/
#   - installs a root LaunchDaemon that watches the state file/blocklist and
#     reconciles /etc/hosts — so the app NEVER needs sudo after this
#   - installs a LaunchAgent so the menu bar app starts at login
#
# Run it normally (NOT with sudo): ./install.sh
# You'll be prompted for your password once for the privileged steps.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Root phase — re-executed under sudo for the steps that need root.
# ---------------------------------------------------------------------------
if [ "${FOCUSON_ROOT_PHASE:-}" = "1" ]; then
    TARGET_USER="$FOCUSON_TARGET_USER"
    SRC="$FOCUSON_SRC"

    # The daemon runs this AS ROOT, so it must live in a directory that is NOT
    # user-writable. /usr/local/bin is frequently user/group-writable (Homebrew),
    # which would let a non-root user swap the binary and gain root — so we use
    # the conventional privileged-helper location instead.
    install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
    install -m 755 -o root -g wheel "$SRC/helper/focus-blocker" \
        /Library/PrivilegedHelperTools/com.focuson.helper
    rm -f /usr/local/bin/focus-blocker   # remove binary left by older installs

    # Config dir + blocklist are owned by the user so the app can write the
    # state file and edit the blocklist with NO privileges. Refuse to operate on
    # a pre-planted symlink (would let a same-user attacker redirect root's writes).
    if [ -L /usr/local/etc/focus-on ]; then
        echo "ERROR: /usr/local/etc/focus-on is a symlink; refusing to install." >&2
        exit 1
    fi
    install -d -m 755 -o "$TARGET_USER" /usr/local/etc/focus-on
    if [ ! -f /usr/local/etc/focus-on/blocklist.txt ]; then
        install -m 644 -o "$TARGET_USER" "$SRC/config/blocklist.txt" /usr/local/etc/focus-on/blocklist.txt
    fi
    # NOTE: the state file is created by the app (running as the user) — root
    # never creates or chowns it, so it can't be tricked into following a
    # symlink the user planted at that path.

    # Remove any sudoers rule from older (sudo-based) installs — no longer used.
    rm -f /etc/sudoers.d/focus-on

    # The root LaunchDaemon: launchd runs it (as root) whenever the state file
    # or blocklist changes, and at load/boot.
    DAEMON_PLIST=/Library/LaunchDaemons/com.focuson.daemon.plist
    cat > "$DAEMON_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.focuson.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.focuson.helper</string>
        <string>reconcile</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/usr/local/etc/focus-on/state</string>
        <string>/usr/local/etc/focus-on/blocklist.txt</string>
    </array>
    <key>RunAtLoad</key><true/>
    <!-- Backstop in case a WatchPaths event is ever missed; reconcile is a
         no-op when /etc/hosts already matches, so this doesn't churn DNS. -->
    <key>StartInterval</key><integer>3600</integer>
    <key>StandardErrorPath</key><string>/var/log/focus-on.daemon.log</string>
    <key>StandardOutPath</key><string>/var/log/focus-on.daemon.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$DAEMON_PLIST"
    chmod 644 "$DAEMON_PLIST"
    launchctl bootout system/com.focuson.daemon 2>/dev/null || true
    if ! launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null; then
        launchctl load -w "$DAEMON_PLIST" 2>/dev/null || true
    fi
    launchctl kickstart -k system/com.focuson.daemon 2>/dev/null || true

    # Stage the new bundle first; only remove the old one once the copy
    # succeeds, so a failed copy never leaves /Applications without an app.
    APP_NEW=/Applications/FocusOn.app.new
    rm -rf "$APP_NEW"
    cp -R "$SRC/build/FocusOn.app" "$APP_NEW"
    rm -rf /Applications/FocusOn.app
    mv "$APP_NEW" /Applications/FocusOn.app

    exit 0
fi

# ---------------------------------------------------------------------------
# User phase.
# ---------------------------------------------------------------------------
"$DIR/build.sh"

echo "==> Installing privileged components (you'll be asked for your password once)"
sudo env \
    FOCUSON_ROOT_PHASE=1 \
    FOCUSON_TARGET_USER="$(id -un)" \
    FOCUSON_SRC="$DIR" \
    bash "${BASH_SOURCE[0]}"

echo "==> Creating state file (as you, not root)"
STATE="/usr/local/etc/focus-on/state"
if [ ! -e "$STATE" ]; then
    printf 'block\n' > "$STATE"   # block by default; owned by you
fi

echo "==> Installing Login item (starts at login)"
PLIST="$HOME/Library/LaunchAgents/com.focuson.app.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.focuson.app</string>
    <key>ProgramArguments</key>
    <array><string>/Applications/FocusOn.app/Contents/MacOS/FocusOn</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
# Kill any stale/duplicate instance of THIS app (match the full binary path, not
# just the process name) and WAIT for it to fully exit. Otherwise the freshly
# loaded copy's single-instance lock would see the still-exiting old process and
# bow out — leaving nothing running.
APP_BIN="/Applications/FocusOn.app/Contents/MacOS/FocusOn"
pkill -f "$APP_BIN" 2>/dev/null || true
for _ in $(seq 1 50); do                       # up to ~5s
    pgrep -f "$APP_BIN" >/dev/null 2>&1 || break
    sleep 0.1
done
# RunAtLoad=true means loading the agent already launches the app — do NOT also
# `open` it, or you'd get two menu bar instances.
launchctl load -w "$PLIST"

echo ""
echo "Done. Look for the shield icon in your menu bar."
echo "Blocking is ON by default. Click the icon to pause or turn it off."
