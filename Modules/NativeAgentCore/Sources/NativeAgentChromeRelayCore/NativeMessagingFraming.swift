import Darwin
import Foundation

// Blueprint: | `NativeMessagingFraming.swift` | `NativeMessagingFramer`: bounded little-endian JSON framing shared by Chrome pipes and private relay socket, with exact fragmented reads |

public enum NativeMessagingFramingError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedEndOfFile
    case emptyMessage
    case messageTooLarge(actual: Int, maximum: Int)
    case invalidJSON
    case topLevelJSONMustBeObject

    public var errorDescription: String? {
        switch self {
        case .unexpectedEndOfFile:
            return "Native-messaging input ended inside a frame."
        case .emptyMessage:
            return "Native-messaging frames cannot be empty."
        case let .messageTooLarge(actual, maximum):
            return "Native-messaging frame is \(actual) bytes; maximum is \(maximum)."
        case .invalidJSON:
            return "Native-messaging payload is not valid JSON."
        case .topLevelJSONMustBeObject:
            return "Native-messaging payload must be a top-level JSON object."
        }
    }
}

/// Chrome native messaging uses a four-byte little-endian payload length
/// followed by one UTF-8 JSON message. The same framing is deliberately reused
/// on the relay's private Unix-socket side so the relay can remain opaque and
/// transport-only.
public struct NativeMessagingFramer: Sendable {
    private static let maximumMessageBytes = 1_048_576

    public init() {}

    public func encode(_ payload: Data) throws -> Data {
        try validateSize(payload)
        var littleEndianLength = UInt32(payload.count).littleEndian
        var framed = withUnsafeBytes(of: &littleEndianLength) { Data($0) }
        framed.append(payload)
        return framed
    }

    public func readMessage(from handle: FileHandle) throws -> Data? {
        try readMessage { count in
            try handle.read(upToCount: count) ?? Data()
        }
    }

    /// Authentication readers update their deadline before each fragmented
    /// read. An empty chunk means EOF; a short non-empty chunk is accumulated.
    public func readMessage(read: (Int) throws -> Data) throws -> Data? {
        guard let header = try readExactly(4, allowCleanEOF: true, read: read) else {
            return nil
        }
        let bytes = Array(header)
        let length = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        guard length > 0 else {
            throw NativeMessagingFramingError.emptyMessage
        }
        guard length <= UInt32(Self.maximumMessageBytes) else {
            throw NativeMessagingFramingError.messageTooLarge(
                actual: Int(length),
                maximum: Self.maximumMessageBytes
            )
        }
        return try readExactly(Int(length), allowCleanEOF: false, read: read)
    }

    public func writeMessage(_ payload: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: encode(payload))
    }

    /// Borrows the descriptor for a bounded complete frame and restores its timeout.
    public func readMessage(fromSocket descriptor: Int32, timeout: TimeInterval) throws -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer { var none = timeval(); setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size)) }
        return try readMessage { count in
            var buffer = [UInt8](repeating: 0, count: count)
            while true {
                try socketWindow(descriptor, option: SO_RCVTIMEO, deadline: deadline)
                let received = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, count, 0) }
                if received < 0, errno == EINTR { continue }
                guard received >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return Data(buffer.prefix(received))
            }
        }
    }

    public func writeMessage(_ payload: Data, toSocket descriptor: Int32, timeout: TimeInterval) throws {
        let frame = try encode(payload)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { var none = timeval(); setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size)) }
        try frame.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                try socketWindow(descriptor, option: SO_SNDTIMEO, deadline: deadline)
                let written = Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: written == 0 ? EPIPE : errno) ?? .EIO) }
                sent += written
            }
        }
    }

    private func socketWindow(_ descriptor: Int32, option: Int32, deadline: TimeInterval) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0.001 else { throw POSIXError(.ETIMEDOUT) }
        var window = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000))
        guard setsockopt(descriptor, SOL_SOCKET, option, &window, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func validateJSONObject(_ payload: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw NativeMessagingFramingError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw NativeMessagingFramingError.topLevelJSONMustBeObject
        }
        return object
    }

    private func validateSize(_ payload: Data) throws {
        guard !payload.isEmpty else {
            throw NativeMessagingFramingError.emptyMessage
        }
        guard payload.count <= Self.maximumMessageBytes else {
            throw NativeMessagingFramingError.messageTooLarge(
                actual: payload.count,
                maximum: Self.maximumMessageBytes
            )
        }
    }

    private func readExactly(
        _ count: Int,
        allowCleanEOF: Bool,
        read: (Int) throws -> Data
    ) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try read(count - result.count)
            if chunk.isEmpty {
                if allowCleanEOF && result.isEmpty {
                    return nil
                }
                throw NativeMessagingFramingError.unexpectedEndOfFile
            }
            guard chunk.count <= count - result.count else {
                // A FileHandle honors the requested count. Refuse a custom
                // reader that violates the same contract instead of dropping
                // bytes from the next frame.
                throw NativeMessagingFramingError.messageTooLarge(
                    actual: result.count + chunk.count,
                    maximum: count
                )
            }
            result.append(chunk)
        }
        return result
    }
}
