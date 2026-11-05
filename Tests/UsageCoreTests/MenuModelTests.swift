import XCTest
@testable import UsageCore

final class MenuModelTests: TempTestCase {
    func model(_ windows: [WindowName: Window], checkedAt: Double? = nil, updatedAt: Double? = nil,
               probeState: [String: Any] = [:], paused: Bool = false) -> MenuModel {
        let at = checkedAt ?? now!
        let cache = UsageCache(windows: windows, updatedAt: updatedAt ?? at, checkedAt: at)
        return MenuModel.build(cache: cache, probeState: probeState, paused: paused, now: now, staleAfter: 3600)
    }

    func open(_ pct: Double, left: Double = 3600) -> Window {
        Window(usedPercentage: pct, resetsAt: now + left)
    }

    /// A 5-hour window `elapsed` seconds in.
    func fiveHour(_ pct: Double, elapsed: Double) -> Window {
        Window(usedPercentage: pct, resetsAt: now + 5 * 3600 - elapsed)
    }

    func row(_ m: MenuModel, _ name: WindowName) -> WindowRow { m.rows.first { $0.name == name }! }

    func testNoDataShowsSetupHelp() {
        let m = MenuModel.build(cache: UsageCache(), probeState: [:], paused: false, now: now, staleAfter: 3600)
        XCTAssertFalse(m.hasData)
        XCTAssertEqual(m.title, "–")
    }

    func testTitleAndColors() {
        // 92% four hours into the 5-hour window also runs out before the reset.
        let m = model([.fiveHour: open(92), .sevenDay: open(41, left: 86400 * 3)])
        XCTAssertEqual(m.title, "92%↗ · 41%")
        XCTAssertEqual(m.titleLevel, .critical)
        XCTAssertEqual(row(m, .fiveHour).level, .critical)
        XCTAssertEqual(m.remaining, 8)
    }

    func testOrangeFrom70() {
        let m = model([.fiveHour: open(75), .sevenDay: open(20, left: 86400)])
        XCTAssertEqual(m.title, "75% · 20%")
        XCTAssertEqual(m.titleLevel, .warning)
    }

    func testPassedWindowShowsAsReset() {
        let m = model([.fiveHour: Window(usedPercentage: 80, resetsAt: now - 10)])
        XCTAssertEqual(m.title, "0%↺")
        XCTAssertEqual(row(m, .fiveHour).percent, 0)
        XCTAssertTrue(row(m, .fiveHour).detail.hasPrefix("Window has reset"))
        XCTAssertNil(row(m, .fiveHour).paceMark)
    }

    func testStaleWhenNoRecentReading() {
        let m = model([.fiveHour: open(10)], checkedAt: now - 3 * 3600)
        XCTAssertEqual(m.title, "10% ⚠")
        XCTAssertEqual(m.lastReading, "Last reading 3h 00m ago (stale)")
        XCTAssertNotNil(m.staleNote)
    }

    func testUnchangedButRecentlyCheckedIsNotStale() {
        let m = model([.fiveHour: open(10)], checkedAt: now - 300, updatedAt: now - 3 * 3600)
        XCTAssertFalse(m.title.contains("⚠"))
        XCTAssertEqual(m.lastReading, "Last reading 5m ago")
    }

    func testResetTime() {
        let m = model([.fiveHour: open(10, left: 2 * 3600 + 15 * 60 + 30)])
        XCTAssertTrue(row(m, .fiveHour).detail.hasPrefix("Resets in 2h 15m ("), row(m, .fiveHour).detail)
    }

    func testSpendLimit() {
        let spend = Window(usedPercentage: 30, resetsAt: now + 86400 * 10, usedUSD: 1.5, limitUSD: 10, period: "monthly")
        let m = model([.fiveHour: open(10), .spendLimit: spend])
        XCTAssertEqual(row(m, .spendLimit).spend, "$1.50 of $10.00 monthly")
        XCTAssertEqual(m.title, "10%")  // spend isn't part of the title
    }

    // MARK: Pace

    func testHeadingOverShowsRunOutTime() {
        // 48% after 2h: 100% at 4h10m, 50 minutes before the reset.
        let m = model([.fiveHour: fiveHour(48, elapsed: 2 * 3600)])
        XCTAssertEqual(m.title, "48%↗")
        XCTAssertEqual(m.titleLevel, .warning)  // orange though under 70%
        XCTAssertEqual(row(m, .fiveHour).runsOut, Format.clock(now + 2 * 3600 + 600, now: now))
    }

    func testOnTrackShowsNoRunOutTime() {
        let m = model([.fiveHour: fiveHour(22, elapsed: 2 * 3600)])  // ends near 55%
        XCTAssertNil(row(m, .fiveHour).runsOut)
        XCTAssertEqual(m.title, "22%")
        XCTAssertEqual(m.titleLevel, .normal)
    }

    func testNoRunOutTimeEarlyInWindow() {
        let m = model([.fiveHour: fiveHour(10, elapsed: 600)])  // would project 300%
        XCTAssertNil(row(m, .fiveHour).runsOut)
    }

    func testWeeklyRunOutShowsTheDay() {
        let week = Window(usedPercentage: 50, resetsAt: now + 4 * 86400)  // 3 days in
        let m = model([.fiveHour: fiveHour(10, elapsed: 2 * 3600), .sevenDay: week])
        XCTAssertEqual(m.title, "10% · 50%↗")
        let out = row(m, .sevenDay).runsOut ?? ""
        XCTAssertEqual(out, Format.clock(now + 3 * 86400, now: now))
        XCTAssertEqual(out.count, 9, out)  // "Sat 09:00"
    }

    func testPaceMarkIsTimePassed() {
        let m = model([.fiveHour: fiveHour(0, elapsed: 2 * 3600)])
        XCTAssertEqual(row(m, .fiveHour).paceMark!, 0.4, accuracy: 0.001)
    }

    // MARK: Auto-check line

    func testAutoCheckPaused() {
        let m = model([.fiveHour: open(10)], paused: true)
        XCTAssertEqual(m.autoCheck, "Auto-check: paused")
        XCTAssertTrue(m.paused)
    }

    func testAutoCheckIdleAndLastGoodCheck() {
        let m = model([.fiveHour: open(10)],
                      probeState: ["last_run": now - 120, "ok": true, "skipped": AutoCheck.idleReason])
        XCTAssertEqual(m.autoCheck, "Auto-check: on · idle, waiting for activity · last check 2m ago ✓")
        XCTAssertNil(m.autoCheckError)
    }

    func testAutoCheckFailureShowsError() {
        let m = model([.fiveHour: open(10)],
                      probeState: ["last_run": now - 60, "ok": false, "error": "Invalid API key"])
        XCTAssertTrue(m.autoCheck.hasSuffix("last check 1m ago ✗"), m.autoCheck)
        XCTAssertEqual(m.autoCheckError, "Invalid API key")
    }
}
