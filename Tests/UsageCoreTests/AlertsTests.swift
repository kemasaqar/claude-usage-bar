import XCTest
@testable import UsageCore

final class AlertsTests: TempTestCase {
    /// What was sent so far, as the app keeps it between refreshes.
    var sent: [String] = []

    /// The alerts due for these windows at `time` (default: now).
    func due(_ windows: [WindowName: Window], every step: Int, at time: Double? = nil) -> [Alert] {
        let at = time ?? now!
        let cache = UsageCache(windows: windows, updatedAt: at, checkedAt: at)
        let model = MenuModel.build(cache: cache, probeState: [:], paused: false, now: at, staleAfter: 3600)
        return Alerts.due(model.rows, every: step, sent: &sent)
    }

    /// A 5-hour window that is `hours` in at `now` (default 2: heading over
    /// above 40%).
    func fiveHour(_ pct: Double, hoursIn hours: Double = 2) -> Window {
        Window(usedPercentage: pct, resetsAt: now + (5 - hours) * 3600)
    }

    // MARK: Every step

    func testBelowTheFirstStepAndOnTrackSendsNothing() {
        XCTAssertEqual(due([.fiveHour: fiveHour(22)], every: 50), [])  // ends near 55%
        XCTAssertEqual(sent, [])
    }

    func testEachStepIsSentOnce() {
        // Three hours in, anything below 60% is on track: no pace alert here.
        func window(_ pct: Double) -> Window { fiveHour(pct, hoursIn: 3) }
        let first = due([.fiveHour: window(22)], every: 20)
        XCTAssertEqual(first, [Alert(title: "5-hour limit at 22%",
                                     body: "Resets in 2h 00m (\(Format.clock(now + 2 * 3600, now: now)))")])
        XCTAssertEqual(due([.fiveHour: window(39)], every: 20), [])
        // 39.6% shows as 40% in the menu bar, so that's when 40% is announced.
        XCTAssertEqual(due([.fiveHour: window(39.6)], every: 20).map(\.title), ["5-hour limit at 40%"])
        XCTAssertEqual(due([.fiveHour: window(40.2)], every: 20), [])
    }

    func testSeveralStepsPassedAtOnceAreOneNotification() {
        XCTAssertEqual(due([.fiveHour: fiveHour(15)], every: 10).map(\.title), ["5-hour limit at 15%"])
        XCTAssertEqual(due([.fiveHour: fiveHour(37)], every: 10).map(\.title), ["5-hour limit at 37%"])
        XCTAssertEqual(due([.fiveHour: fiveHour(38)], every: 10), [])
    }

    func testChoosingAnotherStepDoesNotAnnounceALevelAgain() {
        XCTAssertEqual(due([.fiveHour: fiveHour(38)], every: 10).count, 1)   // told at 30
        XCTAssertEqual(due([.fiveHour: fiveHour(38)], every: 25), [])        // 25 is below that
        XCTAssertEqual(due([.fiveHour: fiveHour(51)], every: 25).map(\.title), ["5-hour limit at 51%"])
    }

    func testOffOrABadStepSendsNoLevels() {
        for step in [0, -10] {
            sent = []
            XCTAssertEqual(due([.fiveHour: fiveHour(22)], every: step), [])
        }
    }

    // MARK: Pace

    func testHeadingOverIsSentOncePerWindow() {
        // 48% after 2h: 100% at 4h10m, 50 minutes before the reset.
        let alerts = due([.fiveHour: fiveHour(48)], every: 50)
        XCTAssertEqual(alerts.map(\.title),
                       ["5-hour limit runs out ~" + Format.clock(now + 2 * 3600 + 600, now: now)])
        XCTAssertTrue(alerts[0].body.hasPrefix("48% used · Resets in 3h 00m ("), alerts[0].body)
        XCTAssertEqual(due([.fiveHour: fiveHour(49)], every: 50), [])
    }

    func testHeadingOverAgainInTheSameWindowIsNotRepeated() {
        // An hour in, anything above 20% is heading over.
        XCTAssertEqual(due([.fiveHour: fiveHour(25, hoursIn: 1)], every: 50).count, 1)
        // Half an hour without use: 25% after 1h30m lasts until the reset.
        XCTAssertEqual(due([.fiveHour: fiveHour(25, hoursIn: 1)], every: 50, at: now + 1800), [])
        XCTAssertEqual(sent.count, 1)
        // Then 35%: heading over again, but you've been told.
        XCTAssertEqual(due([.fiveHour: fiveHour(35, hoursIn: 1)], every: 50, at: now + 1800), [])
    }

    func testAStepThatIsAlsoHeadingOverIsOneNotificationNotTwo() {
        let alerts = due([.fiveHour: fiveHour(41)], every: 20)
        XCTAssertEqual(alerts.map(\.title), ["5-hour limit at 41%"])
        XCTAssertTrue(alerts[0].body.contains(" · runs out ~"), alerts[0].body)
        XCTAssertEqual(due([.fiveHour: fiveHour(45)], every: 20), [])  // no pace alert after it
    }

    // MARK: Reset

    func testResetIsSentOnceAfterNinetyPercent() {
        let window = fiveHour(92)
        XCTAssertEqual(due([.fiveHour: window], every: 10).map(\.title), ["5-hour limit at 92%"])
        let after = window.resetsAt + 1
        XCTAssertEqual(due([.fiveHour: window], every: 10, at: after),
                       [Alert(title: "5-hour limit has reset", body: "")])
        XCTAssertEqual(due([.fiveHour: window], every: 10, at: after + 15), [])
    }

    func testResetFollowsNinetyPercentEvenWithoutAStepThere() {
        XCTAssertEqual(due([.fiveHour: fiveHour(60)], every: 50).count, 1)  // 50%, heading over
        let window = fiveHour(92)
        XCTAssertEqual(due([.fiveHour: window], every: 50), [])             // no step at 90
        XCTAssertEqual(due([.fiveHour: window], every: 50, at: window.resetsAt + 1).map(\.title),
                       ["5-hour limit has reset"])
    }

    func testResetBelowNinetyPercentSendsNothing() {
        let window = fiveHour(48)
        XCTAssertEqual(due([.fiveHour: window], every: 10).count, 1)
        XCTAssertEqual(due([.fiveHour: window], every: 10, at: window.resetsAt + 1), [])
    }

    // MARK: Windows

    func testNextWindowStartsOver() {
        XCTAssertEqual(due([.fiveHour: fiveHour(92)], every: 10).count, 1)
        // An hour into the window after it: old entries go, and it alerts again.
        let next = Window(usedPercentage: 95, resetsAt: now + 8 * 3600)
        XCTAssertEqual(due([.fiveHour: next], every: 10, at: now + 4 * 3600).map(\.title), ["5-hour limit at 95%"])
        XCTAssertEqual(sent, ["at-90", "pace", "90"].map { "five_hour-\(Int(next.resetsAt))-\($0)" })
    }

    func testWeeklyLimitAlertsAndSpendLimitDoesNot() {
        let week = Window(usedPercentage: 93, resetsAt: now + 2 * 86400)
        let spend = Window(usedPercentage: 99, resetsAt: now + 86400, usedUSD: 9.9, limitUSD: 10)
        XCTAssertEqual(
            due([.fiveHour: fiveHour(92), .sevenDay: week, .spendLimit: spend], every: 10).map(\.title),
            ["5-hour limit at 92%", "7-day limit at 93%"])
    }
}
