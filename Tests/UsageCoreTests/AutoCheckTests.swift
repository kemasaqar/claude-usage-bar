import XCTest
@testable import UsageCore

final class AutoCheckTests: TempTestCase {
    var log: URL { root.appendingPathComponent("calls.log") }

    /// A fake `claude` that logs its arguments and prints stream-json.
    /// mode: ok, fail (an error), noevent (no rate_limit_event), slow (hangs).
    func fakeClaude(_ mode: String = "ok") throws {
        let fake = root.appendingPathComponent("claude")
        let reset = Int(now) + 3600
        try writeFile(fake, """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        printf '%s\\n' "$PWD" > '\(root.appendingPathComponent("pwd.log").path)'
        case '\(mode)' in
          fail) echo "Invalid API key" >&2; exit 1 ;;
          slow) sleep 30 ;;
        esac
        echo '{"type":"system","subtype":"init"}'
        if [ '\(mode)' = ok ]; then
          echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.25,"resetsAt":\(reset)},"seven_day":{"utilization":0.5,"resetsAt":\(reset + 86400)}}}}'
        fi
        echo '{"type":"result","subtype":"success"}'
        """, executable: true)
        paths.claudeOverride = fake.path
    }

    func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func state() -> [String: Any] { AutoCheck.loadState(paths) }

    func cacheAt(checked: Double, fiveHourReset: Double? = nil) throws {
        try writeCache([.fiveHour: Window(usedPercentage: 10, resetsAt: fiveHourReset ?? now + 3600)],
                       checkedAt: checked)
    }

    func touchTranscript(_ mtime: Double) throws {
        let file = paths.projects.appendingPathComponent("proj/session.jsonl")
        try writeFile(file, "{}\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: file.path)
    }

    // MARK: Check

    func testCheckWritesCacheFromRateLimitEvent() throws {
        try fakeClaude()
        XCTAssertEqual(AutoCheck.check(now: now, paths: paths), .ok)
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 25)
        XCTAssertEqual(cached()[.sevenDay]?.usedPercentage, 50)
        let args = calls().first ?? ""
        for flag in ["-p", "--no-session-persistence", "--strict-mcp-config", "--model haiku"] {
            XCTAssertTrue(args.contains(flag), args)
        }
        XCTAssertEqual(state()["ok"] as? Bool, true)
    }

    func testClaudeRunsInTheProbeFolderWhateverPWDTheAppInherited() throws {
        // The test process's own PWD stands in for a terminal's (it's
        // usually this repo). claude must see the probe folder instead.
        try fakeClaude()
        XCTAssertEqual(AutoCheck.check(now: now, paths: paths), .ok)
        let seen = try String(contentsOf: root.appendingPathComponent("pwd.log"), encoding: .utf8)
        XCTAssertEqual(seen.trimmingCharacters(in: .newlines), paths.probeCwd.path)
    }

    func testFailureIsRecordedAndCacheUntouched() throws {
        try fakeClaude("fail")
        try cacheAt(checked: now - 3600)
        XCTAssertEqual(AutoCheck.check(now: now, paths: paths), .failed("Invalid API key"))
        XCTAssertEqual(state()["ok"] as? Bool, false)
        XCTAssertEqual(state()["error"] as? String, "Invalid API key")
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 10)
    }

    func testReplyWithoutRateLimitEventIsAFailure() throws {
        try fakeClaude("noevent")
        try cacheAt(checked: now - 3600)
        guard case .failed = AutoCheck.check(now: now, paths: paths) else { return XCTFail() }
        XCTAssertEqual(cached()[.fiveHour]?.usedPercentage, 10)
    }

    func testHungClaudeTimesOut() throws {
        try fakeClaude("slow")
        paths.probeTimeout = 1
        let start = Date()
        XCTAssertEqual(AutoCheck.check(now: now, paths: paths), .failed("claude timed out after 1s"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingClaudeIsReported() {
        guard case .failed(let message) = AutoCheck.check(now: now, paths: paths) else { return XCTFail() }
        XCTAssertTrue(message.contains("claude not found"), message)
    }

    func testSecondCheckWhileOneRunsIsSkipped() throws {
        try fakeClaude()
        let lock = paths.stateDir.appendingPathComponent(".probe-lock")
        let outcome = try withFileLock(lock) { AutoCheck.check(now: now, paths: paths) }
        XCTAssertEqual(outcome, .alreadyRunning)
        XCTAssertEqual(calls(), [])
    }

    func testWindowsFromEvent() {
        let out = AutoCheck.windows(fromEvent: ["unifiedWindows": [
            "five_hour": ["utilization": 0.0234, "resetsAt": 100],
            "bad": "x",
        ]])
        XCTAssertEqual((out["five_hour"] as? [String: Any])?["used_percentage"] as? Double, 2.3)
        XCTAssertNil(out["bad"])
    }

    // MARK: When to check

    func testChecksWhileWindowOpenEvenWhenIdle() throws {
        try fakeClaude()
        try cacheAt(checked: now - 3600)        // 5-hour window resets in 1h
        try touchTranscript(now - 7200)         // no activity since the last reading
        XCTAssertEqual(AutoCheck.auto(now: now, paths: paths), .ok)
        XCTAssertEqual(calls().count, 1)
    }

    func testSkipsWhenIdleAndWindowClosed() throws {
        try fakeClaude()
        try cacheAt(checked: now - 7200, fiveHourReset: now - 60)
        try touchTranscript(now - 9000)
        XCTAssertNil(AutoCheck.auto(now: now, paths: paths))
        XCTAssertEqual(calls(), [])
        XCTAssertEqual(state()["skipped"] as? String, AutoCheck.idleReason)
    }

    func testSkipsRecentReading() throws {
        try fakeClaude()
        try cacheAt(checked: now - 60)
        try touchTranscript(now)
        XCTAssertEqual(AutoCheck.shouldCheck(now: now, paths: paths).1, "recent reading")
        XCTAssertNil(AutoCheck.auto(now: now, paths: paths))
        XCTAssertEqual(calls(), [])
    }

    func testChecksAfterActivityThenNotTwice() throws {
        try fakeClaude()
        try cacheAt(checked: now - 3600, fiveHourReset: now - 60)
        try touchTranscript(now - 30)
        XCTAssertEqual(AutoCheck.auto(now: now, paths: paths), .ok)
        XCTAssertNil(AutoCheck.auto(now: now, paths: paths))
        XCTAssertEqual(calls().count, 1)
    }

    func testPauseAndResume() throws {
        try fakeClaude()
        try cacheAt(checked: now - 3600)
        try AutoCheck.pause(paths)
        XCTAssertEqual(AutoCheck.shouldCheck(now: now, paths: paths).1, "paused")
        XCTAssertNil(AutoCheck.auto(now: now, paths: paths))
        // Check now still works while paused.
        XCTAssertEqual(AutoCheck.check(now: now, paths: paths), .ok)
        AutoCheck.resume(paths)
        XCTAssertFalse(AutoCheck.isPaused(paths))
    }
}
