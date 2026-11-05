import Foundation

/// Claude Code runs `ClaudeUsageBar statusline` as its statusLine command and
/// pipes session JSON on stdin. We merge the plan rate limits into the cache
/// and print a status line. If you had a status line of your own when you
/// installed, it's saved in the config file, gets the same input, and its
/// output is shown instead of ours.
public enum StatusLine {
    public static func handle(input: Data, paths: UsagePaths, now: Double) -> String {
        let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            // Never break the status line over a cache problem.
            try? updateCache(rateLimits, now: now, at: paths.cache)
        }
        return runOriginal(input: input, config: paths.config, timeout: paths.chainTimeout)
            ?? render(payload: payload, now: now)
    }

    /// Output of the status line you had before installing, or nil if there
    /// wasn't one or it failed, in which case ours is shown.
    public static func runOriginal(input: Data, config: URL, timeout: TimeInterval) -> String? {
        let original = loadJSONObject(config)["original_status_line"] as? [String: Any]
        guard let command = original?["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty,
              let result = try? runProgram("/bin/sh", ["-c", command], input: input, timeout: timeout),
              !result.timedOut, result.status == 0 else { return nil }
        let out = result.stdout.hasSuffix("\n") ? String(result.stdout.dropLast()) : result.stdout
        return out.isEmpty ? nil : out
    }

    public static func render(payload: [String: Any], now: Double) -> String {
        var parts: [String] = []
        if let model = (payload["model"] as? [String: Any])?["display_name"] as? String {
            parts.append(model)
        }
        let workspace = payload["workspace"] as? [String: Any]
        if let cwd = workspace?["current_dir"] as? String ?? payload["cwd"] as? String, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            parts.append(name.isEmpty ? cwd : name)
        }
        if let ctx = (payload["context_window"] as? [String: Any])?.double("used_percentage") {
            parts.append("ctx \(Format.percent(ctx))%")
        }
        let rateLimits = payload["rate_limits"] as? [String: Any] ?? [:]
        for (name, label) in [(WindowName.fiveHour, "5h"), (.sevenDay, "7d")] {
            if let window = Window(json: rateLimits[name.rawValue]) {
                let left = Format.compactDuration(window.resetsAt - now)
                parts.append("\(label) \(Format.percent(window.usedPercentage))% (\(left))")
            }
        }
        return parts.joined(separator: " · ")
    }
}

public enum Format {
    /// Whole percent, rounding halves to even like the Python version.
    public static func percent(_ value: Double) -> String {
        String(Int(value.rounded(.toNearestOrEven)))
    }

    /// "3d 4h", "2h 05m", "12m".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86400, hours = s % 86400 / 3600, minutes = s % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes) }
        return "\(minutes)m"
    }

    /// "3d4h", "2h05m", "12m" for the status line.
    public static func compactDuration(_ seconds: Double) -> String {
        duration(seconds).replacingOccurrences(of: " ", with: "")
    }

    /// "16:30", or "Mon 09:00" when it's more than 20 hours away.
    public static func clock(_ timestamp: Double, now: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = timestamp - now > 20 * 3600 ? "EEE HH:mm" : "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
