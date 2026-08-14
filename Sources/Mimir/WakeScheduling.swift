import Foundation

/// Pure decisions for polling around sleep/wake. Adapted from codex-island (MIT).
/// No AppKit or store dependencies so the boundaries stay unit-testable.
enum WakeScheduling {
    /// How late a repeating-timer fire must be before we call it a wake catch-up rather than
    /// run-loop jitter. Tolerance and a busy main thread account for seconds; only sleep
    /// accounts for minutes.
    static let overdueSlack: TimeInterval = 120

    /// How long after wake to hold the first poll: long enough for Wi-Fi to re-associate,
    /// for the reconnect burst of dormant sessions to pass, and for a token that expired
    /// mid-sleep to be refreshable; short enough to update within the first minute.
    static let graceDelay: TimeInterval = 60

    /// True when a repeating-timer fire arrives so far past its schedule that the machine must
    /// have slept through the fire date. The run loop delivers exactly one immediate catch-up
    /// fire on wake — polling right then races the half-up network and the wake burst, which is
    /// how "rate limited" / "token expired" land as the lid opens.
    static func isOverdueFire(now: Date, expected: Date?) -> Bool {
        guard let expected else { return false }
        return now.timeIntervalSince(expected) > overdueSlack
    }

    /// Whether a wake warrants an off-schedule refresh. A lid flip after a short nap doesn't —
    /// the data is still fresher than one poll interval.
    static func shouldRefreshAfterWake(lastPoll: Date?, now: Date, pollInterval: TimeInterval) -> Bool {
        guard let lastPoll else { return true }
        return now.timeIntervalSince(lastPoll) >= pollInterval
    }
}
