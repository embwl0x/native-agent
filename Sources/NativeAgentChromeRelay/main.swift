import Darwin
import Foundation
import NativeAgentChromeRelayCore

private enum RelayError: Error, LocalizedError {
    case socketPathMustBeAbsolute
    case socketPathTooLong
    case socketCreation(Int32)
    case socketConnection(Int32)
    case duplicateDescriptor(Int32)
    case handshakeRefused
    case notLaunchedByChrome

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
        case .handshakeRefused:
            return "NativeAgent.app refused this relay's greeting."
        case .notLaunchedByChrome:
            return "NativeAgentChromeRelay is a Chrome native messaging host and "
                + "was not launched by Chrome for the registered extension."
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
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NativeAgent", isDirectory: true)
        .appendingPathComponent("chrome-control.sock")
        .path
}

/// 2026-09-06: NativeAgent.app authenticates whoever connects to its control
/// socket, because every process running as this Mac user can reach it. The app
/// writes a per-launch secret 0600 next to the socket; presenting it in the
/// connection's first frame is what separates the relay the app registered from
/// anything else that dialed the same path. No secret on disk means no app is
/// listening for one — the link then behaves exactly as it always did.
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
) -> Data? {
    // 2026-09-06: carry what we proved about our parent at launch. The app
    // checks our parent live, and by the time it looks the browser that
    // launched us may already have exited, leaving us to launchd; this is the
    // only account of that moment anybody still has.
    var object: [String: Any] = ["version": 1, "type": "hello", "token": token]
    for (key, value) in parentEvidence?.helloFields ?? [:] { object[key] = value }
    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
private func readHelloAck(descriptor: Int32) -> String? {
    let deadline = Date().addingTimeInterval(5)
    defer {
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &none, socklen_t(MemoryLayout<timeval>.size)
        )
    }
    let framer = NativeMessagingFramer()
    let frame = try? framer.readMessage { count in
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.001 else { return Data() }
        var window = timeval(
            tv_sec: Int(remaining),
            tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &window, socklen_t(MemoryLayout<timeval>.size)
        )
        var buffer = [UInt8](repeating: 0, count: count)
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.recv(descriptor, raw.baseAddress, count, 0)
        }
        guard received > 0 else { return Data() }
        return Data(buffer.prefix(received))
    }
    guard let frame,
          let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
          object["version"] as? Int == 1,
          object["type"] as? String == "hello_ack",
          let generation = object["generation"] as? String
    else { return nil }
    return generation
}

private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var sent = 0
        while sent < raw.count {
            let written = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
            guard written > 0 else { return false }
            sent += written
        }
        return true
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
        // No secret on disk means no app is listening for one — the link then
        // behaves exactly as it always did, with no greeting either way.
        guard let token,
              let hello = handshakeFrame(token: token, parentEvidence: parentEvidence)
        else { return descriptor }
        let framer = NativeMessagingFramer()
        if let frame = try? framer.encode(hello), writeAll(frame, to: descriptor),
           let generation = readHelloAck(descriptor: descriptor) {
            diagnostic("connected to NativeAgent.app listener generation \(generation).")
            return descriptor
        }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        guard attempt == 1, handshakeToken(socketPath: socketPath) != token else {
            throw RelayError.handshakeRefused
        }
        diagnostic("NativeAgent.app relaunched during the greeting; redialing once.")
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
    guard let parentPath = ChromeHostIdentity.executablePath(ofProcess: parent),
          let identifier = ChromeHostIdentity.browserSigningIdentifier(
              forExecutablePath: parentPath
          ) else {
        diagnostic("refusing: the parent process is not a signed Chromium-family browser.")
        throw RelayError.notLaunchedByChrome
    }
    guard ChromeHostIdentity.argumentsCarryAllowedOrigin(CommandLine.arguments) else {
        diagnostic("refusing: argv does not carry the registered extension origin.")
        throw RelayError.notLaunchedByChrome
    }
    return ChromeHostIdentity.ParentEvidence(
        bundleIdentifier: identifier, processID: parent, validatedAt: Date()
    )
}

private func run() throws {
    let parentEvidence = try refuseUnlessLaunchedByChrome()
    let socketPath = ProcessInfo.processInfo.environment["NATIVEAGENT_CHROME_SOCKET_PATH"]
        ?? defaultSocketPath()
    let socketDescriptor = try connectAndGreet(
        socketPath: socketPath, parentEvidence: parentEvidence
    )
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
    if let error = completion.error() {
        throw error
    }
}

do {
    try run()
} catch {
    diagnostic(error.localizedDescription)
    exit(EXIT_FAILURE)
}
