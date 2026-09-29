import Foundation

public protocol CodexDeviceLoginPlatformPort: Sendable {
    func makeProcess(executable: URL, arguments: [String], environment: [String: String]) -> any CodexDeviceLoginProcessPort
    @MainActor func openBrowser(_ url: URL) -> Bool
}

/// A process handle; login state, parsing and cancellation timing stay in Core.
public protocol CodexDeviceLoginProcessPort: Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    var processIdentifier: Int32 { get }
    func run() throws
    func terminate()
    func kill()
    func onOutput(_ receive: @escaping @Sendable (String) -> Void)
    func onTermination(_ receive: @escaping @Sendable (Int32) -> Void)
    func clearOutput()
}
