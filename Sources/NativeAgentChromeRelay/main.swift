import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore

// Blueprint: | `main.swift` | Chrome relay executable: authenticated browser/app handshake and opaque bounded native-message forwarding over the private socket |

private enum RelayError: Error, LocalizedError {
    case socketPathMustBeAbsolute
    case socketPathTooLong
    case socketCreation(Int32)
    case socketConnection(Int32)
    case duplicateDescriptor(Int32)
    case handshakeRefused(String)
    case greetingWrite(String)
    case browserSignature(ChromeHostIdentity.SigningFailure)
    case originRefused
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .socketPathMustBeAbsolute:
            return "NativeAgent Chrome socket path must be absolute."
        case .socketPathTooLong:
            return "NativeAgent Chrome socket path exceeds the Unix-socket limit."
        case let .socketCreation(code):
            return "Could not create NativeAgent Chrome socket (errno \(code))."
        case let .socketConnection(code):
            return "Could not connect to NativeAgent.app Chrome socket (errno \(code))."
        case let .duplicateDescriptor(code):
            return "Could not duplicate NativeAgent Chrome socket (errno \(code))."
        case .handshakeRefused(let reason):
            return "NativeAgent.app did not confirm this relay's greeting: \(reason)"
        case .greetingWrite(let reason): return "Relay greeting socket write failed: \(reason)"
        case .browserSignature(let failure): return failure.localizedDescription
        case .originRefused: return "argv does not carry the registered extension origin."
        case .missingCredential: return "The app listener credential is missing or unreadable."
        }
    }

    var check: String {
        switch self {
        case .browserSignature(let failure): return failure.check
        case .originRefused: return "registered extension origin"
        case .missingCredential: return "app listener credential"
        case .handshakeRefused: return "app hello acknowledgement"
        case .greetingWrite: return "relay greeting socket write"
        case .socketPathMustBeAbsolute, .socketPathTooLong: return "socket path"
        case .socketCreation: return "socket creation"
        case .socketConnection: return "socket connection"
        case .duplicateDescriptor: return "socket descriptor duplication"
        }
    }
}

private final class RelayEndpoint: @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }
}

private final class RelayCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: Error?
    let semaphore = DispatchSemaphore(value: 0)

    func finish(_ error: Error?) {
        lock.lock()
        if firstError == nil, let error {
            firstError = error
        }
        lock.unlock()
        semaphore.signal()
    }

    func error() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return firstError
    }
}

private func diagnostic(_ message: String) {
    let line = "[NativeAgentChromeRelay] \(message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

private func defaultSocketPath() -> String {
    InstallPaths.current.chromeSocket.path
}

/// The app's per-launch 0600 secret authenticates the relay's first frame.
private func handshakeToken(socketPath: String) -> String? {
    guard let raw = try? String(
        contentsOfFile: ChromeHostIdentity.tokenPath(forSocketPath: socketPath),
        encoding: .utf8
    ) else { return nil }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

private func handshakeFrame(
    token: String,
    parentEvidence: ChromeHostIdentity.ParentEvidence
) throws -> Data {
    // Launch-time proof remains available after the browser exits.
    var object: [String: Any] = ["version": 1, "type": "hello", "token": token]
    for (key, value) in parentEvidence.helloFields { object[key] = value }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The app's acknowledgement identifies the listener that accepted this greeting.
private func readHelloAck(descriptor: Int32) throws -> String {
    let frame: Data
    do {
        guard let received = try NativeMessagingFramer().readMessage(fromSocket: descriptor, timeout: 5) else {
            throw RelayError.handshakeRefused("the app sent no acknowledgement.")
        }
        frame = received
    } catch let error as RelayError { throw error }
    catch { throw RelayError.handshakeRefused("the app acknowledgement could not be read: \(error.localizedDescription)") }
    let object: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            throw RelayError.handshakeRefused("the app acknowledgement is not a JSON object.")
        }
        object = parsed
    } catch let error as RelayError { throw error }
    catch { throw RelayError.handshakeRefused("the app acknowledgement is not valid JSON: \(error.localizedDescription)") }
    guard object["version"] as? Int == 1,
          object["type"] as? String == "hello_ack",
          let generation = object["generation"] as? String, !generation.isEmpty
    else { throw RelayError.handshakeRefused("the app acknowledgement has an invalid version, type or listener generation.") }
    return generation
}

/// Dial the app and complete the greeting. A refused connection is retried ONCE
/// and only when the secret on disk has changed since we read it — that is the
/// signal that the app relaunched under us, and the new listener is reachable
/// at the same path. Any other refusal is real and is reported.
private func connectAndGreet(
    socketPath: String,
    parentEvidence: ChromeHostIdentity.ParentEvidence
) throws -> Int32 {
    var attempt = 0
    while true {
        attempt += 1
        // Read the secret BEFORE dialing. The app writes the token and only
        // then binds the socket, so the token on disk when we dial belongs to
        // the listener we are about to reach. Reading it after connecting let
        // an overlapping app launch hand us its successor's secret, which the
        // listener we were actually talking to had never minted.
        let token = handshakeToken(socketPath: socketPath)
        let descriptor = try connectUnixSocket(path: socketPath)
        // Validate and connect before requiring credentials so path and socket
        // failures retain their specific diagnostics, even without a token.
        guard let token else {
            Darwin.close(descriptor)
            throw RelayError.missingCredential
        }
        // Authenticate the server before disclosing credentials or Chrome traffic.
        do { try ChromeSocketIdentity.checkNativeAgentPeer(descriptor: descriptor) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
        let framer = NativeMessagingFramer()
        do {
            let hello = try handshakeFrame(token: token, parentEvidence: parentEvidence)
            do { try framer.writeMessage(hello, toSocket: descriptor, timeout: 5) }
            catch { throw RelayError.greetingWrite(error.localizedDescription) }
            let generation = try readHelloAck(descriptor: descriptor)
            diagnostic("connected to NativeAgent.app listener generation \(generation).")
            return descriptor
        } catch {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            guard attempt == 1, handshakeToken(socketPath: socketPath) != token else { throw error }
            diagnostic("NativeAgent.app relaunched during the greeting; redialing once. Last greeting failure: \(error.localizedDescription)")
        }
    }
}

private func connectUnixSocket(path: String) throws -> Int32 {
    guard path.hasPrefix("/") else {
        throw RelayError.socketPathMustBeAbsolute
    }
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw RelayError.socketPathTooLong
    }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw RelayError.socketCreation(errno)
    }

    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
        tuplePointer.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { pathPointer in
            for (index, byte) in pathBytes.enumerated() {
                pathPointer[index] = byte
            }
        }
    }
    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, addressLength)
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw RelayError.socketConnection(code)
    }
    return descriptor
}

private func pump(
    from source: FileHandle,
    to destination: FileHandle,
    framer: NativeMessagingFramer
) throws {
    while let payload = try framer.readMessage(from: source) {
        _ = try framer.validateJSONObject(payload)
        try framer.writeMessage(payload, to: destination)
    }
}

/// Admit only a signed browser launching this host for the registered extension.
private func refuseUnlessLaunchedByChrome() throws -> ChromeHostIdentity.ParentEvidence {
    let parent = getppid()
    let identifier: String
    do { identifier = try ChromeHostIdentity.checkedBrowserSigningIdentifier(forProcess: parent) }
    catch let failure as ChromeHostIdentity.SigningFailure { throw RelayError.browserSignature(failure) }
    guard ChromeHostIdentity.argumentsCarryAllowedOrigin(CommandLine.arguments) else {
        diagnostic("refusing: argv does not carry the registered extension origin.")
        throw RelayError.originRefused
    }
    return ChromeHostIdentity.ParentEvidence(
        bundleIdentifier: identifier, processID: parent, validatedAt: Date()
    )
}

private func run() throws {
    let socketPath = ProcessInfo.processInfo.environment["NATIVEAGENT_CHROME_SOCKET_PATH"]
        ?? defaultSocketPath()
    let socketDescriptor: Int32
    let browserPID = getppid()
    do {
        let parentEvidence = try refuseUnlessLaunchedByChrome()
        socketDescriptor = try connectAndGreet(socketPath: socketPath, parentEvidence: parentEvidence)
    } catch {
        let failure = error as? RelayError
        let signature: ChromeHostIdentity.SigningFailure? = if case .browserSignature(let signature)? = failure {
            signature
        } else { error as? ChromeHostIdentity.SigningFailure }
        let check = signature?.check ?? failure?.check ?? (error as NSError).userInfo["chrome_check"] as? String ?? "relay greeting"
        let scope: ChromeRelayRefusal.Scope = if case .browserSignature? = failure { .browser } else { .listener }
        do {
            let refusal = ChromeRelayRefusal(scope: scope, check: check, osStatus: signature?.status,
                                            reason: error.localizedDescription, browserPID: browserPID)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(refusal),
                to: URL(fileURLWithPath: ChromeRelayRefusal.path(socketPath: socketPath)))
        } catch { diagnostic("Could not save Chrome relay refusal: \(error.localizedDescription)") }
        throw error
    }
    // The listener this relay reached, to tell later whether it is gone.
    let acceptedListener = ChromeHostIdentity.FileIdentity(path: socketPath)
    var peer: pid_t = 0
    var peerSize = socklen_t(MemoryLayout<pid_t>.size)
    let appPID: pid_t? = getsockopt(socketDescriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerSize) == 0 && peer > 0 ? peer : nil
    let readDescriptor = dup(socketDescriptor)
    guard readDescriptor >= 0 else {
        let code = errno
        Darwin.close(socketDescriptor)
        throw RelayError.duplicateDescriptor(code)
    }

    let chrome = RelayEndpoint(
        input: .standardInput,
        output: .standardOutput
    )
    let app = RelayEndpoint(
        input: FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true),
        output: FileHandle(fileDescriptor: socketDescriptor, closeOnDealloc: true)
    )
    let framer = NativeMessagingFramer()
    let completion = RelayCompletion()

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try pump(from: chrome.input, to: app.output, framer: framer)
            completion.finish(nil)
        } catch {
            completion.finish(error)
        }
    }
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try pump(from: app.input, to: chrome.output, framer: framer)
            completion.finish(nil)
        } catch {
            completion.finish(error)
        }
    }

    completion.semaphore.wait()
    _ = Darwin.shutdown(socketDescriptor, SHUT_RDWR)
    // An exiting app's replacement listener reconnects on Chrome's existing pipes.
    if browserPID > 1, getppid() == browserPID,
       let stale = goneListener(path: socketPath, accepted: acceptedListener, appPID: appPID) {
        var on: Int32 = 1
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        for descriptor in [socketDescriptor, readDescriptor] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        diagnostic("NativeAgent.app closed its listener; waiting for the next one.")
        if awaitSocket(path: socketPath, replacing: stale), let executable = CommandLine.arguments.first, executable.hasPrefix("/") {
            execv(executable, CommandLine.unsafeArgv)
            diagnostic("could not restart for NativeAgent.app's new listener (errno \(errno)).")
        }
    }
    if let error = completion.error() {
        throw error
    }
}

/// Nil while the app this relay reached still listens (it only replaced this
/// connection). Otherwise the socket file it left behind after a crash, which
/// the next listener replaces; `.some(nil)` when nothing was left.
private func goneListener(path: String, accepted: ChromeHostIdentity.FileIdentity?, appPID: pid_t?) -> ChromeHostIdentity.FileIdentity?? {
    guard let current = ChromeHostIdentity.FileIdentity(path: path) else { return .some(nil) }
    guard current == accepted else { return .some(nil) }
    // Same file: stale only if its app is exiting or gone and nothing answers.
    guard let appPID else { return nil }
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(appPID, PROC_PIDTBSDINFO, 0, $0, expected) }
    guard read != expected || info.pbi_status == UInt32(SZOMB) || info.pbi_flags & UInt32(PROC_FLAG_INEXIT) != 0 else { return nil }
    do {
        Darwin.close(try connectUnixSocket(path: path))
        return nil
    } catch RelayError.socketConnection(let code) where code == ECONNREFUSED {
        return .some(current)
    } catch { return nil }
}

/// Blocks until a socket other than `stale` exists at `path`; false if its
/// directory goes away. Directory events, no timer: the app writes its token
/// and binds its socket there.
private func awaitSocket(path: String, replacing stale: ChromeHostIdentity.FileIdentity?) -> Bool {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let descriptor = open(directory, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    let changed = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .global()
    )
    source.setEventHandler { changed.signal() }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    defer { source.cancel() }
    // Watch first, then look, so a listener bound in between is not missed.
    while ChromeHostIdentity.FileIdentity(path: path).map({ $0 == stale }) ?? true {
        guard access(directory, F_OK) == 0 else { return false }
        changed.wait()
    }
    return true
}

do {
    try run()
} catch {
    diagnostic(error.localizedDescription)
    exit(EXIT_FAILURE)
}
