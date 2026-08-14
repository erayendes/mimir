import XCTest
@testable import Mimir

/// The sleep/wake poll guard: a fire minutes late is the run loop's catch-up after sleep (skip it),
/// a fire seconds late is jitter (poll normally); and a short nap doesn't earn an extra refresh.
final class WakeSchedulingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOverdueFireBoundary() {
        XCTAssertFalse(WakeScheduling.isOverdueFire(now: now, expected: nil))            // first fire
        XCTAssertFalse(WakeScheduling.isOverdueFire(now: now, expected: now))            // on time
        XCTAssertFalse(WakeScheduling.isOverdueFire(now: now, expected: now - 5))        // jitter
        XCTAssertFalse(WakeScheduling.isOverdueFire(now: now, expected: now - 120))      // exactly slack
        XCTAssertTrue(WakeScheduling.isOverdueFire(now: now, expected: now - 121))       // just past it
        XCTAssertTrue(WakeScheduling.isOverdueFire(now: now, expected: now - 3600))      // slept an hour
    }

    func testRefreshAfterWakeOnlyWhenDataIsStale() {
        XCTAssertTrue(WakeScheduling.shouldRefreshAfterWake(lastPoll: nil, now: now, pollInterval: 60))
        XCTAssertFalse(WakeScheduling.shouldRefreshAfterWake(lastPoll: now - 59, now: now, pollInterval: 60))
        XCTAssertTrue(WakeScheduling.shouldRefreshAfterWake(lastPoll: now - 60, now: now, pollInterval: 60))
        XCTAssertTrue(WakeScheduling.shouldRefreshAfterWake(lastPoll: now - 7200, now: now, pollInterval: 60))
    }
}
