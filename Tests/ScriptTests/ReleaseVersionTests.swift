import Foundation
import XCTest

/// scripts/release-version.sh: the version a merged pull request is
/// released as, from the last tag, its labels and the files it changed.
final class ReleaseVersionTests: XCTestCase {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/release-version.sh")

    let tags = ["v2.3.0", "v2.4.0", "v2.3.0-pr1", "not-a-version"]

    /// What the script prints (nil when it fails) and its reason on stderr.
    func version(labels: [String] = [], files: [String] = ["Sources/UsageCore/Alerts.swift"],
                 tags: [String]? = nil) throws -> (out: String?, reason: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "TAGS": (tags ?? self.tags).joined(separator: "\n"),
            "LABELS": labels.joined(separator: "\n"),
            "FILES": files.joined(separator: "\n"),
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let reason = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil, reason)
    }

    func testNoLabelIsAPatch() throws {
        XCTAssertEqual(try version().out, "v2.4.1")
        XCTAssertEqual(try version(labels: ["bug", "enhancement"]).out, "v2.4.1")
    }

    func testMinorAndMajorLabels() throws {
        XCTAssertEqual(try version(labels: ["minor"]).out, "v2.5.0")
        XCTAssertEqual(try version(labels: ["major"]).out, "v3.0.0")
        XCTAssertEqual(try version(labels: ["minor", "major"]).out, "v3.0.0")
    }

    func testNoReleaseLabelSkips() throws {
        let result = try version(labels: ["minor", "no release"])
        XCTAssertEqual(result.out, "")
        XCTAssertTrue(result.reason.contains("no release"), result.reason)
    }

    func testDocsOnlyIsNotReleased() throws {
        let docs = try version(files: ["README.md", "docs/notifications.png", "LICENSE", "CHANGES.md"])
        XCTAssertEqual(docs.out, "")
        XCTAssertTrue(docs.reason.contains("Only docs"), docs.reason)
        XCTAssertEqual(try version(files: ["README.md", "install.sh"]).out, "v2.4.1")
        // A Markdown file inside the sources is still a change to the app.
        XCTAssertEqual(try version(files: ["Sources/UsageCore/notes.md"]).out, "v2.4.1")
    }

    func testHighestVersionWinsNotTheLastListed() throws {
        XCTAssertEqual(try version(tags: ["v2.10.0", "v2.9.3"]).out, "v2.10.1")
        XCTAssertEqual(try version(labels: ["minor"], tags: ["v10.0.0", "v9.9.9"]).out, "v10.1.0")
    }

    func testFirstReleaseWithoutTags() throws {
        XCTAssertEqual(try version(tags: []).out, "v0.0.1")
    }

    func testNoFilesIsAnError() throws {
        XCTAssertNil(try version(files: []).out)
    }
}
