import Foundation

public enum WindowName: String, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case spendLimit = "spend_limit"

    public var label: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .spendLimit: return "Spend"
        }
    }

    /// Fixed window length; nil for the spend limit, whose period varies.
    public var length: TimeInterval? {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86400
        case .spendLimit: return nil
        }
    }

    /// No run-out estimate before this much of a window has passed: a few
    /// minutes of use would otherwise project something silly.
    public var minElapsedForEstimate: TimeInterval {
        switch self {
        case .fiveHour: return 30 * 60
        case .sevenDay: return 12 * 3600
        case .spendLimit: return .infinity
        }
    }
}

/// One rate-limit window as Claude Code reports it.
public struct Window: Equatable {
    public var usedPercentage: Double
    public var resetsAt: Double
    public var seenAt: Double?
    public var usedUSD: Double?
    public var limitUSD: Double?
    public var period: String?

    public init(usedPercentage: Double, resetsAt: Double, seenAt: Double? = nil,
                usedUSD: Double? = nil, limitUSD: Double? = nil, period: String? = nil) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.seenAt = seenAt
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
        self.period = period
    }

    /// Keeps only the fields we use; nil for anything malformed. All field
    /// parsing lives here: if Claude Code renames a field, fix it here.
    public init?(json: Any?) {
        guard let raw = json as? [String: Any],
              let pct = raw.double("used_percentage"),
              let resetsAt = raw.double("resets_at") else { return nil }
        self.init(usedPercentage: pct, resetsAt: resetsAt.rounded(.down),
                  seenAt: raw.double("seen_at"), usedUSD: raw.double("used_usd"),
                  limitUSD: raw.double("limit_usd"), period: raw["period"] as? String)
    }

    public var json: [String: Any] {
        var out: [String: Any] = ["used_percentage": usedPercentage, "resets_at": Int(resetsAt)]
        if let seenAt { out["seen_at"] = Int(seenAt) }
        if let usedUSD { out["used_usd"] = usedUSD }
        if let limitUSD { out["limit_usd"] = limitUSD }
        if let period { out["period"] = period }
        return out
    }

    /// Usage within a window only goes up, so accept a value only if it's
    /// from a newer window, or the same window with a higher percentage.
    /// An idle session holding old data can't overwrite fresher data.
    public func isNewer(than current: Window?) -> Bool {
        guard let current else { return true }
        if resetsAt != current.resetsAt { return resetsAt > current.resetsAt }
        return usedPercentage > current.usedPercentage
    }
}

/// The cache file the status line and auto-check write and the app reads.
public struct UsageCache {
    public var windows: [WindowName: Window] = [:]
    public var updatedAt: Double?
    /// Last time any source delivered a reading, even if nothing changed.
    public var checkedAt: Double?

    public init(windows: [WindowName: Window] = [:], updatedAt: Double? = nil, checkedAt: Double? = nil) {
        self.windows = windows
        self.updatedAt = updatedAt
        self.checkedAt = checkedAt
    }

    public init(json: [String: Any]) {
        for (key, raw) in json["windows"] as? [String: Any] ?? [:] {
            if let name = WindowName(rawValue: key), let window = Window(json: raw) {
                windows[name] = window
            }
        }
        updatedAt = json.double("updated_at")
        checkedAt = json.double("checked_at")
    }

    public static func load(_ url: URL) -> UsageCache { UsageCache(json: loadJSONObject(url)) }

    public var json: [String: Any] {
        var out: [String: Any] = [
            "schema": 1,
            "windows": Dictionary(uniqueKeysWithValues: windows.map { ($0.key.rawValue, $0.value.json) }),
        ]
        if let updatedAt { out["updated_at"] = Int(updatedAt) }
        if let checkedAt { out["checked_at"] = Int(checkedAt) }
        return out
    }

    /// Latest moment a reading confirmed these numbers.
    public var lastReading: Double { max(checkedAt ?? 0, updatedAt ?? 0) }

    /// Merges incoming windows (Claude Code's `rate_limits` shape). Returns
    /// true if anything changed.
    @discardableResult
    public mutating func merge(_ rateLimits: [String: Any], now: Double) -> Bool {
        var changed = false
        for name in WindowName.allCases {
            guard var incoming = Window(json: rateLimits[name.rawValue]) else { continue }
            if incoming.isNewer(than: windows[name]) {
                incoming.seenAt = now.rounded(.down)
                windows[name] = incoming
                changed = true
            }
        }
        if changed { updatedAt = now.rounded(.down) }
        return changed
    }
}

/// Merges a fresh reading under a lock (the status line and auto-check can
/// race). `checked_at` records that a reading arrived now, even when no
/// number changed; auto-check uses it to skip checks that wouldn't add anything.
public func updateCache(_ rateLimits: [String: Any], now: Double, at url: URL) throws {
    let lock = url.deletingLastPathComponent().appendingPathComponent(".lock")
    _ = try withFileLock(lock) {
        var cache = UsageCache.load(url)
        cache.merge(rateLimits, now: now)
        if !cache.windows.isEmpty {
            cache.checkedAt = now.rounded(.down)
            try writeJSONObject(cache.json, to: url)
        }
    }
}
