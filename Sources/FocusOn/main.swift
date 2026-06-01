import Cocoa
import FocusOnCore

// MARK: - Configuration

let blocklistPath = "/usr/local/etc/focus-on/blocklist.txt"
let statePath = "/usr/local/etc/focus-on/state"
let hostsPath = "/etc/hosts"
let blockMarker = "focus-on block start"
let launchAgentLabel = "com.focuson.app"
let appExecutablePath = "/Applications/FocusOn.app/Contents/MacOS/FocusOn"

// MARK: - Shell helpers

/// Runs a command and returns whether it exited 0. Output is discarded.
/// Used only for the user-level LaunchAgent (no privileges).
@discardableResult
func runShell(_ launchPath: String, _ arguments: [String]) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

/// Writes the desired-state token to the user-owned state file. The root
/// LaunchDaemon (installed once) watches this file and reconciles /etc/hosts.
/// Written in place (no atomic rename) so launchd's WatchPaths reliably fires.
/// No privileges required — the app owns this file.
@discardableResult
func writeStateToken(_ token: String) -> Bool {
    do {
        try token.write(toFile: statePath, atomically: false, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

/// Reads /etc/hosts directly (world-readable) to detect the managed block —
/// our source of truth for what actually happened.
func isCurrentlyBlocked() -> Bool {
    guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
        return false
    }
    return content.contains(blockMarker)
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pauseEndDate: Date?
    private var tickTimer: Timer?
    private let defaults = UserDefaults.standard

    /// Serial background queue for polling /etc/hosts (which sleeps), so the
    /// confirmation loop never blocks the main thread or overlaps itself.
    private let helperQueue = DispatchQueue(label: "com.focuson.poll")
    /// Guards against stacking multiple error alerts.
    private var errorAlertVisible = false

    /// The user's intent: should distracting sites be blocked? Defaults to ON.
    private var shouldBlock: Bool {
        get {
            if defaults.object(forKey: "shouldBlock") == nil { return true }
            return defaults.bool(forKey: "shouldBlock")
        }
        set { defaults.set(newValue, forKey: "shouldBlock") }
    }

    /// Whether a temporary pause is currently in effect.
    private var isPaused: Bool {
        guard let end = pauseEndDate else { return false }
        return end > Date()
    }

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Ensure the state file exists (we, the user, create it — root never
        // chowns a user-controlled path) and re-assert intent on launch, then
        // confirm the daemon applied it.
        requestState(blocked: shouldBlock && !isPaused, force: true)
        updateIcon()

        // Re-check pause expiry when the machine wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        if let end = pauseEndDate, Date() >= end {
            resumeFromPause()
        }
    }

    // MARK: State
    //
    // All state (shouldBlock, pauseEndDate, timers, UI) lives on the main
    // thread. To change the block we only write a user-owned state file; the
    // root LaunchDaemon picks it up and rewrites /etc/hosts asynchronously. We
    // then poll /etc/hosts (off-main) to confirm the change actually landed,
    // and surface an alert if it never does (daemon missing / not installed).

    /// Writes the desired state and waits for the daemon to apply it.
    /// Call on the main thread.
    private func applyEffectiveState() {
        switch helperAction(shouldBlock: shouldBlock, isPaused: isPaused, currentlyBlocked: isCurrentlyBlocked()) {
        case .none:
            updateIcon() // already in the desired state; nothing to trigger
        case .block:
            requestState(blocked: true, force: false)
        case .unblock:
            requestState(blocked: false, force: false)
        }
    }

    /// Writes the state token (optionally even when already in that state, to
    /// force a re-apply after a blocklist edit) and confirms via polling.
    private func requestState(blocked: Bool, force: Bool) {
        let token = blocked ? "block" : "unblock"
        if !force && isCurrentlyBlocked() == blocked {
            updateIcon()
            return
        }
        guard writeStateToken(token) else {
            updateIcon()
            reportFailure(expectedBlocked: blocked) // can't write — likely not installed
            return
        }
        updateIcon() // optimistic
        confirmState(expectedBlocked: blocked, retriesLeft: 1)
    }

    /// Polls /etc/hosts off the main thread until it matches the expectation or
    /// times out; on first timeout, re-pokes the state file once to re-trigger
    /// the daemon's WatchPaths, then alerts if it still hasn't applied.
    private func confirmState(expectedBlocked: Bool, retriesLeft: Int) {
        helperQueue.async { [weak self] in
            var matched = false
            for _ in 0..<25 {                       // ~5s (25 × 0.2s)
                if isCurrentlyBlocked() == expectedBlocked { matched = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if matched {
                    self.updateIcon()
                } else if retriesLeft > 0 {
                    _ = writeStateToken(expectedBlocked ? "block" : "unblock")
                    self.confirmState(expectedBlocked: expectedBlocked, retriesLeft: retriesLeft - 1)
                } else {
                    self.updateIcon()
                    self.reportFailure(expectedBlocked: expectedBlocked)
                }
            }
        }
    }

    private func reportFailure(expectedBlocked: Bool) {
        guard !errorAlertVisible else { return }
        errorAlertVisible = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = expectedBlocked
            ? "FocusOn couldn’t block the sites"
            : "FocusOn couldn’t unblock the sites"
        alert.informativeText = "The change to /etc/hosts didn’t take effect. "
            + "The FocusOn background service may not be installed or running — "
            + "try reinstalling with ./install.sh."
        alert.runModal()
        errorAlertVisible = false
    }

    @objc private func toggleBlocking() {
        cancelPause()
        shouldBlock.toggle()
        updateIcon()            // optimistic; confirmState reconciles
        applyEffectiveState()
    }

    @objc private func reloadBlocklist() {
        // The daemon also watches the blocklist, so edits auto-apply — this is
        // a manual "apply now". Force a re-write so the daemon re-reads the
        // (possibly edited) list even if the block state is unchanged.
        if shouldBlock && !isPaused {
            requestState(blocked: true, force: true)
        } else {
            applyEffectiveState()
        }
    }

    @objc private func pause(_ sender: NSMenuItem) {
        let minutes = sender.tag
        pauseEndDate = Date().addingTimeInterval(Double(minutes) * 60)
        updateIcon()            // optimistic
        applyEffectiveState()   // unblock now
        startTick()
    }

    @objc private func resumeNow() {
        resumeFromPause()
    }

    private func resumeFromPause() {
        cancelPause()
        updateIcon()            // optimistic
        applyEffectiveState()   // re-block
    }

    private func cancelPause() {
        pauseEndDate = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let end = self.pauseEndDate, Date() >= end {
                self.resumeFromPause()
            } else {
                self.updateIcon()
            }
        }
    }

    // MARK: Login item (LaunchAgent)

    private func launchAgentPath() -> String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath())
    }

    @objc private func toggleLogin() {
        let path = launchAgentPath()
        if launchAgentInstalled() {
            runShell("/bin/launchctl", ["unload", path])
            try? FileManager.default.removeItem(atPath: path)
        } else {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(appExecutablePath)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><false/>
                <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: path, atomically: true, encoding: .utf8)
            runShell("/bin/launchctl", ["load", "-w", path])
        }
    }

    @objc private func editBlocklist() {
        NSWorkspace.shared.open(URL(fileURLWithPath: blocklistPath))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if shouldBlock && isPaused {
            symbol = "hourglass"
        } else if shouldBlock {
            symbol = "shield.lefthalf.filled"
        } else {
            symbol = "shield.slash"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "FocusOn") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = shouldBlock ? (isPaused ? "⏸" : "🛡") : "○"
        }
        button.toolTip = currentStatusLine()
    }

    private func currentStatusLine() -> String {
        let remaining = pauseEndDate.map { Int(ceil($0.timeIntervalSinceNow / 60)) } ?? 0
        return statusLine(shouldBlock: shouldBlock, isPaused: isPaused, remainingMinutes: remaining)
    }

    // MARK: Menu (rebuilt each time it opens so the countdown stays fresh)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let end = pauseEndDate, Date() >= end {
            resumeFromPause()
        }
        menu.removeAllItems()

        let header = NSMenuItem(title: currentStatusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if shouldBlock && !isPaused {
            let pauseItem = NSMenuItem(title: "Pause temporarily", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (label, mins) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120)] {
                let it = NSMenuItem(title: label, action: #selector(pause(_:)), keyEquivalent: "")
                it.tag = mins
                it.target = self
                sub.addItem(it)
            }
            pauseItem.submenu = sub
            menu.addItem(pauseItem)

            addItem(to: menu, "Turn Blocking Off", #selector(toggleBlocking))
            addItem(to: menu, "Reload Blocklist", #selector(reloadBlocklist))
        } else if shouldBlock && isPaused {
            addItem(to: menu, "Resume Blocking Now", #selector(resumeNow))
            addItem(to: menu, "Turn Blocking Off", #selector(toggleBlocking))
        } else {
            addItem(to: menu, "Turn Blocking On", #selector(toggleBlocking))
        }

        menu.addItem(.separator())
        addItem(to: menu, "Edit Blocklist…", #selector(editBlocklist))
        let login = addItem(to: menu, "Open at Login", #selector(toggleLogin))
        login.state = launchAgentInstalled() ? .on : .off

        menu.addItem(.separator())
        let quitItem = addItem(to: menu, "Quit FocusOn", #selector(quit))
        quitItem.keyEquivalent = "q"
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
}

// MARK: - Entry point

let delegate = AppController() // retained for the program's lifetime
let app = NSApplication.shared
app.delegate = delegate
app.run()
