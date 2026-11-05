import XCTest
@testable import UsageCore

final class StatusLineTests: TempTestCase {
    func handle(_ input: Data) -> String { StatusLine.handle(input: input, paths: paths, now: now) }

    func testWritesCacheAndPrintsStatusLine() {
        let out = handle(payload(rateLimits(five: (23.5, now + 3600), seven: (41.2, now + 86400 * 3))))
        XCTAssertTrue(out.contains("Opus"), out)
        XCTAssertTrue(out.contains("myproj"), out)
        XCTAssertTrue(out.contains("ctx 8%"), out)
        XCTAssertTrue(out.contains("5h 24% (1h00m)") || out.contains("5h 24% (59m)"), out)
        XCTAssertTrue(out.contains("7d 41%"), out)
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 23.5)
        XCTAssertEqual(cached()[.sevenDay]?.usedPercentage, 41.2)
    }

    func testLowerValueInSameWindowIsIgnored() {
        _ = handle(payload(rateLimits(five: (50, now + 3600))))
        _ = handle(payload(rateLimits(five: (30, now + 3600))))  // a stale session
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 50)
    }

    func testHigherValueInSameWindowWins() {
        _ = handle(payload(rateLimits(five: (30, now + 3600))))
        _ = handle(payload(rateLimits(five: (55, now + 3600))))
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 55)
    }

    func testNewerWindowReplacesEvenIfLower() {
        _ = handle(payload(rateLimits(five: (90, now + 60))))
        _ = handle(payload(rateLimits(five: (2, now + 5 * 3600))))
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 2)
    }

    func testOlderWindowIsIgnored() {
        _ = handle(payload(rateLimits(five: (2, now + 5 * 3600))))
        _ = handle(payload(rateLimits(five: (90, now + 60))))
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 2)
    }

    func testMissingRateLimitsKeepsCache() {
        _ = handle(payload(rateLimits(five: (10, now + 3600))))
        let out = handle(payload())  // e.g. a new session before its first reply
        XCTAssertFalse(out.contains("5h"), out)
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 10)
    }

    func testGarbageInputDoesNotCrash() {
        XCTAssertEqual(handle(Data("not json".utf8)), "")
        XCTAssertEqual(handle(Data(#"{"rate_limits": {"five_hour": "x"}}"#.utf8)), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cache.path))
    }

    func testMergeKeepsCheckedAtCurrentEvenWhenNothingChanged() throws {
        _ = handle(payload(rateLimits(five: (10, now + 3600))))
        let later = now + 600
        _ = StatusLine.handle(input: payload(rateLimits(five: (10, now + 3600))), paths: paths, now: later)
        let cache = UsageCache.load(paths.cache)
        XCTAssertEqual(cache.checkedAt, later)
        XCTAssertEqual(cache.updatedAt, now)
    }

    // MARK: Your original status line

    func keepOriginal(_ command: String) throws {
        try writeJSONObject(["original_status_line": ["type": "command", "command": command]], to: paths.config)
    }

    func testOriginalStatusLineIsShownAndCacheStillUpdated() throws {
        try keepOriginal("printf 'mine: '; head -c 12")  // echoes part of its stdin
        let input = Data(#"{"model": {"display_name": "Opus"}, "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": \#(Int(now) + 3600)}}}"#.utf8)
        XCTAssertEqual(handle(input), #"mine: {"model": {""#)
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 23.5)
    }

    func testFailingOriginalStatusLineFallsBackToOurs() throws {
        try keepOriginal("echo broken; exit 3")
        XCTAssertTrue(handle(payload(rateLimits(five: (23.5, now + 3600)))).contains("5h 24%"))
    }

    func testSlowOriginalStatusLineFallsBackInTime() throws {
        // Not `exec sleep`: the shell's child keeps the output pipe open.
        try keepOriginal("sleep 4; echo late")
        paths.chainTimeout = 0.5
        let start = Date()
        let out = handle(payload(rateLimits(five: (23.5, now + 3600))))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertTrue(out.contains("5h 24%"), out)
    }

    func testFormatting() {
        XCTAssertEqual(Format.duration(3 * 86400 + 4 * 3600 + 59), "3d 4h")
        XCTAssertEqual(Format.duration(2 * 3600 + 5 * 60), "2h 05m")
        XCTAssertEqual(Format.duration(12 * 60 + 30), "12m")
        XCTAssertEqual(Format.duration(-5), "0m")
        XCTAssertEqual(Format.compactDuration(2 * 3600 + 14 * 60), "2h14m")
        XCTAssertEqual(Format.percent(23.5), "24")
        XCTAssertEqual(Format.percent(22.5), "22")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Format.clock(3600 * 16.5, now: 3600 * 14, timeZone: utc), "16:30")
        XCTAssertEqual(Format.clock(86400 * 4 + 9 * 3600, now: 0, timeZone: utc), "Mon 09:00")
    }
}
