import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore
import TrustCenter

enum ChromeControlRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable
    case disconnected
    case invalidResponse
    case requestTimedOut
    case socketFailure(Int32)
    case socketPathTooLong
    case relayUnavailable
    case unsafeSocketPath

    var errorDescription: String? {
        switch self {
        case .disabled: return "Chrome control is off in Trust Center."
        case .unavailable: return "Chrome control authority could not be verified."
        case .disconnected: return "Chrome is not connected to NativeAgent."
        case .invalidResponse: return "Chrome returned an invalid control response."
        case .requestTimedOut: return "Chrome did not answer before the control deadline."
        case .socketFailure(let code): return "Chrome control socket failed (errno \(code))."
        case .socketPathTooLong: return "Chrome control socket path is too long."
        case .relayUnavailable: return "The bundled NativeAgent Chrome relay is unavailable."
        case .unsafeSocketPath: return "Chrome control refused to replace a non-socket filesystem entry."
        }
    }
}

enum ChromeControlEffect: String, Sendable, CaseIterable {
    case acquire = "lease.acquire"
    case navigate
    case snapshot = "page.snapshot.read"
    case click = "page.element.click"
    case fill = "page.element.fill"
    case type = "page.element.type"
    case select = "page.element.select"
    case keypress = "page.element.keypress"
    case setChecked = "page.element.set_checked"
    case doubleClick = "page.element.double_click"
    case wait = "page.wait"
    case scroll = "page.scroll"
    case release = "lease.release"

    var requiresEffectTimeAuthorization: Bool {
        switch self {
        case .acquire, .navigate, .snapshot, .click, .fill, .type, .select,
             .keypress, .setChecked, .doubleClick, .wait, .scroll: true
        case .release: false
        }
    }
}

private final class ChromeSocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    func fileHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

actor ChromeControlChannel {
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    private let socket: ChromeSocketHandle
    private let framer = NativeMessagingFramer()
    private var readTask: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var activeLeaseIDs: Set<String> = []
    private var closed = false

    init(descriptor: Int32) {
        socket = ChromeSocketHandle(descriptor: descriptor)
    }

    func start() {
        guard readTask == nil, let handle = socket.fileHandle() else { return }
        let framer = self.framer
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                while let data = try framer.readMessage(from: handle) {
                    try framer.validateJSONObject(data)
                    await self?.receive(data)
                }
                await self?.connectionEnded(error: ChromeControlRuntimeError.disconnected)
            } catch {
                await self?.connectionEnded(error: error)
            }
        }
    }

    func request(action: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        guard !closed, let handle = socket.fileHandle() else {
            throw ChromeControlRuntimeError.disconnected
        }
        let id = UUID().uuidString.lowercased()
        let envelope = JSONValue.object([
            "version": .int(1),
            "type": .string("request"),
            "id": .string(id),
            "action": .string(action.rawValue),
            "payload": .object(payload),
        ])
        let data = try envelope.serializedData(pretty: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.timeoutRequest(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout)
                do {
                    try framer.writeMessage(data, to: handle)
                } catch {
                    if let row = pending.removeValue(forKey: id) {
                        row.timeout.cancel()
                        row.continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func shutdown(releaseLeases: Bool, error: Error = ChromeControlRuntimeError.disabled) {
        guard !closed else { return }
        if releaseLeases, let handle = socket.fileHandle() {
            for leaseID in activeLeaseIDs.sorted() {
                let envelope = JSONValue.object([
                    "version": .int(1),
                    "type": .string("request"),
                    "id": .string("shutdown-\(UUID().uuidString.lowercased())"),
                    "action": .string(ChromeControlEffect.release.rawValue),
                    "payload": .object([
                        "leaseId": .string(leaseID),
                        "closeCreatedTab": .bool(false),
                    ]),
                ])
                if let data = try? envelope.serializedData(pretty: false) {
                    try? framer.writeMessage(data, to: handle)
                }
            }
        }
        closed = true
        activeLeaseIDs.removeAll()
        socket.close()
        readTask?.cancel()
        readTask = nil
        failPending(error)
    }

    func activeLeaseCount() -> Int { activeLeaseIDs.count }

    private func receive(_ data: Data) {
        guard let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              case .string(let type)? = object["type"] else {
            connectionEnded(error: ChromeControlRuntimeError.invalidResponse)
            return
        }
        if type == "event" {
            applyEvent(object)
            return
        }
        guard type == "response", case .string(let id)? = object["id"],
              let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        if case .bool(true)? = object["ok"] {
            if case .string(let action)? = object["action"],
               action == ChromeControlEffect.acquire.rawValue,
               case .object(let result)? = object["result"],
               case .string(let leaseID)? = result["leaseId"] {
                activeLeaseIDs.insert(leaseID)
            } else if case .string(let action)? = object["action"],
                      action == ChromeControlEffect.release.rawValue,
                      case .object(let result)? = object["result"],
                      case .string(let leaseID)? = result["leaseId"] {
                activeLeaseIDs.remove(leaseID)
            }
            row.continuation.resume(returning: value)
        } else {
            let message: String
            if case .object(let errorObject)? = object["error"],
               case .string(let detail)? = errorObject["message"] {
                message = detail
            } else {
                message = "Chrome control action failed."
            }
            row.continuation.resume(throwing: NSError(
                domain: "NativeAgentChromeControl",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    private func applyEvent(_ object: [String: JSONValue]) {
        guard case .string(let event)? = object["event"],
              case .object(let payload)? = object["payload"],
              case .string(let leaseID)? = payload["leaseId"] else { return }
        if event == "lease.granted" {
            activeLeaseIDs.insert(leaseID)
        } else if event == "lease.yielded" || event == "lease.released" {
            activeLeaseIDs.remove(leaseID)
        }
    }

    private func timeoutRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        row.continuation.resume(throwing: ChromeControlRuntimeError.requestTimedOut)
    }

    private func cancelRequest(_ id: String) {
        guard let row = pending.removeValue(forKey: id) else { return }
        row.timeout.cancel()
        row.continuation.resume(throwing: CancellationError())
    }

    private func connectionEnded(error: Error) {
        guard !closed else { return }
        closed = true
        activeLeaseIDs.removeAll()
        socket.close()
        readTask?.cancel()
        readTask = nil
        failPending(error)
    }

    private func failPending(_ error: Error) {
        let rows = pending.values
        pending.removeAll()
        for row in rows {
            row.timeout.cancel()
            row.continuation.resume(throwing: error)
        }
    }
}

actor ChromeControlRuntime {
    static let shared = ChromeControlRuntime()

    typealias Authority = @Sendable () async -> Bool

    private let authority: Authority
    private let socketPath: String
    private let manageNativeHostRegistration: Bool
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var channel: ChromeControlChannel?

    init(
        socketPath: String = ChromeControlRuntime.defaultSocketPath(),
        manageNativeHostRegistration: Bool = true,
        authority: @escaping Authority = {
            await SwiftNativeTrustCenter(dataRoot: NativeAgentPaths.dataRoot)
                .chromeControlEnabledChecked()
        }
    ) {
        self.socketPath = socketPath
        self.manageNativeHostRegistration = manageNativeHostRegistration
        self.authority = authority
    }

    func reconcilePolicy() async {
        guard await authority() else {
            await stopLocked(releaseLeases: true)
            if manageNativeHostRegistration { try? ChromeNativeHostRegistration.uninstall() }
            return
        }
        do {
            try startListenerIfNeeded()
            if manageNativeHostRegistration { try ChromeNativeHostRegistration.install() }
        } catch {
            await stopLocked(releaseLeases: false)
        }
    }

    func perform(_ effect: ChromeControlEffect, payload: [String: JSONValue]) async throws -> JSONValue {
        if effect.requiresEffectTimeAuthorization {
            guard await authority() else {
                await stopLocked(releaseLeases: true)
                throw ChromeControlRuntimeError.disabled
            }
        }
        guard let channel else { throw ChromeControlRuntimeError.disconnected }
        return try await channel.request(action: effect, payload: payload)
    }

    func stop() async {
        await stopLocked(releaseLeases: true)
    }

    func installAcceptedDescriptorForTesting(_ descriptor: Int32) async {
        await installAcceptedDescriptor(descriptor)
    }

    private func startListenerIfNeeded() throws {
        guard listenerDescriptor < 0 else { return }
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        guard Array(socketPath.utf8CString).count <= MemoryLayout<sockaddr_un>.size - 2 else {
            throw ChromeControlRuntimeError.socketPathTooLong
        }
        try unlinkSocketIfPresent(path: socketPath)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
        do {
            try bindUnixSocket(descriptor: descriptor, path: socketPath)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw ChromeControlRuntimeError.socketFailure(errno)
            }
            chmod(socketPath, 0o600)
        } catch {
            Darwin.close(descriptor)
            try? unlinkSocketIfPresent(path: socketPath)
            throw error
        }
        listenerDescriptor = descriptor
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 { break }
                await self?.installAcceptedDescriptor(accepted)
            }
        }
    }

    private func installAcceptedDescriptor(_ descriptor: Int32) async {
        guard await authority(), listenerDescriptor >= 0 || !manageNativeHostRegistration else {
            Darwin.close(descriptor)
            return
        }
        if let channel { await channel.shutdown(releaseLeases: true) }
        let next = ChromeControlChannel(descriptor: descriptor)
        channel = next
        await next.start()
    }

    private func stopLocked(releaseLeases: Bool) async {
        let existing = channel
        channel = nil
        if let existing {
            await existing.shutdown(releaseLeases: releaseLeases)
        }
        acceptTask?.cancel()
        acceptTask = nil
        if listenerDescriptor >= 0 {
            _ = Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }
        try? unlinkSocketIfPresent(path: socketPath)
    }

    static func defaultSocketPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NativeAgent", isDirectory: true)
            .appendingPathComponent("chrome-control.sock")
            .path
    }
}

private func bindUnixSocket(descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { pointer in
            for (index, byte) in pathBytes.enumerated() { pointer[index] = byte }
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}

private func unlinkSocketIfPresent(path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT { return }
        throw ChromeControlRuntimeError.socketFailure(errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw ChromeControlRuntimeError.unsafeSocketPath
    }
    guard unlink(path) == 0 else { throw ChromeControlRuntimeError.socketFailure(errno) }
}

enum ChromeNativeHostRegistration {
    static let hostID = "com.nativeagent.chrome"
    static let extensionID = "egdbijiogeeggnmjheomgnnkhmlepfcn"

    static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        relayURL: URL? = nil
    ) throws {
        let relay = relayURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/NativeAgentChromeRelay")
        guard relay.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: relay.path) else {
            throw ChromeControlRuntimeError.relayUnavailable
        }
        let directory = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": hostID,
            "description": "NativeAgent Chrome transport relay",
            "path": relay.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let destination = directory.appendingPathComponent("\(hostID).json")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let destination = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostID).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }
}
