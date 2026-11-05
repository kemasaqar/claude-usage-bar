import Foundation

public struct RunResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

/// Runs a program, feeding `input` on stdin, and gives up after `timeout`.
/// On timeout it doesn't wait for the output pipes to close: a child the
/// program started could keep them open long after.
public func runProgram(
    _ executable: String, _ arguments: [String], cwd: URL? = nil, input: Data? = nil,
    environment: [String: String]? = nil, timeout: TimeInterval
) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    if let environment { process.environment = environment }

    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let inPipe = input.map { _ in Pipe() }
    process.standardInput = inPipe ?? FileHandle.nullDevice

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        let closed = DispatchSemaphore(value: 0)
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    let outData = Collector(), errData = Collector()
    for (pipe, collector) in [(out, outData), (err, errData)] {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.closed.signal()
            } else {
                collector.append(chunk)
            }
        }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    try process.run()
    if let inPipe, let input {
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
    } else {
        // Normally the pipes close right after exit; don't hang if a
        // leftover child still holds them.
        _ = outData.closed.wait(timeout: .now() + 1)
        _ = errData.closed.wait(timeout: .now() + 1)
    }
    return RunResult(
        status: timedOut ? -1 : process.terminationStatus,
        stdout: String(decoding: outData.value, as: UTF8.self),
        stderr: String(decoding: errData.value, as: UTF8.self),
        timedOut: timedOut
    )
}
