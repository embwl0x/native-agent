import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Test doubles

actor _MockHTTPClient: HTTPClient {
    struct Call: Equatable {
        let urlString: String
        let body: Data
    }
    private(set) var calls: [Call] = []
    private var responses: [(status: Int, data: Data)] = []
    private var failure: Error? = nil

    func queue(status: Int, data: Data) {
        responses.append((status, data))
    }
    func queueJSON(status: Int, _ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        responses.append((status, data))
    }
    func queueFailure(_ err: Error) { failure = err }

    func postJSON(url: URL, body: Data, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        calls.append(.init(urlString: url.absoluteString, body: body))
        if let failure { throw failure }
        if responses.isEmpty {
            return (200, Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}

actor _MockNotificationCenter: NotificationCenterAdapter {
    struct Call: Equatable {
        let title: String
        let message: String
        let soundName: String?
    }
    private(set) var calls: [Call] = []
    private var shouldThrow: Error? = nil
    private var receipt = NotificationPostReceipt(authorization: .adapterManaged)
    func setShouldThrow(_ err: Error?) { shouldThrow = err }
    func setReceipt(_ receipt: NotificationPostReceipt) { self.receipt = receipt }
    func postNotification(title: String, message: String, soundName: String?) async throws {
        calls.append(.init(title: title, message: message, soundName: soundName))
        if let shouldThrow { throw shouldThrow }
    }
    func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt {
        try await postNotification(title: title, message: message, soundName: soundName)
        return receipt
    }
}

final class _MockAppleScriptAdapter: AppleScriptAdapter, @unchecked Sendable {
    var lastScript: String = ""
    var result: String = "hello"
    var shouldThrow: Error? = nil
    func run(script: String) throws -> String {
        lastScript = script
        if let shouldThrow { throw shouldThrow }
        return result
    }
}

actor _MockProcessAdapter: ProcessAdapter {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeoutSeconds: Int
    }
    private(set) var calls: [Call] = []
    private var responses: [ProcessRunResult] = []
    func queue(_ r: ProcessRunResult) { responses.append(r) }
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        calls.append(.init(executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds))
        if responses.isEmpty {
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        }
        return responses.removeFirst()
    }
}

actor _MockAppControlAdapter: AppControlAdapter, AppStateVerificationAdapter {
    enum Call: Equatable {
        case focus(String)
        case quit(String)
    }
    private(set) var calls: [Call] = []
    var focusResult = AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: true,
        terminated: false
    )
    var quitResult = AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        terminated: true
    )
    var shouldThrow: Error? = nil
    private var frontmost = true

    func configureFocus(result: AppControlRunResult, frontmost: Bool) {
        focusResult = result
        self.frontmost = frontmost
    }

    func focusApp(named name: String) async throws -> AppControlRunResult {
        calls.append(.focus(name))
        if let shouldThrow { throw shouldThrow }
        return focusResult
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        calls.append(.quit(name))
        if let shouldThrow { throw shouldThrow }
        return quitResult
    }

    func isFrontmostApplication(matching name: String) async -> Bool {
        frontmost && name == focusResult.requestedName
    }

    func isApplicationRunning(matching name: String) async -> Bool {
        name != quitResult.requestedName
    }
}

// _MockFileManagerAdapter: simple in-memory FS. Class so it can be mutated
// in-place behind the protocol; @unchecked Sendable because tests run
// serially.
final class _MockFileManagerAdapter: FileManagerAdapter, FileStateVerificationAdapter, @unchecked Sendable {
    var files: [String: Data] = [:]
    var directories: [String: [String]] = [:]
    var trashed: [String] = []
    var throwOnRead: Error? = nil
    var throwOnWrite: Error? = nil
    var throwOnMove: Error? = nil
    var throwOnTrash: Error? = nil

    func readData(at url: URL, maxBytes: Int) throws -> Data {
        if let e = throwOnRead { throw e }
        let data = files[url.path] ?? Data()
        if data.count > maxBytes { return data.prefix(maxBytes) }
        return data
    }
    func writeData(_ data: Data, to url: URL, append: Bool) throws {
        if let e = throwOnWrite { throw e }
        if append, let existing = files[url.path] {
            files[url.path] = existing + data
        } else {
            files[url.path] = data
        }
    }
    func listDirectory(at url: URL) throws -> [URL] {
        let names = directories[url.path] ?? []
        return names.map { url.appendingPathComponent($0) }
    }
    func moveItem(from src: URL, to dst: URL) throws {
        if let e = throwOnMove { throw e }
        if let data = files.removeValue(forKey: src.path) {
            files[dst.path] = data
        } else {
            throw NSError(domain: "mock", code: 2, userInfo: [NSLocalizedDescriptionKey: "src missing"])
        }
    }
    func trashItem(at url: URL) throws {
        if let e = throwOnTrash { throw e }
        if files[url.path] != nil {
            files.removeValue(forKey: url.path)
            trashed.append(url.path)
        } else {
            throw NSError(domain: "mock", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing"])
        }
    }
    func itemExists(at url: URL) -> Bool {
        files[url.path] != nil || directories[url.path] != nil
    }
}

/// Test policy provider: returns a fixed policy (or nil to simulate
/// unresolved policy → fail-open).
struct _StubPolicyProvider: MacControlPolicyProvider {
    let policy: MacControlPolicy?
    func currentPolicy() async -> MacControlPolicy? { policy }
}

/// A permissive base policy: master on, remote-ios on, every category on,
/// no trust policy (file policy short-circuits to allow). Tests flip
/// individual fields off.
func _permissiveMacPolicy() -> MacControlPolicy {
    MacControlPolicy(
        enabled: true,
        remoteFromIOSAllowed: true,
        requireAppBridgeForTCC: false,
        categoryAllowed: [
            "applescript_allowed": true, "jxa_allowed": true,
            "shortcuts_allowed": true, "accessibility_allowed": true,
            "system_control_allowed": true, "file_ops_allowed": true,
            "shell_allowed": true, "notifications_allowed": true,
            "spotlight_allowed": true,
        ],
        trustPolicy: nil,
        workspaceRoots: []
    )
}

final class _InertEventSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _mouse = 0
    private var _keys = 0
    var isAvailable: Bool { true }
    var mouseCount: Int { lock.lock(); defer { lock.unlock() }; return _mouse }
    var keyCount: Int { lock.lock(); defer { lock.unlock() }; return _keys }
    func post(key: MacKeyEvent) { lock.lock(); _keys += 1; lock.unlock() }
    func post(mouse: MacMouseEvent) { lock.lock(); _mouse += 1; lock.unlock() }
    func post(scroll: MacScrollEvent) { lock.lock(); _mouse += 1; lock.unlock() }
}
