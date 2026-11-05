import XCTest
@testable import UsageCore

final class SetupTests: TempTestCase {
    let command = SettingsSetup.command(executable: "/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar")
    let mine: [String: Any] = ["type": "command", "command": "~/.claude/my-status.sh", "padding": 0]

    func writeSettings(_ object: [String: Any]) throws { try writeJSONObject(object, to: paths.settings) }
    func settings() -> [String: Any] { loadJSONObject(paths.settings) }
    func statusLine() -> [String: Any] { settings()["statusLine"] as? [String: Any] ?? [:] }
    func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.settings.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix("settings.json.bak-") }
    }
    func install(_ at: Double = 1000) throws -> [String] {
        try SettingsSetup.install(command: command, paths: paths, now: Date(timeIntervalSince1970: at))
    }
    func uninstall() throws -> [String] {
        try SettingsSetup.uninstall(paths: paths, now: Date(timeIntervalSince1970: 2000))
    }

    func testCommandIsQuoted() {
        XCTAssertEqual(SettingsSetup.command(executable: "/Users/a b/X.app/Contents/MacOS/ClaudeUsageBar"),
                       "'/Users/a b/X.app/Contents/MacOS/ClaudeUsageBar' statusline")
        XCTAssertTrue(SettingsSetup.isOurs(["command": command]))
    }

    func testInstallWithoutSettingsFile() throws {
        _ = try install()
        XCTAssertEqual(statusLine()["command"] as? String, command)
        XCTAssertEqual(statusLine()["type"] as? String, "command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
    }

    func testInstallKeepsOtherSettingsAndBacksUp() throws {
        try writeSettings(["model": "opus", "env": ["FOO": "ü"]])
        _ = try install()
        XCTAssertEqual(settings()["model"] as? String, "opus")
        XCTAssertEqual((settings()["env"] as? [String: Any])?["FOO"] as? String, "ü")
        XCTAssertEqual(backups().count, 1)
    }

    func testInstallKeepsExistingStatusLine() throws {
        try writeSettings(["statusLine": mine])
        let log = try install()
        XCTAssertTrue(log.contains { $0.hasPrefix("Kept your status line") }, "\(log)")
        let saved = loadJSONObject(paths.config)["original_status_line"] as? [String: Any]
        XCTAssertEqual(saved?["command"] as? String, "~/.claude/my-status.sh")
        XCTAssertEqual(statusLine()["command"] as? String, command)
        XCTAssertEqual(statusLine()["padding"] as? Int, 0)  // extra keys kept
    }

    func testNonObjectStatusLine() throws {
        try writeSettings(["statusLine": "echo hi"])
        XCTAssertTrue(try install().contains("Kept your status line: echo hi"))
        XCTAssertEqual(statusLine()["command"] as? String, command)
        _ = try uninstall()
        XCTAssertEqual(settings()["statusLine"] as? String, "echo hi")
    }

    func testReinstallChangesNothing() throws {
        try writeSettings(["statusLine": mine])
        _ = try install(1000)
        XCTAssertTrue(try install(1001).contains { $0.contains("already set") })
        XCTAssertEqual(backups().count, 1)
        let saved = loadJSONObject(paths.config)["original_status_line"] as? [String: Any]
        XCTAssertEqual(saved?["command"] as? String, "~/.claude/my-status.sh")  // still yours
    }

    func testReplacesPythonBridgeWithoutSavingIt() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "/x/claude-usage-bar/bridge/statusline.py"]])
        _ = try install()
        XCTAssertEqual(statusLine()["command"] as? String, command)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
    }

    func testUninstallRestoresOriginal() throws {
        try writeSettings(["statusLine": mine, "model": "opus"])
        _ = try install()
        XCTAssertTrue(try uninstall().contains { $0.hasPrefix("Restored your status line") })
        XCTAssertEqual(statusLine()["command"] as? String, "~/.claude/my-status.sh")
        XCTAssertEqual(settings()["model"] as? String, "opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
    }

    func testUninstallWithoutOriginalRemovesEntry() throws {
        try writeSettings(["model": "opus"])
        _ = try install()
        _ = try uninstall()
        XCTAssertNil(settings()["statusLine"])
        XCTAssertEqual(settings()["model"] as? String, "opus")
    }

    func testUninstallLeavesSomeoneElsesStatusLine() throws {
        try writeSettings(["statusLine": mine])
        XCTAssertTrue(try uninstall().contains { $0.contains("left it alone") })
        XCTAssertEqual(statusLine()["command"] as? String, "~/.claude/my-status.sh")
    }

    func testSymlinkedSettingsStaysASymlink() throws {
        let real = root.appendingPathComponent("dotfiles/settings.json")
        try writeJSONObject(["model": "opus"], to: real)
        try FileManager.default.createDirectory(
            at: paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.settings, withDestinationURL: real)
        _ = try install()
        let type = try FileManager.default.attributesOfItem(atPath: paths.settings.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertNotNil(loadJSONObject(real)["statusLine"])
    }

    func testInvalidJSONIsLeftUntouched() throws {
        try writeFile(paths.settings, "{not json")
        XCTAssertThrowsError(try install()) { error in
            XCTAssertTrue("\(error)".contains("isn't valid JSON"))
        }
        XCTAssertEqual(try String(contentsOf: paths.settings, encoding: .utf8), "{not json")
    }

    func testLoginItem() throws {
        try LoginItem.enable(appPath: "/Applications/ClaudeUsageBar.app", paths: paths)
        XCTAssertTrue(LoginItem.isEnabled(paths))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: LoginItem.plist(paths)), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["ProgramArguments"] as? [String],
                       ["/usr/bin/open", "-a", "/Applications/ClaudeUsageBar.app"])
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        LoginItem.disable(paths)
        XCTAssertFalse(LoginItem.isEnabled(paths))
    }
}
