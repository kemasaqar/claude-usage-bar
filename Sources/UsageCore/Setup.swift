import Foundation

/// Points Claude Code's statusLine at the app, or undoes that. A status
/// line you already had is kept: it's saved in the config file and the app
/// shows its output; uninstall puts it back. settings.json is backed up
/// before every change.
public enum SettingsSetup {
    /// Also matches the old Python bridge, so switching replaces it.
    public static func isOurs(_ statusLine: Any?) -> Bool {
        guard let command = (statusLine as? [String: Any])?["command"] as? String else { return false }
        return command.contains("ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar")
            || command.hasSuffix("/bridge/statusline.py")
    }

    /// The statusLine command for an app at `executable`, quoted for the shell.
    public static func command(executable: String) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' statusline"
    }

    static func describe(_ statusLine: Any) -> String {
        if let dict = statusLine as? [String: Any], let command = dict["command"] { return "\(command)" }
        return "\(statusLine)"
    }

    /// Returns what it did, one line per step.
    public static func install(command: String, paths: UsagePaths, now: Date = Date()) throws -> [String] {
        var log: [String] = []
        var settings = try loadSettings(paths.settings)
        let current = settings["statusLine"]
        if let current, !isEmpty(current), !isOurs(current) {
            try writeJSONObject(["original_status_line": current], to: paths.config)
            log.append("Kept your status line: \(describe(current))")
            log.append("  It still shows in the terminal; the app runs it for you.")
        }
        // Keep extra keys such as "padding" from the existing entry.
        var wanted = current as? [String: Any] ?? [:]
        wanted["type"] = "command"
        wanted["command"] = command
        if let current = current as? [String: Any], NSDictionary(dictionary: current).isEqual(to: wanted) {
            log.append("statusLine already set in \(paths.settings.path)")
            return log
        }
        settings["statusLine"] = wanted
        log += try saveSettings(settings, to: paths.settings, now: now)
        log.append("Set statusLine in \(paths.settings.path)")
        return log
    }

    public static func uninstall(paths: UsagePaths, now: Date = Date()) throws -> [String] {
        var log: [String] = []
        var settings = try loadSettings(paths.settings)
        let original = loadJSONObject(paths.config)["original_status_line"]
        if !isOurs(settings["statusLine"]) {
            log.append("statusLine doesn't point at this app; left it alone")
        } else {
            if let original, !isEmpty(original) {
                settings["statusLine"] = original
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            log += try saveSettings(settings, to: paths.settings, now: now)
            if let original, !isEmpty(original) {
                log.append("Restored your status line: \(describe(original))")
            } else {
                log.append("Removed statusLine from \(paths.settings.path)")
            }
        }
        try? FileManager.default.removeItem(at: paths.config)
        return log
    }

    static func isEmpty(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let s = value as? String { return s.isEmpty }
        if let d = value as? [String: Any] { return d.isEmpty }
        return false
    }

    static func loadSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw CheckError("\(url.path) isn't valid JSON; fix it and re-run.")
        }
        guard let dict = object as? [String: Any] else {
            throw CheckError("\(url.path) doesn't contain a JSON object.")
        }
        return dict
    }

    /// Backs up, then writes atomically. Writes through a symlink (dotfiles
    /// setups) instead of replacing it, and keeps the file's permissions.
    static func saveSettings(_ settings: [String: Any], to url: URL, now: Date) throws -> [String] {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var log: [String] = []
        var permissions: Any?
        if fm.fileExists(atPath: target.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.bak-\(Int(now.timeIntervalSince1970))")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: target, to: backup)
            permissions = try fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            log.append("Backed up \(url.path) -> \(backup.lastPathComponent)")
        }
        try writeJSONObject(settings, to: target)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return log
    }
}

/// Starts the app at login with a LaunchAgent. Works for an app without a
/// Developer ID, unlike the system login-item API.
public enum LoginItem {
    public static let label = "com.kemasaqar.claude-usage-bar"

    public static func plist(_ paths: UsagePaths) -> URL {
        paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func isEnabled(_ paths: UsagePaths) -> Bool {
        FileManager.default.fileExists(atPath: plist(paths).path)
    }

    public static func enable(appPath: String, paths: UsagePaths) throws {
        let url = plist(paths)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
        ] as [String: Any], format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    public static func disable(_ paths: UsagePaths) {
        try? FileManager.default.removeItem(at: plist(paths))
    }
}
