import Foundation

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
    public static let defaultMaximumMessageBytes = 1_048_576

    public let maximumMessageBytes: Int

    public init(maximumMessageBytes: Int = Self.defaultMaximumMessageBytes) {
        precondition(maximumMessageBytes > 0 && maximumMessageBytes <= Int(UInt32.max))
        self.maximumMessageBytes = maximumMessageBytes
    }

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

    /// Closure-based seam used by tests to prove fragmented pipe reads. An
    /// empty chunk means EOF; a short non-empty chunk is accumulated.
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
        guard length <= UInt32(maximumMessageBytes) else {
            throw NativeMessagingFramingError.messageTooLarge(
                actual: Int(length),
                maximum: maximumMessageBytes
            )
        }
        return try readExactly(Int(length), allowCleanEOF: false, read: read)
    }

    public func writeMessage(_ payload: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: encode(payload))
    }

    public func validateJSONObject(_ payload: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw NativeMessagingFramingError.invalidJSON
        }
        guard value is [String: Any] else {
            throw NativeMessagingFramingError.topLevelJSONMustBeObject
        }
    }

    private func validateSize(_ payload: Data) throws {
        guard !payload.isEmpty else {
            throw NativeMessagingFramingError.emptyMessage
        }
        guard payload.count <= maximumMessageBytes else {
            throw NativeMessagingFramingError.messageTooLarge(
                actual: payload.count,
                maximum: maximumMessageBytes
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
