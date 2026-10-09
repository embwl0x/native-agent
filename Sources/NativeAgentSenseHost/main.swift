import Darwin
import Foundation
import Senses

let io = PlugIO()
signal(SIGPIPE, SIG_IGN)
var runtime: JavaScriptSenseRuntime?

private final class SwiftStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
}

/// Swift senses are standalone plug programs. They receive the same initial
/// run and subsequent replies; the app applies the same validation and gates.
@MainActor func runSwift(_ message: [String: Any]) throws -> Never {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") else {
        throw SenseFailure(code: "unsupported", message: "Swift senses require /usr/bin/swift.")
    }
    guard runtime == nil, let rawRecord = message["sense"] as? [String: Any],
          let request = message["request"] as? [String: Any], let kind = request["type"] as? String,
          ["read", "act", "watch", "event"].contains(kind), message["id"] is Int,
          let source = message["source"] as? String, source.utf8.count <= 512 * 1024,
          let index = CommandLine.arguments.firstIndex(of: "--scratch"),
          CommandLine.arguments.indices.contains(index + 1) else {
        throw SenseFailure(code: "bad_input", message: "Swift sense requires source and --scratch <private folder>.")
    }
    let record = try JSONDecoder().decode(SenseRecord.self, from: JSONSerialization.data(withJSONObject: rawRecord))
    guard record.language == .swift, kind != "watch" || record.mode == .live,
          kind != "act" || (request["verb"] is String && request["address"] is String) else {
        throw SenseFailure(code: "bad_input", message: "Swift sense request does not match its record.")
    }
    let scratchArgument = CommandLine.arguments[index + 1]
    let scratch = URL(fileURLWithPath: scratchArgument, isDirectory: true)
    guard scratchArgument.hasPrefix("/"), scratch.path != "/" else {
        throw SenseFailure(code: "bad_input", message: "Swift scratch must be an absolute private folder.")
    }
    let entry = scratch.appendingPathComponent("sense-\(getpid()).swift")
    let descriptor = open(entry.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
        throw SenseFailure(code: "source_unavailable", message: "Could not stage Swift sense source.")
    }
    defer { try? FileManager.default.removeItem(at: entry) }
    let staged = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try staged.write(contentsOf: Data(source.utf8))
    try staged.close()
    let child = Process()
    let input = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    child.arguments = ["-module-cache-path", scratch.appendingPathComponent("module-cache").path, entry.path]
    child.currentDirectoryURL = scratch
    child.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.path,
                         "CLANG_MODULE_CACHE_PATH": scratch.appendingPathComponent("module-cache").path]
    child.standardInput = input
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    let runID = message["id"] as? Int
    let stopState = SwiftStopState()
    child.terminationHandler = { process in
        try? FileManager.default.removeItem(at: entry)
        if process.terminationStatus != 0, !stopState.isStopped {
            PlugIO().fail(id: runID, SenseFailure(code: "crashed", message: "Swift sense exited with status \(process.terminationStatus)."))
        }
        exit(process.terminationStatus == 0 || stopState.isStopped ? 0 : 1)
    }
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    func forward(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    var run = message
    run.removeValue(forKey: "source")
    try forward(run)
    while let message = try io.receive() {
        if message["type"] as? String == "stop" {
            stopState.stop()
            child.terminate()
            // Keep the helper alive until its child is reaped. P2's outer
            // deadline kills the entire group if the child ignores SIGTERM.
            child.waitUntilExit()
            exit(0)
        }
        try forward(message)
    }
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    exit(child.terminationStatus == 0 ? 0 : 1)
}

while true {
    var id: Int?
    do {
        guard let message = try io.receive() else { break }
        id = message["id"] as? Int
        switch message["type"] as? String {
        case "stop": exit(0)
        case "run":
            if let record = message["sense"] as? [String: Any], record["language"] as? String == "swift" {
                try runSwift(message)
            }
            fallthrough
        case "changed":
            if runtime == nil {
                let installedSDK = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Resources/Senses/sense.js")
                #if SWIFT_PACKAGE
                let sdk = FileManager.default.isReadableFile(atPath: installedSDK.path) ? installedSDK
                    : Bundle.module.bundleURL.appendingPathComponent("Senses/sense.js")
                #else
                let sdk = installedSDK
                #endif
                let shim = try String(contentsOf: sdk, encoding: .utf8)
                runtime = JavaScriptSenseRuntime(io: io, shim: shim)
            }
            try runtime?.run(message)
        default: throw SenseFailure(code: "bad_input", message: "Expected run, changed or stop on the sense plug.")
        }
    } catch {
        io.fail(id: id, (error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription))
        // Failed JSC contexts and interrupted plug exchanges cannot be reused.
        exit(1)
    }
}
