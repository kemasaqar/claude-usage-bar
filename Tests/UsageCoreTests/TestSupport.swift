import Foundation
import XCTest
@testable import UsageCore

/// A throwaway home, cache, config and projects folder per test. Nothing
/// touches your real files, and claude is a fake unless a test makes one.
class TempTestCase: XCTestCase {
    var root: URL!
    var paths: UsagePaths!
    var now: Double!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = UsagePaths(
            home: home,
            cache: root.appendingPathComponent("cache/usage.json"),
            config: root.appendingPathComponent("config/config.json"),
            projects: root.appendingPathComponent("projects"),
            claudeOverride: root.appendingPathComponent("no-claude").path,
            probeInterval: 300, probeTimeout: 90, chainTimeout: 5, staleAfter: 3600)
        now = Date().timeIntervalSince1970.rounded(.down)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func rateLimits(five: (Double, Double)? = nil, seven: (Double, Double)? = nil) -> [String: Any] {
        var out: [String: Any] = [:]
        if let five { out["five_hour"] = ["used_percentage": five.0, "resets_at": five.1] }
        if let seven { out["seven_day"] = ["used_percentage": seven.0, "resets_at": seven.1] }
        return out
    }

    func payload(_ rateLimits: [String: Any]? = nil) -> Data {
        var p: [String: Any] = [
            "model": ["id": "claude-opus-5-5", "display_name": "Opus"],
            "workspace": ["current_dir": "/tmp/myproj"],
            "context_window": ["used_percentage": 8],
        ]
        if let rateLimits { p["rate_limits"] = rateLimits }
        return try! JSONSerialization.data(withJSONObject: p)
    }

    func cached() -> [WindowName: Window] { UsageCache.load(paths.cache).windows }

    func writeCache(_ windows: [WindowName: Window], checkedAt: Double? = nil, updatedAt: Double? = nil) throws {
        let at = checkedAt ?? now!
        try writeJSONObject(
            UsageCache(windows: windows, updatedAt: updatedAt ?? at, checkedAt: at).json, to: paths.cache)
    }

    func writeFile(_ url: URL, _ text: String, executable: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
