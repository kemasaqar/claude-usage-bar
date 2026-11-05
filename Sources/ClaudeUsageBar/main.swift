import AppKit
import UsageCore

// One binary, several jobs:
//
//   ClaudeUsageBar                      the menu bar app
//   ClaudeUsageBar statusline           Claude Code's statusLine command
//   ClaudeUsageBar probe --auto|--now|--pause|--resume
//   ClaudeUsageBar setup                point statusLine here, start at login
//   ClaudeUsageBar uninstall            undo setup
//   ClaudeUsageBar render-preview OUT.png [heading-over|on-track|now] [text size %]

let paths = UsagePaths.fromEnvironment()
let arguments = Array(CommandLine.arguments.dropFirst())
let now = Date().timeIntervalSince1970

/// Path of the running executable, inside the .app bundle when installed.
let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

switch arguments.first {
case "statusline":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    print(StatusLine.handle(input: input, paths: paths, now: now))

case "probe":
    switch arguments.dropFirst().first {
    case "--auto":
        if let outcome = AutoCheck.auto(now: now, paths: paths) {
            print(outcome)
        } else {
            print("skipped:", AutoCheck.shouldCheck(now: now, paths: paths).1)
        }
    case "--now":
        let outcome = AutoCheck.check(now: now, paths: paths)
        print(outcome)
        if case .failed = outcome { exit(1) }
    case "--pause":
        do { try AutoCheck.pause(paths) } catch { fail("\(error)") }
        print("auto-check paused")
    case "--resume":
        AutoCheck.resume(paths)
        print("auto-check resumed")
    default:
        fail("usage: ClaudeUsageBar probe --auto|--now|--pause|--resume")
    }

case "setup":
    do {
        let command = SettingsSetup.command(executable: executablePath)
        try SettingsSetup.install(command: command, paths: paths).forEach { print($0) }
        // Bundle path: .../ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar
        let app = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" {
            try LoginItem.enable(appPath: app.path, paths: paths)
            print("Starts at login (\(LoginItem.plist(paths).path))")
        }
    } catch {
        fail("\(error)")
    }

case "uninstall":
    do {
        try SettingsSetup.uninstall(paths: paths).forEach { print($0) }
        LoginItem.disable(paths)
        print("Removed the login item")
    } catch {
        fail("\(error)")
    }

case "render-preview":
    guard arguments.count >= 2 else {
        fail("usage: ClaudeUsageBar render-preview OUT.png [heading-over|on-track|now]")
    }
    let scenario = arguments.count >= 3 ? arguments[2] : "now"
    let percent = arguments.count >= 4 ? Int(arguments[3]) : nil
    do {
        try Preview.render(scenario: scenario, to: URL(fileURLWithPath: arguments[1]), paths: paths,
                           scalePercent: TextScale.sanitize(percent))
    } catch {
        fail("\(error)")
    }

default:
    // Finder and `open` may pass their own -flags; anything else is the app.
    let app = NSApplication.shared
    let delegate = AppDelegate(paths: paths)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
