import AppKit
import Darwin
import Foundation
import ProviderRouting

struct AppCodexDeviceLoginPlatform: CodexDeviceLoginPlatformPort {
    func makeProcess(executable: URL, arguments: [String], environment: [String: String]) -> any CodexDeviceLoginProcessPort {
        AppCodexDeviceLoginProcess(executable: executable, arguments: arguments, environment: environment)
    }

    @MainActor
    func openBrowser(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

private final class AppCodexDeviceLoginProcess: CodexDeviceLoginProcessPort, @unchecked Sendable {
    private let process: Process
    private let outputHandle: FileHandle

    init(executable: URL, arguments: [String], environment: [String: String]) {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.environment = environment
        proc.standardOutput = pipe
        proc.standardError = pipe
        process = proc
        outputHandle = pipe.fileHandleForReading
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    var processIdentifier: Int32 { process.processIdentifier }

    func run() throws { try process.run() }
    func terminate() { process.terminate() }
    func kill() { Darwin.kill(process.processIdentifier, SIGKILL) }

    func onOutput(_ receive: @escaping @Sendable (String) -> Void) {
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            receive(text)
        }
    }

    func onTermination(_ receive: @escaping @Sendable (Int32) -> Void) {
        process.terminationHandler = { receive($0.terminationStatus) }
    }

    func clearOutput() {
        outputHandle.readabilityHandler = nil
        try? outputHandle.close()
    }
}
