import XCTest
@testable import FocusOnCore

final class FocusOnCoreTests: XCTestCase {

    // MARK: helperAction — the block/unblock decision

    func testActionBlocksWhenWantedButNotBlocked() {
        XCTAssertEqual(helperAction(shouldBlock: true, isPaused: false, currentlyBlocked: false), .block)
    }

    func testActionUnblocksWhenNotWantedButBlocked() {
        XCTAssertEqual(helperAction(shouldBlock: false, isPaused: false, currentlyBlocked: true), .unblock)
    }

    func testActionNoneWhenAlreadyInDesiredState() {
        XCTAssertEqual(helperAction(shouldBlock: true, isPaused: false, currentlyBlocked: true), .none)
        XCTAssertEqual(helperAction(shouldBlock: false, isPaused: false, currentlyBlocked: false), .none)
    }

    func testPauseUnblocksEvenWhenShouldBlock() {
        // Paused => effective intent is "not blocked", so a live block must come off.
        XCTAssertEqual(helperAction(shouldBlock: true, isPaused: true, currentlyBlocked: true), .unblock)
        // ...and if already unblocked while paused, nothing to do.
        XCTAssertEqual(helperAction(shouldBlock: true, isPaused: true, currentlyBlocked: false), .none)
    }

    func testActionIsExhaustiveAcrossAllInputs() {
        // Every combination resolves to exactly one well-defined action.
        for s in [false, true] {
            for p in [false, true] {
                for b in [false, true] {
                    let want = s && !p
                    let action = helperAction(shouldBlock: s, isPaused: p, currentlyBlocked: b)
                    switch action {
                    case .block: XCTAssertTrue(want && !b)
                    case .unblock: XCTAssertTrue(!want && b)
                    case .none: XCTAssertEqual(want, b)
                    }
                }
            }
        }
    }

    // MARK: stateToken — what gets written to the daemon's state file

    func testStateTokenBlocksWhenIntended() {
        XCTAssertEqual(stateToken(shouldBlock: true, isPaused: false), "block")
    }

    func testStateTokenUnblocksWhenOffOrPaused() {
        XCTAssertEqual(stateToken(shouldBlock: false, isPaused: false), "unblock")
        XCTAssertEqual(stateToken(shouldBlock: true, isPaused: true), "unblock")
        XCTAssertEqual(stateToken(shouldBlock: false, isPaused: true), "unblock")
    }

    func testStateTokenAgreesWithHelperAction() {
        // The token the app writes must never contradict the action decider.
        for s in [false, true] {
            for p in [false, true] {
                let token = stateToken(shouldBlock: s, isPaused: p)
                // From an unblocked machine, "block" intent => .block, else .none.
                let fromUnblocked = helperAction(shouldBlock: s, isPaused: p, currentlyBlocked: false)
                if token == "block" { XCTAssertEqual(fromUnblocked, .block) }
                else { XCTAssertEqual(fromUnblocked, .none) }
            }
        }
    }

    // MARK: statusLine — the menu/tooltip text

    func testStatusLineOn() {
        XCTAssertEqual(statusLine(shouldBlock: true, isPaused: false, remainingMinutes: 0), "Blocking is ON")
    }

    func testStatusLineOff() {
        XCTAssertEqual(statusLine(shouldBlock: false, isPaused: false, remainingMinutes: 0), "Blocking is OFF")
        // OFF takes precedence regardless of stale pause inputs.
        XCTAssertEqual(statusLine(shouldBlock: false, isPaused: true, remainingMinutes: 42), "Blocking is OFF")
    }

    func testStatusLinePausedShowsMinutes() {
        XCTAssertEqual(statusLine(shouldBlock: true, isPaused: true, remainingMinutes: 12), "Paused — resumes in 12 min")
    }

    func testStatusLinePausedClampsToAtLeastOneMinute() {
        XCTAssertEqual(statusLine(shouldBlock: true, isPaused: true, remainingMinutes: 0), "Paused — resumes in 1 min")
        XCTAssertEqual(statusLine(shouldBlock: true, isPaused: true, remainingMinutes: -5), "Paused — resumes in 1 min")
    }
}
