import Foundation
import Testing
@testable import NativeAgentChromeRelayCore

private func take(_ count: Int, from bytes: inout [UInt8]) -> Data {
    let chunk = Data(bytes.prefix(count))
    bytes.removeFirst(count)
    return chunk
}

@Suite("Chrome native-messaging framing")
struct NativeMessagingFramingTests {
    @Test("encodes the Chrome little-endian length prefix")
    func encodesLittleEndianPrefix() throws {
        let payload = Data(#"{"type":"request"}"#.utf8)
        let framed = try NativeMessagingFramer().encode(payload)

        #expect(Array(framed.prefix(4)) == [18, 0, 0, 0])
        #expect(framed.dropFirst(4) == payload)
    }

    @Test("reassembles fragmented header and payload reads")
    func readsFragmentedFrame() throws {
        let payload = Data(#"{"version":1,"type":"event"}"#.utf8)
        var bytes = Array(try NativeMessagingFramer().encode(payload))
        let result = try NativeMessagingFramer().readMessage { requested in
            guard !bytes.isEmpty else { return Data() }
            let count = min(requested, 2, bytes.count)
            return take(count, from: &bytes)
        }

        #expect(result == payload)
        #expect(bytes.isEmpty)
    }

    @Test("clean frame-boundary EOF is not an error")
    func cleanEOF() throws {
        let result = try NativeMessagingFramer().readMessage { _ in Data() }
        #expect(result == nil)
    }

    @Test("partial header and payload EOF fail closed")
    func partialEOFFails() throws {
        var partialHeader = [UInt8(3), 0]
        #expect(throws: NativeMessagingFramingError.unexpectedEndOfFile) {
            _ = try NativeMessagingFramer().readMessage { requested in
                guard !partialHeader.isEmpty else { return Data() }
                return take(min(requested, partialHeader.count), from: &partialHeader)
            }
        }

        var partialPayload = [UInt8(4), 0, 0, 0, 123, 125]
        #expect(throws: NativeMessagingFramingError.unexpectedEndOfFile) {
            _ = try NativeMessagingFramer().readMessage { requested in
                guard !partialPayload.isEmpty else { return Data() }
                return take(min(requested, partialPayload.count), from: &partialPayload)
            }
        }
    }

    @Test("zero and oversized frames are refused before allocation")
    func refusesInvalidLengths() throws {
        var zero = [UInt8](repeating: 0, count: 4)
        #expect(throws: NativeMessagingFramingError.emptyMessage) {
            _ = try NativeMessagingFramer().readMessage { requested in
                take(min(requested, zero.count), from: &zero)
            }
        }

        let framer = NativeMessagingFramer(maximumMessageBytes: 16)
        var oversized = [UInt8(17), 0, 0, 0]
        #expect(throws: NativeMessagingFramingError.messageTooLarge(actual: 17, maximum: 16)) {
            _ = try framer.readMessage { requested in
                take(min(requested, oversized.count), from: &oversized)
            }
        }
    }

    @Test("only top-level JSON objects cross the relay")
    func validatesJSONObject() throws {
        let framer = NativeMessagingFramer()
        try framer.validateJSONObject(Data(#"{"ok":true}"#.utf8))

        #expect(throws: NativeMessagingFramingError.invalidJSON) {
            try framer.validateJSONObject(Data("{".utf8))
        }
        #expect(throws: NativeMessagingFramingError.topLevelJSONMustBeObject) {
            try framer.validateJSONObject(Data("[]".utf8))
        }
    }

    @Test("writeMessage emits one complete frame and nothing else")
    func writesOneFrame() throws {
        let pipe = Pipe()
        let payload = Data(#"{"id":"one"}"#.utf8)
        try NativeMessagingFramer().writeMessage(payload, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        let expected = try NativeMessagingFramer().encode(payload)

        #expect(bytes == expected)
    }
}
