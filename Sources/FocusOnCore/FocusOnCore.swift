import Foundation

/// What the privileged helper must do to reach the user's desired state.
public enum HelperAction: Equatable {
    case block
    case unblock
    case none
}

/// Decides the action needed to reconcile the actual `/etc/hosts` state with
/// the user's intent.
///
/// - Parameters:
///   - shouldBlock: the user's persisted intent (blocking enabled?).
///   - isPaused: whether a temporary pause is in effect.
///   - currentlyBlocked: whether `/etc/hosts` currently contains the block.
public func helperAction(shouldBlock: Bool, isPaused: Bool, currentlyBlocked: Bool) -> HelperAction {
    let wantBlocked = shouldBlock && !isPaused
    if wantBlocked && !currentlyBlocked { return .block }
    if !wantBlocked && currentlyBlocked { return .unblock }
    return .none
}

/// The token the app writes to the desired-state file that the root
/// LaunchDaemon watches. Effective blocking is "on" only when the user wants
/// it AND no temporary pause is in effect.
public func stateToken(shouldBlock: Bool, isPaused: Bool) -> String {
    return (shouldBlock && !isPaused) ? "block" : "unblock"
}

/// The human-readable status shown in the menu header and tooltip.
public func statusLine(shouldBlock: Bool, isPaused: Bool, remainingMinutes: Int) -> String {
    if shouldBlock && isPaused {
        let mins = max(1, remainingMinutes)
        return "Paused — resumes in \(mins) min"
    } else if shouldBlock {
        return "Blocking is ON"
    } else {
        return "Blocking is OFF"
    }
}
