// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything testable: cache, merge rules, status line, auto-check,
        // settings setup, pace, and the menu's content.
        .target(name: "UsageCore"),
        // The menu bar app, plus the command-line modes Claude Code and the
        // installer call (statusline, probe, setup, uninstall).
        .executableTarget(name: "ClaudeUsageBar", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        // Runs install.sh / uninstall.sh against a fake app and fake commands.
        .testTarget(name: "ScriptTests"),
    ]
)
