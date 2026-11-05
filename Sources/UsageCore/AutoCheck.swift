import Foundation

/// The status line only runs in terminal sessions. For the desktop app and
/// editor panels, auto-check runs a tiny headless request,
///
///     claude -p --model haiku --tools "" --system-prompt "Reply with ok." ...
///
/// and reads the `rate_limit_event` from its stream-json output. It costs
/// roughly a thousand Haiku tokens and saves no session.
public enum AutoCheck {
    public static let idleReason = "idle, no open 5-hour window"
    /// How often to check while the 5-hour limit is heading over.
    public static let headingOverInterval: TimeInterval = 60

    public enum Outcome: Equatable {
        case ok
        case failed(String)
        case alreadyRunning
    }

    // MARK: Decision

    /// Check every interval while a 5-hour window is open or you're active.
    /// When idle with no open window, a request would itself start a new
    /// 5-hour window and shift your reset times, so wait for real activity.
    public static func shouldCheck(now: Double, paths: UsagePaths) -> (Bool, String) {
        if FileManager.default.fileExists(atPath: paths.pauseFlag.path) { return (false, "paused") }
        let cache = UsageCache.load(paths.cache)
        let lastReading = max(cache.checkedAt ?? 0, loadState(paths).double("last_run") ?? 0)
        if now - lastReading < interval(cache, now: now, paths: paths) { return (false, "recent reading") }
        if lastActivity(paths.projects) > lastReading { return (true, "activity since last reading") }
        if let fiveHour = cache.windows[.fiveHour], fiveHour.resetsAt > now {
            return (true, "5-hour window open")
        }
        return (false, idleReason)
    }

    /// Every minute while the 5-hour limit would run out before it resets at
    /// your current pace (the orange "runs out" in the menu), so you see it
    /// coming. Otherwise the normal interval (5 minutes). The weekly limit
    /// moves too slowly for faster checks to tell you anything new.
    public static func interval(_ cache: UsageCache, now: Double, paths: UsagePaths) -> TimeInterval {
        headingOver(cache, now: now) ? min(paths.probeInterval, headingOverInterval) : paths.probeInterval
    }

    public static func headingOver(_ cache: UsageCache, now: Double) -> Bool {
        guard let fiveHour = cache.windows[.fiveHour] else { return false }
        return runsOutAt(.fiveHour, fiveHour, now: now) != nil
    }

    /// Runs a check if `shouldCheck` says so; records why not otherwise.
    @discardableResult
    public static func auto(now: Double, paths: UsagePaths) -> Outcome? {
        let (go, why) = shouldCheck(now: now, paths: paths)
        if go { return check(now: now, paths: paths) }
        var state = loadState(paths)
        if why != "recent reading", state["skipped"] as? String != why {
            state["skipped"] = why  // shown in the menu
            try? writeJSONObject(state, to: paths.probeState)
        }
        return nil
    }

    // MARK: Check

    public static func check(now: Double, paths: UsagePaths) -> Outcome {
        let lock = paths.stateDir.appendingPathComponent(".probe-lock")
        let locked: Outcome??
        do {
            locked = try withFileLock(lock, wait: false) { () -> Outcome in
                runLocked(now: now, paths: paths)
            }
        } catch {
            return .failed(String(describing: error))
        }
        return locked.flatMap { $0 } ?? .alreadyRunning
    }

    private static func runLocked(now: Double, paths: UsagePaths) -> Outcome {
        var state: [String: Any] = ["last_run": Int(now)]
        let outcome: Outcome
        do {
            guard let claude = findClaude(paths) else {
                throw CheckError("claude not found; set CLAUDE_USAGE_BAR_CLAUDE")
            }
            let rateLimits = try runClaude(claude, paths: paths)
            try updateCache(rateLimits, now: Date().timeIntervalSince1970, at: paths.cache)
            state["ok"] = true
            outcome = .ok
        } catch {
            state["ok"] = false
            state["error"] = String(describing: error)
            outcome = .failed(String(describing: error))
        }
        try? writeJSONObject(state, to: paths.probeState)
        return outcome
    }

    public static func pause(_ paths: UsagePaths) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.pauseFlag.path, contents: nil)
    }

    public static func resume(_ paths: UsagePaths) {
        try? FileManager.default.removeItem(at: paths.pauseFlag)
    }

    public static func isPaused(_ paths: UsagePaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.pauseFlag.path)
    }

    public static func loadState(_ paths: UsagePaths) -> [String: Any] { loadJSONObject(paths.probeState) }

    // MARK: Pieces

    /// `CLAUDE_USAGE_BAR_CLAUDE`, if set, is the only one tried: a wrong path
    /// should show up as an error, not quietly fall back to another claude.
    public static func findClaude(_ paths: UsagePaths) -> String? {
        let candidates: [String]
        if let override = paths.claudeOverride {
            candidates = [override]
        } else {
            let home = paths.home.path
            candidates = searchPath(paths).map { $0 + "/claude" } + [
                home + "/.claude/local/claude",
            ]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Apps started from Finder or at login get a bare PATH, so add the usual
    /// install locations for claude (and for node, if claude is an npm script).
    static func searchPath(_ paths: UsagePaths) -> [String] {
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = [paths.home.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return (current + extra).filter { seen.insert($0).inserted }
    }

    static func runClaude(_ claude: String, paths: UsagePaths) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: paths.probeCwd, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath(paths).joined(separator: ":")
        // claude treats $PWD as the folder it's working in. An app opened
        // from a terminal inherits that terminal's PWD, which may be a
        // project on an external disk: claude then reads it, and macOS asks
        // you to let ClaudeUsageBar access removable volumes. Point it at
        // the empty probe folder instead.
        env["PWD"] = paths.probeCwd.path
        env.removeValue(forKey: "OLDPWD")
        let result = try runProgram(claude, [
            "-p",
            "--model", "haiku",
            "--output-format", "stream-json", "--verbose",
            "--max-turns", "1",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "project",  // empty probe-cwd: skips your hooks and plugins
            "--disable-slash-commands",
            "--no-session-persistence",
            "--system-prompt", "Reply with ok.",
            "ok",
        ], cwd: paths.probeCwd, environment: env, timeout: paths.probeTimeout)
        if result.timedOut {
            throw CheckError("claude timed out after \(Int(paths.probeTimeout))s")
        }
        var rateLimits: [String: Any] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["type"] as? String == "rate_limit_event" else { continue }
            rateLimits.merge(windows(fromEvent: event["rate_limit_info"] as? [String: Any] ?? [:])) { $1 }
        }
        if !rateLimits.isEmpty { return rateLimits }
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .split(separator: "\n").last.map { String($0.prefix(200)) }
        throw CheckError(detail ?? "no rate_limit_event (exit \(result.status))")
    }

    /// `rate_limit_info.unifiedWindows` to the status line's `rate_limits`
    /// shape. Utilization is a 0..1 fraction here; the status line uses 0..100.
    public static func windows(fromEvent info: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, raw) in info["unifiedWindows"] as? [String: Any] ?? [:] {
            guard let window = raw as? [String: Any],
                  let utilization = window.double("utilization"),
                  let resetsAt = window.double("resetsAt") else { continue }
            out[name] = ["used_percentage": (utilization * 1000).rounded() / 10, "resets_at": resetsAt]
        }
        return out
    }

    /// Newest transcript write across all Claude Code sessions, any app.
    public static func lastActivity(_ projects: URL) -> Double {
        let fm = FileManager.default
        var newest = 0.0
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                newest = max(newest, modified)
            }
        }
        return newest
    }
}

public struct CheckError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
