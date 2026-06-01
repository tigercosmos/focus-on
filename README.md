# FocusOn

A tiny macOS menu bar app that blocks distracting websites (Threads, Facebook,
X, Instagram, …) so you can stay focused — even when you forget you shouldn't be
browsing them. It runs quietly in the background and starts at login, but you
can pause or turn it off whenever you genuinely need to.

## How it works

Blocking is done by adding a managed section to `/etc/hosts` that routes the
listed domains to `0.0.0.0`, so they fail to load in every browser, system‑wide.
The DNS cache is flushed on each change.

Editing `/etc/hosts` needs root — but the app itself never uses `sudo`. Instead:

- A one‑time `install.sh` (the only step that asks for your password) drops a
  **root LaunchDaemon** (`com.focuson.daemon`) and a small worker
  (`focus-blocker`).
- The daemon **watches a user‑owned state file** (`/usr/local/etc/focus-on/state`)
  and the blocklist. Whenever either changes, launchd runs the worker **as root**
  to reconcile `/etc/hosts`.
- To block/unblock/pause, the app just **writes `block` or `unblock` into that
  state file** — a plain user‑owned file, no privileges. Editing the blocklist
  auto‑applies the same way.

So `sudo` happens exactly once (install); every toggle afterward is a password‑
free file write that the already‑root daemon picks up. (See `git log` / the
discussion for why this beats per‑toggle `sudo`.)

```
Package.swift                  SwiftPM manifest (core lib + app + test target)
Sources/FocusOnCore/           pure, dependency-free logic (unit tested)
Sources/FocusOn/main.swift     the menu bar app (Swift / AppKit)
Tests/FocusOnCoreTests/        XCTest unit tests for FocusOnCore
helper/focus-blocker           worker: block | unblock | status | reconcile
config/blocklist.txt           the default list of domains to block (editable)
app/Info.plist                 app bundle metadata (menu bar / no Dock icon)
build.sh                       swift build + assembles build/FocusOn.app
install.sh                     builds + installs everything (run normally, not as root)
uninstall.sh                   removes everything and restores /etc/hosts
scripts/test-helper.sh         automated helper tests (no root, sandboxed)
scripts/e2e-smoke.sh           opt-in end-to-end test against the live system
scripts/run.sh                 runs the whole local suite
```

At runtime the pieces are:

```
FocusOn.app (you)                      root LaunchDaemon (launchd)
  writes "block"/"unblock"  ──────▶    com.focuson.daemon
  to .../focus-on/state                WatchPaths: state + blocklist
        │                                     │  runs focus-blocker reconcile
        │                                     ▼
        └────── polls /etc/hosts ◀──── atomically rewrites /etc/hosts (as root)
                to confirm it landed
```

## Install

```sh
./install.sh
```

You'll be prompted for your password once. When it's done, look for the shield
icon in your menu bar. Blocking is ON by default.

## Using it

Click the menu bar icon:

- **Pause temporarily** — 15 / 30 / 60 / 120 minutes. Sites unblock now and
  re-block automatically when the timer ends.
- **Turn Blocking Off / On** — a manual toggle that sticks across restarts.
- **Reload Blocklist** — forces an immediate re-apply (edits also auto-apply,
  since the daemon watches the blocklist file).
- **Edit Blocklist…** — opens the installed copy at
  `/usr/local/etc/focus-on/blocklist.txt`. Add or remove domains (one per line)
  and save — the daemon applies it automatically.
- **Open at Login** — toggles whether FocusOn starts automatically.
- **Quit FocusOn** — quits the menu bar app. (Already-blocked sites stay
  blocked; the block lives in `/etc/hosts`, not in the running app.)

The icon shows state at a glance: a shield when ON, an hourglass when paused, a
crossed-out shield when OFF.

## Tests

```sh
bash scripts/run.sh        # syntax check + helper tests + swift build + swift test
```

- **Helper tests** (`scripts/test-helper.sh`) — fully automated, no root: they point
  the helper at a sandbox hosts file via `FOCUS_BLOCKER_*` env overrides and cover
  block/unblock round-trips, idempotency, input sanitation, the stale-lock reclaim
  vs. live-lock behaviour, the empty-base `unblock` safety net, temp-file sweep, and
  the daemon's `reconcile` reading of the state file.
- **Swift unit tests** (`Tests/FocusOnCoreTests`) — XCTest over the pure logic in
  `FocusOnCore` (the block/unblock decision, the state-file token, the status text).
  `swift test` needs full Xcode; with Command Line Tools only, `scripts/run.sh`
  skips it and it runs in CI instead.
- **E2E smoke test** (`scripts/e2e-smoke.sh`) — opt-in; it proves the no-sudo path
  by writing only the user-owned state file and checking the daemon reconciles the
  live `/etc/hosts`. Run it by hand after installing:
  ```sh
  bash scripts/e2e-smoke.sh      # prompts before changing anything; restores your state
  ```
- **CI** — `.github/workflows/ci.yml` runs the shell syntax check, helper tests,
  `swift build`, `swift test`, and the bundle assembly on every push/PR.

## Notes

- This is friction, not a vault: anyone with admin rights can edit `/etc/hosts`
  or unload the daemon by hand. It's designed to stop the absent‑minded "oops I
  opened X again" reflex, which is the thing it's good at.
- The user-owned state file is read by a root daemon, but only as *data*: it's
  never executed, and every blocklist hostname is sanitised before it reaches
  `/etc/hosts`, so the worst a tampered file can do is block extra sites. The
  daemon opens those files with `O_NOFOLLOW`/`O_NONBLOCK` and `fstat`s the open
  descriptor, so a swapped-in symlink or FIFO can't trick it (no TOCTOU).
- The app is built locally and unsigned. Because it isn't downloaded from the
  internet it has no quarantine flag, so Gatekeeper runs it without complaint.

## Uninstall

```sh
./uninstall.sh
```
