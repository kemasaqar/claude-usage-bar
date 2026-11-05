import Foundation

public enum Level: Equatable {
    case normal, warning, critical

    /// Orange from 70%, red from 90%.
    public static func forPercent(_ pct: Double) -> Level {
        pct >= 90 ? .critical : pct >= 70 ? .warning : .normal
    }
}

public struct WindowRow: Equatable {
    public var name: WindowName
    public var percent: Double
    public var level: Level
    public var hasReset: Bool
    /// 0...1: how much of the window has passed, where an even pace would
    /// put you now. Drawn as a marker on the bar.
    public var paceMark: Double?
    /// "Resets in 2h 14m (16:30)" or "Window has reset (...)".
    public var detail: String
    /// "15:40" when the current pace runs out before the reset.
    public var runsOut: String?
    public var spend: String?
}

/// Everything the menu bar item and its menu show, computed from the files.
/// The app only draws this, so all the decisions here are testable.
public struct MenuModel: Equatable {
    public var title: String
    public var titleLevel: Level
    /// What's left of the higher usage, for the battery icon (0...100).
    public var remaining: Double
    public var rows: [WindowRow]
    public var lastReading: String?
    public var staleNote: String?
    public var autoCheck: String
    public var autoCheckError: String?
    public var paused: Bool

    public var hasData: Bool { !rows.isEmpty }

    public static func build(
        cache: UsageCache, probeState: [String: Any], paused: Bool, now: Double,
        staleAfter: TimeInterval, timeZone: TimeZone = .current
    ) -> MenuModel {
        let auto = autoCheckLine(probeState: probeState, paused: paused,
                                 headingOver: AutoCheck.headingOver(cache, now: now), now: now)
        guard !cache.windows.isEmpty else {
            return MenuModel(title: "–", titleLevel: .normal, remaining: 100, rows: [],
                             lastReading: nil, staleNote: nil, autoCheck: auto.line,
                             autoCheckError: auto.error, paused: paused)
        }

        var rows: [WindowRow] = []
        for name in WindowName.allCases {
            guard let window = cache.windows[name] else { continue }
            let hasReset = window.resetsAt <= now
            // A passed reset means the number belongs to an old window:
            // treat it as 0 until fresh data arrives.
            let pct = hasReset ? 0 : window.usedPercentage
            let out = hasReset ? nil : runsOutAt(name, window, now: now)
            let detail = hasReset
                ? "Window has reset (0% until the next reading)"
                : "Resets in \(Format.duration(window.resetsAt - now)) "
                    + "(\(Format.clock(window.resetsAt, now: now, timeZone: timeZone)))"
            var spend: String?
            if name == .spendLimit, let used = window.usedUSD, let limit = window.limitUSD {
                spend = String(format: "$%.2f of $%.2f", used, limit)
                    + (window.period.map { " \($0)" } ?? "")
            }
            rows.append(WindowRow(
                name: name, percent: pct, level: .forPercent(pct), hasReset: hasReset,
                paceMark: hasReset ? nil : elapsedFraction(name, window, now: now),
                detail: detail,
                runsOut: out.map { Format.clock($0, now: now, timeZone: timeZone) },
                spend: spend))
        }

        // Title: 5h and 7d percentages, colored by the worse of the two.
        // ↗ marks a window that runs out before its reset at the current pace.
        let limits = rows.filter { $0.name != .spendLimit }
        let worst = limits.map(\.percent).max() ?? 0
        let headingOver = limits.contains { $0.runsOut != nil }
        var title = limits.map { row in
            Format.percent(row.percent) + "%" + (row.hasReset ? "↺" : "") + (row.runsOut != nil ? "↗" : "")
        }.joined(separator: " · ")
        if title.isEmpty { title = "–" }

        // Stale means no reading arrived lately, not that the numbers didn't move.
        let stale = now - cache.lastReading > staleAfter
        if stale { title += " ⚠" }
        var level = Level.forPercent(worst)
        if level == .normal && headingOver { level = .warning }

        return MenuModel(
            title: title, titleLevel: level, remaining: 100 - worst, rows: rows,
            lastReading: "Last reading \(Format.duration(now - cache.lastReading)) ago"
                + (stale ? " (stale)" : ""),
            staleNote: stale
                ? "No reading in the last \(Int(staleAfter / 60))m. Checks pause while you're "
                    + "idle with no open 5-hour window, so a check doesn't start one."
                : nil,
            autoCheck: auto.line, autoCheckError: auto.error, paused: paused)
    }

    static func autoCheckLine(probeState: [String: Any], paused: Bool, headingOver: Bool = false,
                              now: Double) -> (line: String, error: String?) {
        var status = paused ? "paused" : headingOver ? "every 1m" : "on"
        if !paused, !headingOver, (probeState["skipped"] as? String)?.hasPrefix("idle") == true {
            status += " · idle, waiting for activity"
        }
        var error: String?
        if let lastRun = probeState.double("last_run"), lastRun > 0 {
            let ok = probeState["ok"] as? Bool == true
            status += " · checked \(Format.duration(now - lastRun)) ago \(ok ? "✓" : "✗")"
            if !ok { error = probeState["error"] as? String }
        }
        return ("Auto-check: \(status)", error)
    }
}

/// How much of the window has passed (0...1), or nil for the spend limit.
public func elapsedFraction(_ name: WindowName, _ window: Window, now: Double) -> Double? {
    guard let length = name.length else { return nil }
    let start = window.resetsAt - length
    return min(1, max(0, (now - start) / length))
}

/// When usage hits 100% if it keeps its average pace since the window
/// started. Nil if it lasts until the reset, or it's too early to tell.
public func runsOutAt(_ name: WindowName, _ window: Window, now: Double) -> Double? {
    guard let length = name.length, window.usedPercentage > 0, window.usedPercentage < 100 else {
        return nil
    }
    let start = window.resetsAt - length
    let elapsed = now - start
    guard elapsed >= name.minElapsedForEstimate else { return nil }
    let out = start + elapsed * 100 / window.usedPercentage
    return out < window.resetsAt ? out : nil
}
