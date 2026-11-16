import Foundation

/// A notification: what its banner says.
public struct Alert: Equatable {
    public var title: String
    public var body: String
}

/// When to send a notification, decided from the menu's rows. For the
/// 5-hour and the weekly limit, each of these once per window:
///
///     every step   usage passed another 10% (or 20, 25, 50: your choice)
///     pace         on course to run out before the reset (the orange "runs out")
///     reset        the limit has reset, after reaching 90%
public enum Alerts {
    /// The menu's choices: a notification every this many percent.
    public static let steps = [10, 20, 25, 50]
    /// Preferences key for the chosen step; 0 or missing is off.
    public static let stepKey = "notifyEveryPercent"
    public static let sentKey = "sentAlerts"

    /// The alerts to send now. `sent` lists what was already sent, as
    /// "five_hour-<resets_at>-pace". It's updated here, and entries for
    /// windows that are no longer in the cache are dropped.
    public static func due(_ rows: [WindowRow], every step: Int, sent: inout [String]) -> [Alert] {
        var alerts: [Alert] = []
        var kept: [String] = []
        for row in rows where row.name != .spendLimit {
            // resets_at tells one window from the next, as in the merge rule.
            let window = "\(row.name.rawValue)-\(Int(row.resetsAt))-"
            var mine = sent.filter { $0.hasPrefix(window) }
            let limit = "\(row.name.label) limit"
            func has(_ kind: String) -> Bool { mine.contains(window + kind) }
            func mark(_ kind: String) { if !has(kind) { mine.append(window + kind) } }

            if row.hasReset {
                // Only worth a notification if the limit was nearly used up.
                if has("90"), !has("reset") {
                    mark("reset")
                    alerts.append(Alert(title: "\(limit) has reset", body: ""))
                }
            } else {
                // The whole percent the menu bar shows, so the two agree.
                let percent = Int(Format.percent(row.percent)) ?? 0
                let level = step > 0 ? percent / step * step : 0
                // The highest step already announced: several passed at once
                // are one notification, and a new choice of step doesn't
                // announce a level again.
                let told = mine.compactMap { $0.hasPrefix(window + "at-") ? Int($0.dropFirst(window.count + 3)) : nil }
                    .max() ?? 0
                if level > told {
                    mine.removeAll { $0.hasPrefix(window + "at-") }
                    mark("at-\(level)")
                    let runsOut = row.runsOut.map { " · runs out ~\($0)" } ?? ""
                    alerts.append(Alert(title: "\(limit) at \(percent)%", body: row.detail + runsOut))
                    // That said when it runs out, so it was the pace alert too.
                    if row.runsOut != nil { mark("pace") }
                } else if let out = row.runsOut, !has("pace") {
                    mark("pace")
                    alerts.append(Alert(title: "\(limit) runs out ~\(out)", body: "\(percent)% used · \(row.detail)"))
                }
                // Remembered for the reset alert, whatever the step.
                if row.level == .critical { mark("90") }
            }
            kept += mine
        }
        sent = kept
        return alerts
    }
}
