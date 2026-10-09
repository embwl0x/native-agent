import Darwin
import Foundation
import NativeAgentChromeRelayCore
import PersistenceCore

private enum RelayError: Error, LocalizedError {
    case socketPathMustBeAbsolute
    case socketPathTooLong
    case socketCreation(Int32)
    case socketConnection(Int32)
    case duplicateDescriptor(Int32)
    case handshakeRefused(String)
    case greetingWrite(Int32)
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
        case .greetingWrite(let code): return "Relay greeting socket write failed (errno \(code))."
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

/// 2026-09-06: NativeAgent.app authenticates whoever connects to its control
/// socket, because every process running as this Mac user can reach it. The app
/// writes a per-launch secret 0600 next to the socket; presenting it in the
/// connection's first frame is what separates the relay the app registered from
/// anything else that dialed the same path. Missing credentials fail closed.
private func handshakeTokenPath(forSocket socketPath: String) -> String {
    URL(fileURLWithPath: socketPath)
        .deletingLastPathComponent()
        .appendingPathComponent("chrome-control.token")
        .path
}

private func handshakeToken(socketPath: String) -> String? {
    guard let raw = try? String(
        contentsOfFile: handshakeTokenPath(forSocket: socketPath),
        encoding: .utf8
    ) else { return nil }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

private func handshakeFrame(
    token: String,
    parentEvidence: ChromeHostIdentity.ParentEvidence?
) throws -> Data {
    // 2026-09-06: carry what we proved about our parent at launch. The app
    // checks our parent live, and by the time it looks the browser that
    // launched us may already have exited, leaving us to launchd; this is the
    // only account of that moment anybody still has.
    var object: [String: Any] = ["version": 1, "type": "hello", "token": token]
    for (key, value) in parentEvidence?.helloFields ?? [:] { object[key] = value }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// 2026-09-06: the app answers a proven greeting with `hello_ack`, carrying the
/// listener generation that accepted us. Reading it is how this relay tells
/// "accepted" from "refused" — before, both looked like a socket that simply
/// went quiet, and the refusal that matters is the one where the app relaunched
/// between our token read and our dial, so the secret we presented belonged to
/// a listener that no longer exists.
///
/// Raw `recv` under one wall-clock deadline, for the same reason the app reads
/// the hello that way: a FileHandle read on a timed-out socket raises, and the
/// framer loops until a frame is complete, so a per-read timeout would let a
/// dripped byte hold this process open indefinitely.
private func readHelloAck(descriptor: Int32) throws -> String {
    let deadline = Date().addingTimeInterval(5)
    defer {
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &none, socklen_t(MemoryLayout<timeval>.size)
        )
    }
    let framer = NativeMessagingFramer()
    var readFailure: String?
    let frame: Data?
    do { frame = try framer.readMessage { count in
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.001 else {
            readFailure = "the app acknowledgement did not complete within the authentication deadline."
            return Data()
        }
        var window = timeval(
            tv_sec: Int(remaining),
            tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000)
        )
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &window, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            readFailure = "the app acknowledgement socket receive window could not be set (errno \(errno))."
            return Data()
        }
        var buffer = [UInt8](repeating: 0, count: count)
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.recv(descriptor, raw.baseAddress, count, 0)
        }
        guard received > 0 else {
            readFailure = received == 0 ? "the app closed before acknowledging the greeting."
                : "the app acknowledgement socket read failed (errno \(errno))."
            return Data()
        }
        return Data(buffer.prefix(received))
    } } catch {
        throw RelayError.handshakeRefused(readFailure ?? "the acknowledgement frame could not be decoded: \(error.localizedDescription)")
    }
    guard let frame else { throw RelayError.handshakeRefused(readFailure ?? "the app sent no acknowledgement.") }
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

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { throw RelayError.greetingWrite(EINVAL) }
        var sent = 0
        while sent < raw.count {
            let written = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
            guard written > 0 else { throw RelayError.greetingWrite(errno) }
            sent += written
        }
    }
}

/// Dial the app and complete the greeting. A refused connection is retried ONCE
/// and only when the secret on disk has changed since we read it — that is the
/// signal that the app relaunched under us, and the new listener is reachable
/// at the same path. Any other refusal is real and is reported.
private func connectAndGreet(
    socketPath: String,
    parentEvidence: ChromeHostIdentity.ParentEvidence?
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
        // 2026-09-06: preserve the tokenless hermetic transport lane. The bare
        // SwiftPM executable never ships; Chrome launches the bundled relay,
        // which the app alone accepts. Require a kernel-reported, non-bundled
        // executable path: neither argv nor environment can exempt a bundled
        // relay, and an unavailable path still requires the secure handshake.
        if token == nil,
           let selfPath = ChromeHostIdentity.executablePath(ofProcess: getpid()),
           !ChromeHostIdentity.isBundledRelay(executablePath: selfPath) {
            return descriptor
        }
        // Validate and connect before requiring credentials so path and socket
        // failures retain their specific diagnostics, even without a token.
        guard let token else {
            Darwin.close(descriptor)
            throw RelayError.missingCredential
        }
        // 2026-09-06: authenticate the server before disclosing the greeting
        // credential or forwarding any Chrome traffic to a same-user listener.
        do { try ChromeSocketIdentity.checkNativeAgentPeer(descriptor: descriptor) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
        let framer = NativeMessagingFramer()
        do {
            let hello = try handshakeFrame(token: token, parentEvidence: parentEvidence)
            try writeAll(framer.encode(hello), to: descriptor)
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
        try framer.validateJSONObject(payload)
        try framer.writeMessage(payload, to: destination)
    }
}

/// 2026-09-06: this process treats its own stdin/stdout as Chrome, and it is
/// the executable the app's peer check expects — so a same-user process that
/// simply launches the bundled relay with pipes of its own passes both sides
/// and takes the channel. Chrome launches its native messaging hosts itself
/// and names the calling extension in argv; neither is true of an arbitrary
/// launcher. Refuse when either fails.
///
/// Scoped to the relay INSIDE an app bundle — the only relay the app accepts
/// as a peer, and so the only one worth impersonating. A bare build-products
/// binary is unchanged; the app does not accept that one either.
private func refuseUnlessLaunchedByChrome() throws -> ChromeHostIdentity.ParentEvidence? {
    let selfPath = ChromeHostIdentity.executablePath(ofProcess: getpid())
        ?? CommandLine.arguments.first ?? ""
    guard ChromeHostIdentity.isBundledRelay(executablePath: selfPath) else { return nil }
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
            try ChromeRelayRefusal(scope: scope, check: check, osStatus: signature?.status,
                                   reason: error.localizedDescription, browserPID: browserPID).write(socketPath: socketPath)
        } catch { diagnostic("Could not save Chrome relay refusal: \(error.localizedDescription)") }
        throw error
    }
    // The listener this relay reached, to tell later whether it is gone.
    let acceptedListener = SocketFile(path: socketPath)
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
    // 2026-10-07: the app quit (an install or a relaunch) or crashed while
    // Chrome still holds this host. Wait for its next listener and start over
    // as the registered relay on Chrome's same pipes, instead of leaving the
    // extension on its 30-second reconnect alarm.
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

/// A socket file's identity: a relaunched app unlinks and binds a new one.
private struct SocketFile: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Nil while the app this relay reached still listens (it only replaced this
/// connection). Otherwise the socket file it left behind after a crash, which
/// the next listener replaces; `.some(nil)` when nothing was left.
private func goneListener(path: String, accepted: SocketFile?, appPID: pid_t?) -> SocketFile?? {
    guard let current = SocketFile(path: path) else { return .some(nil) }
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
private func awaitSocket(path: String, replacing stale: SocketFile?) -> Bool {
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
    while SocketFile(path: path).map({ $0 == stale }) ?? true {
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
