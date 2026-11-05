import Foundation
import XCTest

/// Runs the real install.sh and uninstall.sh with a temporary HOME and
/// install folder, a fake app (its binary logs what it's asked to do), and
/// fake curl, open, pkill, defaults, sw_vers and uname first on PATH.
/// Nothing touches your real apps, settings or SwiftBar.
final class InstallScriptTests: XCTestCase {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var apps: URL { root.appendingPathComponent("Applications") }
    var bin: URL { root.appendingPathComponent("bin") }
    var log: URL { root.appendingPathComponent("calls.log") }
    var zip: URL { root.appendingPathComponent("ClaudeUsageBar.zip") }
    var defaultsFile: URL { root.appendingPathComponent("swiftbar-defaults") }
    var app: URL { apps.appendingPathComponent("ClaudeUsageBar.app") }

    // Each fake logs "name args..." to $FAKE_LOG.
    let fakes: [String: String] = [
        "uname": #"echo "${FAKE_UNAME:-Darwin}""#,
        "sw_vers": #"echo "${FAKE_MACOS:-15.1}""#,
        "pkill": "exit 1",
        "open": "exit 0",
        // curl -fsSL --retry 2 -o FILE URL: copy the test zip, or fail.
        "curl": """
        [ -n "$FAKE_CURL_FAIL" ] && exit 22
        while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp "$FAKE_ZIP" "$2"; exit 0; }; shift; done
        """,
        "defaults": #"[ "$1" = read ] && [ -f "$FAKE_DEFAULTS" ] && cat "$FAKE_DEFAULTS" || exit 1"#,
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("install-tests-\(UUID().uuidString)")
        for dir in [home, apps, bin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for (name, body) in fakes {
            try script(bin.appendingPathComponent(name), "echo \"\(name) $*\" >> \"$FAKE_LOG\"\n\(body)")
        }
        try makeZip(version: "new")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func script(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A zip holding a fake ClaudeUsageBar.app whose binary logs "app <version> args".
    func makeZip(version: String) throws {
        let build = root.appendingPathComponent("build-\(version)")
        let bundle = build.appendingPathComponent("ClaudeUsageBar.app")
        try script(bundle.appendingPathComponent("Contents/MacOS/ClaudeUsageBar"),
                   "echo \"app \(version) $*\" >> \"$FAKE_LOG\"")
        try? FileManager.default.removeItem(at: zip)
        _ = try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, zip.path], env: [:])
    }

    @discardableResult
    func run(_ exe: String, _ args: [String], env: [String: String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func runScript(_ name: String, _ extra: [String: String] = [:]) throws -> (status: Int32, out: String) {
        var env = [
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "CLAUDE_USAGE_BAR_APP_DIR": apps.path,
            "CLAUDE_USAGE_BAR_ZIP": zip.path,
            "FAKE_ZIP": zip.path,
            "FAKE_LOG": log.path,
            "FAKE_DEFAULTS": defaultsFile.path,
        ]
        env.merge(extra) { $1 }
        return try run("/bin/bash", [repo.appendingPathComponent(name).path], env: env)
    }

    func calls(_ name: String) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { $0.hasPrefix(name + " ") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    // MARK: install.sh

    func testInstallsFromLocalZip() throws {
        let r = try runScript("install.sh")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/ClaudeUsageBar").path))
        XCTAssertEqual(calls("app"), ["new setup"])
        XCTAssertEqual(calls("open"), [app.path])
        XCTAssertEqual(calls("curl"), [])
    }

    func testDownloadsWithCurl() throws {
        let url = "https://github.com/kemasaqar/claude-usage-bar/releases/latest/download/ClaudeUsageBar.zip"
        let r = try runScript("install.sh", ["CLAUDE_USAGE_BAR_ZIP": url])
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertEqual(calls("curl").count, 1)
        XCTAssertTrue(calls("curl")[0].hasSuffix(url))
        XCTAssertEqual(calls("app"), ["new setup"])
    }

    func testDefaultDownloadsLatestRelease() throws {
        // Unset (or empty) falls back to the latest release URL.
        let r = try runScript("install.sh", ["CLAUDE_USAGE_BAR_ZIP": ""])
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(calls("curl").first?.contains("/releases/latest/download/ClaudeUsageBar.zip") == true)
    }

    func testFailedDownloadChangesNothing() throws {
        let r = try runScript("install.sh", ["CLAUDE_USAGE_BAR_ZIP": "https://example.invalid/x.zip", "FAKE_CURL_FAIL": "1"])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.out.contains("Download failed"), r.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertEqual(calls("app"), [])
    }

    func testZipWithoutTheAppIsRejected() throws {
        try "not a zip".write(to: zip, atomically: true, encoding: .utf8)
        let r = try runScript("install.sh")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    func testReinstallReplacesOldCopy() throws {
        try makeZip(version: "old")
        XCTAssertEqual(try runScript("install.sh").status, 0)
        try makeZip(version: "new")
        let r = try runScript("install.sh")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertEqual(calls("app"), ["old setup", "new setup"])
        XCTAssertEqual(calls("pkill"), ["-x ClaudeUsageBar", "-x ClaudeUsageBar"])
    }

    func testRemovesOldSwiftBarPlugin() throws {
        let plugins = home.appendingPathComponent("Plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let link = plugins.appendingPathComponent("claude-usage.5m.py")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/somewhere/claude-usage.5m.py")
        let other = plugins.appendingPathComponent("weather.10m.sh")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        try plugins.path.write(to: defaultsFile, atomically: true, encoding: .utf8)
        let r = try runScript("install.sh")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))  // other plugins stay
        XCTAssertTrue(r.out.contains("Removed the old SwiftBar plugin"), r.out)
    }

    func testOldMacOSStopsEarly() throws {
        let r = try runScript("install.sh", ["FAKE_MACOS": "12.7"])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.out.contains("macOS 13 or newer"), r.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    func testNotMacOSStopsEarly() throws {
        let r = try runScript("install.sh", ["FAKE_UNAME": "Linux"])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.out.contains("only runs on macOS"), r.out)
    }

    // MARK: uninstall.sh

    func testUninstallUndoesSetupAndDeletesApp() throws {
        XCTAssertEqual(try runScript("install.sh").status, 0)
        let r = try runScript("uninstall.sh")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertEqual(calls("app"), ["new setup", "new uninstall"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    func testUninstallWithoutAppExplainsWhatToDo() throws {
        let r = try runScript("uninstall.sh")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("not found"), r.out)
    }
}
