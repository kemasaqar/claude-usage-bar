import Foundation

/// Where everything lives. Same files and environment variables as the
/// Python version, so switching keeps your readings and settings.
public struct UsagePaths {
    public var home: URL
    public var cache: URL
    public var config: URL
    public var projects: URL
    public var claudeOverride: String?
    public var probeInterval: TimeInterval
    public var probeTimeout: TimeInterval
    public var chainTimeout: TimeInterval
    public var staleAfter: TimeInterval

    public var stateDir: URL { cache.deletingLastPathComponent() }
    public var pauseFlag: URL { stateDir.appendingPathComponent("auto-check-paused") }
    public var probeState: URL { stateDir.appendingPathComponent("probe.json") }
    public var probeCwd: URL { stateDir.appendingPathComponent("probe-cwd") }
    public var settings: URL { home.appendingPathComponent(".claude/settings.json") }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> UsagePaths {
        // $HOME first, like the Python version, so tests can point it elsewhere.
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
        func path(_ key: String, _ fallback: String) -> URL {
            URL(fileURLWithPath: env[key] ?? home.appendingPathComponent(fallback).path)
        }
        func number(_ key: String, _ fallback: Double) -> Double {
            env[key].flatMap(Double.init) ?? fallback
        }
        return UsagePaths(
            home: home,
            cache: path("CLAUDE_USAGE_BAR_CACHE", ".cache/claude-usage-bar/usage.json"),
            // Not in the cache folder: deleting the cache must not lose your status line.
            config: path("CLAUDE_USAGE_BAR_CONFIG", ".config/claude-usage-bar/config.json"),
            projects: path("CLAUDE_USAGE_BAR_PROJECTS", ".claude/projects"),
            claudeOverride: env["CLAUDE_USAGE_BAR_CLAUDE"].flatMap { $0.isEmpty ? nil : $0 },
            probeInterval: number("CLAUDE_USAGE_BAR_PROBE_MIN", 5) * 60,
            probeTimeout: number("CLAUDE_USAGE_BAR_PROBE_TIMEOUT_S", 90),
            chainTimeout: number("CLAUDE_USAGE_BAR_CHAIN_TIMEOUT_S", 5),
            staleAfter: number("CLAUDE_USAGE_BAR_STALE_MIN", 60) * 60
        )
    }
}

/// A JSON object from disk; anything missing or malformed reads as empty.
public func loadJSONObject(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else { return [:] }
    return dict
}

/// Atomic write (temp file + rename), so a reader never sees half a file.
public func writeJSONObject(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
}

/// Runs `body` while holding an exclusive lock on `url`. With `wait` false,
/// returns nil straight away if someone else holds it.
public func withFileLock<T>(_ url: URL, wait: Bool = true, _ body: () throws -> T) throws -> T? {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    if flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
        if !wait && errno == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return try body()
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        // JSON booleans also bridge to numbers; don't treat them as one.
        guard let number = self[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
