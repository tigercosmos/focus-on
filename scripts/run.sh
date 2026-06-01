#!/bin/bash
#
# Runs the automated test suite locally:
#   1. bash -n syntax check of every shell script
#   2. helper unit/integration tests (scripts/test-helper.sh)
#   3. swift build (compiles the package + app)
#   4. swift test (XCTest) — only if XCTest is available (needs full Xcode);
#      skipped with a notice when running on Command Line Tools alone.
#
# The e2e smoke test is NOT run here (it touches the live system) — run it
# manually with: bash scripts/e2e-smoke.sh
#
# Usage: bash scripts/run.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

rc=0

echo "== 1. shell syntax =="
for f in helper/focus-blocker install.sh uninstall.sh build.sh scripts/*.sh; do
    if bash -n "$f"; then echo "  ok: $f"; else echo "  FAIL: $f"; rc=1; fi
done

echo "== 2. helper tests =="
bash scripts/test-helper.sh || rc=1

echo "== 3. swift build =="
swift build || rc=1

echo "== 4. swift test (XCTest) =="
if xcrun --find xctest >/dev/null 2>&1; then
    swift test || rc=1
else
    echo "  SKIPPED: XCTest unavailable (Command Line Tools only)."
    echo "  Install Xcode and 'sudo xcode-select -s /Applications/Xcode.app' to run these,"
    echo "  or rely on CI (GitHub Actions macos runner) where they run automatically."
fi

echo "----------------------------------------"
[ "$rc" -eq 0 ] && echo "ALL GREEN" || echo "SOME CHECKS FAILED"
exit "$rc"
