import XCTest
import MimirShared
@testable import Mimir

/// Covers the pure parsing/math helpers in LiveUsageDataSource — the fragile, reverse-engineered
/// logic that turns raw provider JSON into percentages and dates. LiveUsageDataSource is stateless,
/// so a throwaway instance is fine.
final class UsageParsingTests: XCTestCase {
    private let ds = LiveUsageDataSource()

    func testRemainingPercentFromUsed() {
        XCTAssertEqual(ds.remainingPercent(fromUsed: 0), 100)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 100), 0)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 30), 70)
        XCTAssertEqual(ds.remainingPercent(fromUsed: 30.4), 70)   // rounds
        XCTAssertEqual(ds.remainingPercent(fromUsed: 150), 0)     // clamps low
        XCTAssertEqual(ds.remainingPercent(fromUsed: -10), 100)   // clamps high
    }

    func testDoubleValueCoercions() {
        XCTAssertEqual(ds.doubleValue(5), 5)
        XCTAssertEqual(ds.doubleValue(5.5), 5.5)
        XCTAssertEqual(ds.doubleValue("5.5"), 5.5)
        XCTAssertNil(ds.doubleValue("not a number"))
        XCTAssertNil(ds.doubleValue(nil))
    }

    func testEpochMillisToDate() {
        XCTAssertEqual(ds.epochMillisToDate(1_700_000_000_000),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ds.epochMillisToDate("1700000000000"),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(ds.epochMillisToDate(0))
        XCTAssertNil(ds.epochMillisToDate(nil))
    }

    func testCodexAPIWindow() {
        let (used, reset) = ds.codexAPIWindow(["used_percent": 42.0, "reset_at": 1_700_000_000.0])
        XCTAssertEqual(used, 42.0)
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_700_000_000))

        let (usedInt, _) = ds.codexAPIWindow(["used_percent": 30])   // Int coerced
        XCTAssertEqual(usedInt, 30)

        let (none, noReset) = ds.codexAPIWindow(nil)
        XCTAssertNil(none)
        XCTAssertNil(noReset)

        // The session files spell it `resets_at`; accept either so a shape change can't silently
        // drop the countdown.
        let (_, plural) = ds.codexAPIWindow(["used_percent": 5.0, "resets_at": 1_700_000_000.0])
        XCTAssertEqual(plural, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The real Plus case since OpenAI's July 2026 5-hour removal: the sole window sits in the
    /// `primary_window` slot but is the WEEKLY one (limit_window_seconds 604800). It must be classified
    /// as weekly — not mislabeled as the 5-hour session (which showed a bogus "5s, resets in 6d").
    func testCodexStatusWeeklyWindowInPrimarySlot() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 1.0, "limit_window_seconds": 604800, "reset_at": 1_785_822_607.0],
            ],
            "credits": ["has_credits": false, "balance": "0"],
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertEqual(status.name, "Codex")
        XCTAssertNil(status.sessionRemainingPercent)                       // NOT a 5h window
        XCTAssertEqual(status.weeklyRemainingPercent, 99)                  // classified as weekly
        XCTAssertEqual(status.weeklyResetAt, Date(timeIntervalSince1970: 1_785_822_607))
        XCTAssertTrue(status.models.isEmpty)                              // no credits row
    }

    /// ChatGPT Go moved its quota to a ~30-day window in mid-2026. It must be kept as the window's
    /// REAL length so the UI can label it "30d" — the old code bucketed anything over 6h as "7d".
    func testCodexStatusKeepsMonthlyWindowLength() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 10.0, "limit_window_seconds": 2_592_000, "reset_at": 1_785_822_607.0],
            ],
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertNil(status.sessionRemainingPercent)
        XCTAssertEqual(status.weeklyRemainingPercent, 90)
        XCTAssertEqual(status.weeklyWindowSeconds, 2_592_000)
        XCTAssertEqual(quotaWindowDays(status.weeklyWindowSeconds), 30)
    }

    /// The weekly window's length reaches the UI for the ordinary 7-day case too.
    func testCodexStatusKeepsWeeklyWindowLength() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 1.0, "limit_window_seconds": 604800, "reset_at": 1_785_822_607.0],
            ],
        ]
        XCTAssertEqual(quotaWindowDays(ds.codexStatus(fromUsageRoot: root).weeklyWindowSeconds), 7)
    }

    /// No length reported → nil, so the UI keeps its plain weekly badge instead of printing a guess.
    func testCodexStatusWithoutWindowLengthLeavesItNil() {
        let root: [String: Any] = [
            "rate_limit": ["secondary_window": ["used_percent": 5.0, "reset_at": 1_785_822_607.0]],
        ]
        XCTAssertNil(ds.codexStatus(fromUsageRoot: root).weeklyWindowSeconds)
    }

    /// The badge must come from the window's total length, never from the countdown — on day 27 of a
    /// 30-day window it still reads "30d". Session-length and unknown windows get no day badge.
    func testQuotaWindowDaysUsesWindowLengthNotRemainingTime() {
        XCTAssertEqual(quotaWindowDays(2_592_000), 30)      // 30d
        XCTAssertEqual(quotaWindowDays(604800), 7)          // 7d
        XCTAssertEqual(quotaWindowDays(3 * 86_400), 3)      // a 3-day window is "3d", not "7d"
        XCTAssertNil(quotaWindowDays(18000))                // 5h session → no day badge
        XCTAssertNil(quotaWindowDays(TimeInterval?.none))   // unknown → no badge
    }

    /// The live `wham/usage` response observed 2026-08-04 on a Plus account (identifiers redacted),
    /// parsed through JSONSerialization so the numbers arrive as NSNumber exactly as in production.
    func testCodexStatusFromLiveWeeklyOnlyResponse() {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 40,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 332661,
              "reset_at": 1786161248
            },
            "secondary_window": null
          },
          "credits": { "has_credits": false, "unlimited": false }
        }
        """
        let root = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertNil(status.sessionRemainingPercent)
        XCTAssertEqual(status.weeklyRemainingPercent, 60)
        XCTAssertEqual(status.weeklyResetAt, Date(timeIntervalSince1970: 1_786_161_248))
        XCTAssertEqual(status.weeklyWindowSeconds, 604_800)
        XCTAssertTrue(status.models.isEmpty)
    }

    // MARK: Codex reset credits

    private func resetCreditsRoot(_ credits: String) -> [String: Any] {
        let json = "{\"available_count\": 2, \"credits\": [\(credits)]}"
        return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private let credalNow = Date(timeIntervalSince1970: 1_786_000_000)
    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_786_000_000 + offset))
    }

    /// One row per available credit, soonest expiry first, each carrying its own expiry so the popover
    /// can draw a live countdown and the warning can pick the nearest one.
    func testCodexResetCreditsRowPerCredit() {
        let root = resetCreditsRoot("""
        {"id": "a", "status": "available", "expires_at": "\(iso(6 * 86_400))", "title": "Reset", "description": ""},
        {"id": "b", "status": "available", "expires_at": "\(iso(3 * 86_400))", "title": "Reset", "description": ""}
        """)
        let rows = ds.codexResetCreditRows(fromRoot: root, now: credalNow)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.resetAt), [credalNow.addingTimeInterval(3 * 86_400),
                                             credalNow.addingTimeInterval(6 * 86_400)])
        // Each line is labelled by the date it lapses, in the locale's own short format.
        XCTAssertEqual(rows[0].name, LiveUsageDataSource.creditDateFormatter
            .string(from: credalNow.addingTimeInterval(3 * 86_400)))
        XCTAssertEqual(rows[1].name, LiveUsageDataSource.creditDateFormatter
            .string(from: credalNow.addingTimeInterval(6 * 86_400)))
        XCTAssertEqual(rows[0].valueText, TimeFormatter.duration(from: 3 * 86_400))
    }

    /// A credit that lapsed between polls, and one that was already spent, are both dropped —
    /// `available_count` alone would have over-reported here.
    func testCodexResetCreditsDropsExpiredAndUsed() {
        let root = resetCreditsRoot("""
        {"id": "a", "status": "available", "expires_at": "\(iso(-3_600))", "title": "", "description": ""},
        {"id": "b", "status": "used", "expires_at": "\(iso(30 * 86_400))", "title": "", "description": ""}
        """)
        XCTAssertTrue(ds.codexResetCreditRows(fromRoot: root, now: credalNow).isEmpty)
    }

    /// Empty / missing payload → no rows at all, so the card simply doesn't draw the section.
    func testCodexResetCreditsEmptyPayload() {
        XCTAssertTrue(ds.codexResetCreditRows(fromRoot: ["available_count": 0, "credits": []]).isEmpty)
        XCTAssertTrue(ds.codexResetCreditRows(fromRoot: [:]).isEmpty)
    }

    /// Both windows present with real durations: the 5-hour one (limit_window_seconds 18000) is the
    /// session, the 7-day one (604800) is weekly — classified by duration regardless of slot.
    func testCodexStatusClassifiesBothWindowsByDuration() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 20.0, "limit_window_seconds": 18000, "reset_at": 1_700_000_000.0],
                "secondary_window": ["used_percent": 60.0, "limit_window_seconds": 604800, "reset_at": 1_700_500_000.0],
            ]
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertEqual(status.sessionRemainingPercent, 80)
        XCTAssertEqual(status.weeklyRemainingPercent, 40)
        XCTAssertEqual(status.sessionResetAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// No duration field and the resets already lapsed → nothing better to go on, so fall back to the
    /// slot: primary is the session, secondary the weekly. Keeps older payloads working unchanged.
    func testCodexStatusFallsBackToSlotWhenNoDuration() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 20.0, "reset_at": 1_700_000_000.0],
                "secondary_window": ["used_percent": 60.0, "reset_at": 1_700_500_000.0],
            ]
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertEqual(status.sessionRemainingPercent, 80)
        XCTAssertEqual(status.weeklyRemainingPercent, 40)
    }

    /// The period field is the only reliable signal; when it goes missing, how far the reset is beats
    /// the slot. Here the sole window resets 6 DAYS out while sitting in `primary_window` — the shape
    /// that made Mimir print "5s, resets in 6d". Without a duration it must still read as weekly.
    func testCodexStatusUsesResetDistanceWhenDurationMissing() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 1.0, "reset_at": now.addingTimeInterval(6 * 86400).timeIntervalSince1970],
            ]
        ]
        let status = ds.codexStatus(fromUsageRoot: root, now: now)
        XCTAssertNil(status.sessionRemainingPercent)          // not a 5h window
        XCTAssertEqual(status.weeklyRemainingPercent, 99)

        // A reset within 5h can only be the session window.
        let soon: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 10.0, "reset_at": now.addingTimeInterval(2 * 3600).timeIntervalSince1970]]
        ]
        XCTAssertEqual(ds.codexStatus(fromUsageRoot: soon, now: now).sessionRemainingPercent, 90)
    }

    /// Both windows read as the session (no duration, both resetting soon): the second must land in
    /// the weekly slot instead of being dropped — a slightly mislabelled reading beats a missing one.
    func testCodexStatusKeepsSecondWindowWhenBothLookLikeSession() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 20.0, "reset_at": now.addingTimeInterval(3600).timeIntervalSince1970],
                "secondary_window": ["used_percent": 60.0, "reset_at": now.addingTimeInterval(2 * 3600).timeIntervalSince1970],
            ]
        ]
        let status = ds.codexStatus(fromUsageRoot: root, now: now)
        XCTAssertEqual(status.sessionRemainingPercent, 80)
        XCTAssertEqual(status.weeklyRemainingPercent, 40)     // kept, not dropped
    }

    /// No `primary_window` — the common case since OpenAI temporarily removed Codex's 5-hour limit in
    /// July 2026 (all plans, not just business). The card stays "Codex" but drops the 5h reading
    /// (`sessionRemainingPercent == nil` → popover hides the 5s block); weekly + credit still show.
    func testCodexStatusDropsFiveHourWindowWhenAbsent() {
        let root: [String: Any] = [
            "rate_limit": [
                "secondary_window": ["used_percent": 10.0, "reset_at": 1_700_500_000.0],
            ],
            "credits": ["has_credits": true, "balance": "42"],
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertEqual(status.name, "Codex")
        XCTAssertNil(status.sessionRemainingPercent)          // 5h block is dropped, not pinned to 100
        XCTAssertNil(status.sessionResetAt)
        XCTAssertEqual(status.weeklyRemainingPercent, 90)     // weekly still shown
        XCTAssertEqual(status.models.first?.valueText?.contains("42"), true)
        XCTAssertTrue(status.isAvailable)
    }

    /// A window present but WITHOUT `used_percent` reads as unknown, not full. Pinning it to 100 made a
    /// partial response look like a fresh reset, which fired "quota refilled" mid-month on the 30-day
    /// (ChatGPT Go) window. The reset time is still kept, so the countdown survives.
    func testCodexStatusLeavesPercentNilWhenUsedPercentMissing() {
        let root: [String: Any] = [
            "rate_limit": [
                "primary_window": ["limit_window_seconds": 2_592_000, "reset_at": 1_785_822_607.0],
            ],
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertNil(status.weeklyRemainingPercent)                        // unknown, not 100
        XCTAssertEqual(status.weeklyResetAt, Date(timeIntervalSince1970: 1_785_822_607))
        XCTAssertEqual(status.weeklyWindowSeconds, 2_592_000)
    }

    /// The refill alert runs off the window's reset clock, not off the percent: fire once the armed
    /// reset has passed, and never twice for the same one (the stamp survives a relaunch).
    func testRefillFiresOncePerArmedReset() {
        let t: Double = 1_785_000_000
        XCTAssertTrue(refillIsDue(armed: t, announced: 0, now: t))              // reset came round
        XCTAssertTrue(refillIsDue(armed: t, announced: t - 1, now: t + 60))     // a later reset
        XCTAssertFalse(refillIsDue(armed: t, announced: 0, now: t - 1))         // not yet
        XCTAssertFalse(refillIsDue(armed: t, announced: t, now: t + 60))        // already announced
        XCTAssertFalse(refillIsDue(armed: 0, announced: 0, now: t))             // nothing armed
    }

    /// Arming takes the next future reset, once, and refuses the one we already announced — otherwise
    /// the data rolling forward at reset time would clobber a refill still owed.
    func testNextArmedResetTakesTheNextFutureResetOnly() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let next = now.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(nextArmedReset(armed: 0, announced: 0, resetAt: next, now: now),
                       next.timeIntervalSince1970)
        XCTAssertNil(nextArmedReset(armed: 123, announced: 0, resetAt: next, now: now))   // already armed
        XCTAssertNil(nextArmedReset(armed: 0, announced: 0, resetAt: nil, now: now))      // no reset reported
        XCTAssertNil(nextArmedReset(armed: 0, announced: 0,
                                    resetAt: now.addingTimeInterval(-60), now: now))      // already past
        XCTAssertNil(nextArmedReset(armed: 0, announced: next.timeIntervalSince1970,
                                    resetAt: next, now: now))                             // already announced
    }

    /// Codex's 5-hour `reset_at` drifts forward inside one window, so the low warning must key on
    /// "has that reset actually come round" rather than on the stamp changing — otherwise the same
    /// spent window warned again on every poll.
    func testLowAlertFiresOncePerWindowDespiteDriftingReset() {
        let now: Double = 1_788_650_000
        let reset = now + 3_600
        XCTAssertTrue(lowAlertIsDue(lastWarnedReset: nil, resetStamp: reset, now: now))        // never warned
        XCTAssertFalse(lowAlertIsDue(lastWarnedReset: reset, resetStamp: reset, now: now))     // same reset
        XCTAssertFalse(lowAlertIsDue(lastWarnedReset: reset, resetStamp: reset + 12, now: now)) // drifted, same window
        XCTAssertTrue(lowAlertIsDue(lastWarnedReset: reset, resetStamp: reset + 18_000,
                                    now: reset + 60))                                          // window rolled over
        XCTAssertFalse(lowAlertIsDue(lastWarnedReset: 0, resetStamp: 0, now: now))             // no reset reported
    }

    /// The low-quota threshold scales with the window: a flat 10% warns on day three of a 30-day
    /// ChatGPT Go quota. Anything at or under a week keeps the base, and the floor stops the scaling
    /// from tightening past a usable warning.
    func testLowQuotaThresholdScalesWithWindowLength() {
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: nil), 10)             // unknown → base
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: 7 * 86_400), 10)      // the week itself
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: 5 * 86_400), 10)      // shorter → still base
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: 14 * 86_400), 5)      // scaled to the floor
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: 2_592_000), 5)        // 30d Go window
        // Without the floor a 30-day window would warn at 2% — too late to spend the remainder.
        XCTAssertEqual(lowQuotaThreshold(windowSeconds: 2_592_000, floor: 0), 2)
    }

    /// Credit-only account with neither window → "Codex" shows just the credit balance; both window
    /// readings stay nil (no misleading 100%).
    func testCodexStatusCreditOnly() {
        let root: [String: Any] = [
            "rate_limit": [:],
            "credits": ["has_credits": true, "balance": "5"],
        ]
        let status = ds.codexStatus(fromUsageRoot: root)
        XCTAssertEqual(status.name, "Codex")
        XCTAssertNil(status.sessionRemainingPercent)
        XCTAssertNil(status.weeklyRemainingPercent)
        XCTAssertEqual(status.models.first?.valueText?.contains("5"), true)
    }

    func testJWTExpiry() {
        let token = Self.makeJWT(payload: ["exp": 2_000_000_000])
        XCTAssertEqual(ds.jwtExpiry(token), Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(ds.jwtExpiry("garbage"))
        XCTAssertNil(ds.jwtExpiry("only.two"))   // invalid base64 payload
    }

    func testDecodeJWTPayload() {
        let token = Self.makeJWT(payload: ["sub": "abc", "n": 7])
        let payload = ds.decodeJWTPayload(token)
        XCTAssertEqual(payload?["sub"] as? String, "abc")
        XCTAssertNil(ds.decodeJWTPayload("x"))
    }

    /// Right after a 5-hour boundary the API briefly returns a `five_hour` reset that has already
    /// passed (the old window's). Live data must keep the session — it's authoritative — otherwise
    /// Claude's card and widget vanish for a few minutes. Stale fallbacks still blank a lapsed window.
    func testLiveClaudeKeepsSessionWhenResetJustLapsed() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 7.0, "resets_at": "2020-01-01T00:00:00Z"],   // long past
            "seven_day": ["utilization": 1.0, "resets_at": "2030-01-01T00:00:00Z"],   // future
        ]
        // Live: session percent survives the lapsed reset.
        let live = ds.buildClaudeStatus(from: root, note: "oauth usage api", live: true)
        XCTAssertEqual(live.sessionRemainingPercent, 93)
        XCTAssertEqual(live.weeklyRemainingPercent, 99)
        XCTAssertTrue(live.isAvailable)

        // Stale fallback: a window whose reset has passed has refilled to full, so it shows 100% (not
        // a blank that would make the session vanish from the card and drop it from the widget); the
        // weekly (future reset) keeps its real number. The card stays present and available.
        let stale = ds.buildClaudeStatus(from: root, note: "snapshot", live: false)
        XCTAssertEqual(stale.sessionRemainingPercent, 100)
        XCTAssertEqual(stale.weeklyRemainingPercent, 99)
        XCTAssertTrue(stale.isAvailable)
    }

    /// When EVERY window and per-model row has lapsed (idle for hours — no fresh hook or OAuth fetch),
    /// the card must not blank the session (Claude vanishes) or drop the model rows (Fable disappears).
    /// Each lapsed row refills to 100% with its reset rolled forward to the next boundary, and the card
    /// dims (`isStale`) so it reads as last-known rather than live.
    func testStaleCardRefillsAndKeepsModelsWhenAllLapsed() {
        let past = Date(timeIntervalSinceNow: -3600)   // 1h ago → lapsed
        let card = ds.staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: 93, sessionReset: past,
            weeklyPct: 16, weeklyReset: past,
            models: [ModelStatus(name: "Fable", remainingPercent: 6, resetAt: past)],
            freshNote: "fresh", staleNote: "stale")
        XCTAssertEqual(card?.sessionRemainingPercent, 100)          // refilled, not blanked
        XCTAssertEqual(card?.weeklyRemainingPercent, 100)
        XCTAssertEqual(card?.models.first?.name, "Fable")          // kept, not dropped
        XCTAssertEqual(card?.models.first?.remainingPercent, 100)
        XCTAssertTrue(card?.isStale ?? false)                      // dimmed = last-known
        XCTAssertNotNil(card?.sessionResetAt)
        XCTAssertGreaterThan(card!.sessionResetAt!, Date())        // reset rolled into the future
        XCTAssertGreaterThan(card!.weeklyResetAt!, Date())
        XCTAssertGreaterThan(card!.models.first!.resetAt!, Date())
    }

    /// A lapsed reset is rolled forward by the window's REAL length. With a ~30-day window (ChatGPT Go)
    /// and a reset 40 days old, stepping by 30 days lands 20 days out; the old hardcoded 7-day step
    /// would have landed within a week — a boundary that window never has.
    func testStaleCardRollsResetForwardByRealWindowLength() {
        let month: TimeInterval = 30 * 86_400
        let past = Date(timeIntervalSinceNow: -40 * 86_400)
        let card = ds.staleClassifiedCard(
            name: "Codex", iconName: "codex",
            sessionPct: nil, sessionReset: nil,
            weeklyPct: 12, weeklyReset: past,
            weeklyWindowSeconds: month,
            models: [], freshNote: "fresh", staleNote: "stale")
        let rolled = try! XCTUnwrap(card?.weeklyResetAt)
        XCTAssertGreaterThan(rolled, Date())
        // 40 days past + two 30-day steps = 20 days out, not the ~2 days a 7-day step would give.
        XCTAssertEqual(rolled.timeIntervalSince(past), 60 * 86_400, accuracy: 60)
        XCTAssertEqual(card?.weeklyWindowSeconds, month)            // survives into the restored card
    }

    /// No reported length → the 7-day default, exactly as before this field existed.
    func testStaleCardFallsBackToSevenDaysWithoutWindowLength() {
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        let card = ds.staleClassifiedCard(
            name: "Claude", iconName: "claude",
            sessionPct: nil, sessionReset: nil,
            weeklyPct: 30, weeklyReset: past,
            models: [], freshNote: "fresh", staleNote: "stale")
        let rolled = try! XCTUnwrap(card?.weeklyResetAt)
        XCTAssertEqual(rolled.timeIntervalSince(past), 14 * 86_400, accuracy: 60)
        XCTAssertNil(card?.weeklyWindowSeconds)
    }

    /// The window length survives the real save→load JSON round trip (not just the in-memory path)
    /// and drives the reset rollover on restore. A save/load key mismatch would fail here where the
    /// direct staleClassifiedCard tests above would still pass. Uses a made-up service name so the
    /// file never collides with a real provider's snapshot.
    func testSnapshotRoundTripPreservesWindowLengthAndRollsReset() throws {
        let month: TimeInterval = 30 * 86_400
        let past = Date(timeIntervalSinceNow: -40 * 86_400)
        let status = ServiceStatus(
            name: "RoundTrip", iconName: "codex",
            sessionResetAt: nil, weeklyResetAt: past,
            weeklyRemainingPercent: 12, weeklyWindowSeconds: month,
            models: [], isAvailable: true, statusNote: nil)
        ds.saveSnapshot(status)
        defer { try? FileManager.default.removeItem(at: ds.snapshotURL(for: "RoundTrip")) }

        let card = try XCTUnwrap(ds.loadSnapshot(for: "RoundTrip", iconName: "codex"))
        XCTAssertEqual(card.weeklyWindowSeconds, month)
        // 40 days past + two 30-day steps = 20 days out — proof the persisted length, not the
        // 7-day default, stepped the lapsed reset.
        let rolled = try XCTUnwrap(card.weeklyResetAt)
        XCTAssertEqual(rolled.timeIntervalSince(past), 60 * 86_400, accuracy: 60)
    }

    /// An absurd on-disk window length (corrupt or hand-edited snapshot) is dropped at load instead
    /// of reaching quotaWindowDays' Double→Int conversion, where 1e300 would trap and crash the app
    /// on every launch until the file is deleted.
    func testSnapshotLoadDropsOutOfRangeWindowLength() throws {
        let iso = ISO8601DateFormatter()
        let past = iso.string(from: Date(timeIntervalSinceNow: -10 * 86_400))
        let json = """
        {"version":1,"savedAt":"\(iso.string(from: Date()))","weeklyRemainingPercent":30,\
        "weeklyResetAt":"\(past)","weeklyWindowSeconds":1e300}
        """
        let url = ds.snapshotURL(for: "RoundTrip")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let card = try XCTUnwrap(ds.loadSnapshot(for: "RoundTrip", iconName: "codex"))
        XCTAssertNil(card.weeklyWindowSeconds)          // out-of-range → dropped
        XCTAssertNil(quotaWindowDays(card.weeklyWindowSeconds))   // and the badge stays off
    }

    /// A card with even ONE refilled window is an estimate → `isStale`, so it's excluded from the reset
    /// notification path (which fires on `!isStale`). This stops the false "weekly quota refilled" spam
    /// when a stale card bounces its weekly to a refilled 100 while the session is still live.
    func testMixedRefilledWindowMarksCardStale() {
        let future = Date(timeIntervalSinceNow: 3600)
        let past = Date(timeIntervalSinceNow: -3600)
        let card = ds.staleClassifiedCard(
            name: "Codex", iconName: "codex",
            sessionPct: 90, sessionReset: future,   // live
            weeklyPct: 40, weeklyReset: past,        // lapsed → refilled to 100
            models: [], freshNote: "fresh", staleNote: "stale")
        XCTAssertEqual(card?.sessionRemainingPercent, 90)   // live window kept
        XCTAssertEqual(card?.weeklyRemainingPercent, 100)   // refilled estimate
        XCTAssertTrue(card?.isStale ?? false)               // → not eligible to notify
    }

    /// `secureAtomicWrite` must land the file at 0o600 (never the umask default), on both a fresh
    /// write and an overwrite — that's the whole point of the TOCTOU fix for token files.
    func testSecureAtomicWriteIsAlways0600() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mimir-secwrite-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        func perms() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int
        }

        // Fresh write (target absent → moveItem path).
        let first = Data("{\"token\":\"a\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: first, to: tmp)
        XCTAssertEqual(try Data(contentsOf: tmp), first)
        XCTAssertEqual(try perms(), 0o600)

        // Overwrite (target exists → replaceItemAt path) still 0o600, new content.
        let second = Data("{\"token\":\"b\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: second, to: tmp)
        XCTAssertEqual(try Data(contentsOf: tmp), second)
        XCTAssertEqual(try perms(), 0o600)
    }

    /// A symlinked credential file (dotfile-manager pattern) must be written *through*: the link is
    /// preserved and the real file behind it gets the new 0o600 content, not clobbered into a file.
    func testSecureAtomicWriteFollowsSymlink() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let real = dir.appendingPathComponent("mimir-real-\(UUID()).json")
        let link = dir.appendingPathComponent("mimir-link-\(UUID()).json")
        defer { try? fm.removeItem(at: real); try? fm.removeItem(at: link) }

        try Data("{\"t\":\"old\"}".utf8).write(to: real)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let new = Data("{\"t\":\"new\"}".utf8)
        try LiveUsageDataSource.secureAtomicWrite(data: new, to: link)

        // Link still a symlink pointing at `real` (not replaced by a regular file)…
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path)
        // …and the real file behind it got the new content at 0o600.
        XCTAssertEqual(try Data(contentsOf: real), new)
        XCTAssertEqual(try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
    }

    /// Per-model weekly rows come from the `limits` array (`scope.model.display_name`), not the
    /// legacy flat `seven_day_<model>` keys — the API now returns those as null. This mirrors a real
    /// captured response: session 93%, all-models 34%, and a scoped "Fable" row at 66% used.
    func testClaudeScopedModelRowFromLimitsArray() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 93.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 34.0, "resets_at": "2030-01-08T00:00:00Z"],
            "seven_day_sonnet": NSNull(),   // legacy key: now dead, must be ignored
            "limits": [
                ["kind": "session", "group": "session", "percent": 93, "resets_at": "2030-01-01T00:00:00Z", "scope": NSNull()],
                ["kind": "weekly_all", "group": "weekly", "percent": 34, "resets_at": "2030-01-08T00:00:00Z", "scope": NSNull()],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 66, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        XCTAssertEqual(status.models.map(\.name), ["Fable"])
        XCTAssertEqual(status.models.first?.remainingPercent, 34)   // 100 - 66
    }

    /// Multiple scoped models appear as separate rows, in the order the API returns them — no
    /// hardcoded model list needed for a new tier to show up.
    func testClaudeMultipleScopedModelRows() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 10.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 10.0, "resets_at": "2030-01-08T00:00:00Z"],
            "limits": [
                ["kind": "weekly_scoped", "group": "weekly", "percent": 20, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["display_name": "Fable"], "surface": NSNull()]],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 50, "resets_at": "2030-01-08T00:00:00Z",
                 "scope": ["model": ["display_name": "Opus"], "surface": NSNull()]],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        XCTAssertEqual(status.models.map(\.name), ["Fable", "Opus"])
        XCTAssertEqual(status.models.map(\.remainingPercent), [80, 50])
    }

    /// The new `spend` object is preferred over the legacy `extra_usage` shape when both are present
    /// and `spend` is enabled.
    func testClaudeBillingPrefersSpendOverLegacyExtraUsage() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 0.0, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 0.0, "resets_at": "2030-01-08T00:00:00Z"],
            "extra_usage": ["is_enabled": true, "used_credits": 999.0, "monthly_limit": 999.0, "currency": "USD"],
            "spend": [
                "enabled": true,
                "percent": 50.0,
                "used": ["amount_minor": 500, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 1000, "currency": "USD", "exponent": 2],
            ],
        ]
        let status = ds.buildClaudeStatus(from: root, note: "oauth usage api")
        let billing = status.models.first { $0.valueText != nil }
        XCTAssertEqual(billing?.valueText, "$5 / $10")
    }

    /// Claude Code now writes per-config keychain items ("Claude Code-credentials-<hash>") and can
    /// leave the legacy exact-name item behind with a dead token. Candidate ordering must be
    /// newest-modified first, include both name shapes, and exclude unrelated services.
    func testClaudeKeychainServicesOrdered() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let ordered = LiveUsageDataSource.claudeKeychainServicesOrdered([
            ("Claude Code-credentials", old),
            ("Claude Safe Storage", new),                       // unrelated → excluded
            ("Claude Code-credentials-b47470ab", new),
            ("Claude Code-credentials-a7f272c1", nil),          // no mdat → sorts last
        ])
        XCTAssertEqual(ordered, [
            "Claude Code-credentials-b47470ab",
            "Claude Code-credentials",
            "Claude Code-credentials-a7f272c1",
        ])
    }

    /// Build a base64url JWT (header.payload.sig) from a payload dict — only the payload is read.
    private static func makeJWT(payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64url = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(b64url).signature"
    }
}

/// The cache-freshness rule: age decides on its own for the deep fallbacks, but a caller choosing
/// whether to fetch also demands the entry was written by the running process — otherwise a freshly
/// updated app would show the previous version's numbers until the interval lapsed.
final class ClaudeCacheFreshnessTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    func testEntryFromThisSessionIsFresh() {
        let written = launch.addingTimeInterval(30)
        XCTAssertTrue(LiveUsageDataSource.claudeCacheCountsAsFresh(
            modifiedAt: written, now: written.addingTimeInterval(60), maxAge: 300,
            launchedAt: launch, writtenThisSession: true))
    }

    func testEntryFromAnEarlierSessionNeverSkipsTheFetch() {
        // Young enough by age, but written before launch — the just-updated-app case.
        let written = launch.addingTimeInterval(-60)
        XCTAssertFalse(LiveUsageDataSource.claudeCacheCountsAsFresh(
            modifiedAt: written, now: launch.addingTimeInterval(10), maxAge: 300,
            launchedAt: launch, writtenThisSession: true))
        // The deep fallbacks still accept it: they are judged by age alone.
        XCTAssertTrue(LiveUsageDataSource.claudeCacheCountsAsFresh(
            modifiedAt: written, now: launch.addingTimeInterval(10), maxAge: 300,
            launchedAt: launch, writtenThisSession: false))
    }

    func testAgeStillWins() {
        let written = launch.addingTimeInterval(30)
        XCTAssertFalse(LiveUsageDataSource.claudeCacheCountsAsFresh(
            modifiedAt: written, now: written.addingTimeInterval(301), maxAge: 300,
            launchedAt: launch, writtenThisSession: true))
    }
}
