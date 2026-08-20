import Darwin
import Foundation
import NativeAgentChromeRelayCore

private enum RelayError: Error, LocalizedError {
    case socketPathMustBeAbsolute
    case socketPathTooLong
    case socketCreation(Int32)
    case socketConnection(Int32)
    case duplicateDescriptor(Int32)

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

private func run() throws {
    let socketPath = ProcessInfo.processInfo.environment["NATIVEAGENT_CHROME_SOCKET_PATH"]
        ?? defaultSocketPath()
    let socketDescriptor = try connectUnixSocket(path: socketPath)
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
