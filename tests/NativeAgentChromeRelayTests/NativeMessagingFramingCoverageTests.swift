import Foundation
import Testing

@testable import NativeAgentChromeRelayCore

// Coverage evals for the framing rows of the `relay` fence that no existing
// test entered. Every existing framing test's reader does `min(requested, …)`
// and every existing size test uses a CUSTOM 16-byte framer, so the over-read
// refusal, the 1 MiB default bound, and the whole WRITE-side size guard were
// unentered branches.

/// Records what a closure reader was asked for, so a test can prove a refusal
/// happened BEFORE the payload was ever requested (i.e. before allocation).
private final class ScriptedReader {
    private(set) var requests: [Int] = []
    private var chunks: [Data]

    init(chunks: [Data]) { self.chunks = chunks }

    func read(_ requested: Int) -> Data {
        requests.append(requested)
        guard !chunks.isEmpty else { return Data() }
        return chunks.removeFirst()
    }
}

@Suite("Chrome relay framing coverage")
struct NativeMessagingFramingCoverageTests {

    // MARK: relay.framing.readMessage.overReadRefusal

    @Test("a reader returning MORE than requested is refused, not silently truncated")
    func refusesOverReadingHeader() throws {
        // The surplus byte is the head of the NEXT frame. Swallowing it
        // desynchronizes the channel one frame at a time with no error, which
        // is why this branch must throw rather than truncate.
        let reader = ScriptedReader(chunks: [Data([4, 0, 0, 0, 0x7B])])
        #expect(throws: NativeMessagingFramingError.messageTooLarge(actual: 5, maximum: 4)) {
            _ = try NativeMessagingFramer().readMessage(read: reader.read)
        }
        // Refused on the first read; the framer did not keep pulling bytes.
        #expect(reader.requests == [4])
    }

    @Test("over-reading the PAYLOAD is refused with the exact surplus named")
    func refusesOverReadingPayload() throws {
        let payload = Data(#"{"id":"a"}"#.utf8)
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8(payload.count)
        // Header exact, then one byte too many on the payload read.
        let reader = ScriptedReader(chunks: [
            Data(header),
            payload + Data([0x21]),
        ])
        #expect(
            throws: NativeMessagingFramingError.messageTooLarge(
                actual: payload.count + 1, maximum: payload.count
            )
        ) {
            _ = try NativeMessagingFramer().readMessage(read: reader.read)
        }
        #expect(reader.requests == [4, payload.count])
    }

    @Test("a well-behaved reader that returns exactly the requested count still round-trips")
    func exactReaderStillWorks() throws {
        // Negative control for the two evals above: the guard must bite ONLY
        // on a surplus, never on an exact-count reader.
        let payload = Data(#"{"id":"a"}"#.utf8)
        var bytes = Array(try NativeMessagingFramer().encode(payload))
        let result = try NativeMessagingFramer().readMessage { requested in
            let chunk = Data(bytes.prefix(requested))
            bytes.removeFirst(chunk.count)
            return chunk
        }
        #expect(result == payload)
    }

    // MARK: relay.framing.maximumMessageBytes.default

    @Test("the default frame bound is 1 MiB and is what a bare framer uses")
    func defaultMaximumIsPinned() throws {
        // Both processes construct a bare `NativeMessagingFramer()` — relay
        // main.swift:139 and app ChromeControlRuntime.swift:89 — so this value
        // is an unwritten CROSS-PROCESS contract. Pin it here; the spawned
        // relay pins the same number end-to-end in
        // RelayExecutableTransportTests.oversizeFrameNamesTheDefaultBound.
        #expect(NativeMessagingFramer.defaultMaximumMessageBytes == 1_048_576)
        #expect(
            NativeMessagingFramer().maximumMessageBytes
                == NativeMessagingFramer.defaultMaximumMessageBytes
        )
    }

    @Test("a frame one byte over the default is refused before the payload is read")
    func defaultMaximumRefusesOversizeBeforeAllocation() throws {
        let maximum = NativeMessagingFramer.defaultMaximumMessageBytes
        let oversize = UInt32(maximum + 1)
        let header = Data([
            UInt8(oversize & 0xFF),
            UInt8((oversize >> 8) & 0xFF),
            UInt8((oversize >> 16) & 0xFF),
            UInt8((oversize >> 24) & 0xFF),
        ])
        let reader = ScriptedReader(chunks: [header])
        #expect(
            throws: NativeMessagingFramingError.messageTooLarge(
                actual: maximum + 1, maximum: maximum
            )
        ) {
            _ = try NativeMessagingFramer().readMessage(read: reader.read)
        }
        // The load-bearing half: only the 4-byte header was ever requested, so
        // a hostile length prefix cannot make the relay reserve 1 MiB+.
        #expect(reader.requests == [4])
    }

    @Test("a frame exactly at the default bound is accepted")
    func defaultMaximumBoundaryIsInclusive() throws {
        // Off-by-one control for the eval above.
        let maximum = NativeMessagingFramer.defaultMaximumMessageBytes
        let payload = Data(repeating: 0x61, count: maximum)
        let framed = try NativeMessagingFramer().encode(payload)
        #expect(framed.count == maximum + 4)
        var bytes = framed
        let result = try NativeMessagingFramer().readMessage { requested in
            let chunk = bytes.prefix(requested)
            bytes = bytes.dropFirst(chunk.count)
            return Data(chunk)
        }
        #expect(result?.count == maximum)
    }

    // MARK: relay.framing.encode.sizeValidation

    @Test("encode refuses an empty payload and an oversize payload")
    func encodeValidatesSize() throws {
        let framer = NativeMessagingFramer()
        #expect(throws: NativeMessagingFramingError.emptyMessage) {
            _ = try framer.encode(Data())
        }
        let maximum = NativeMessagingFramer.defaultMaximumMessageBytes
        #expect(
            throws: NativeMessagingFramingError.messageTooLarge(
                actual: maximum + 1, maximum: maximum
            )
        ) {
            _ = try framer.encode(Data(count: maximum + 1))
        }
    }

    @Test("writeMessage writes ZERO bytes when the payload violates the size contract")
    func writeMessageEmitsNothingOnInvalidSize() throws {
        // If validateSize regressed to a no-op, an empty payload would put a
        // `00 00 00 00` header on the wire and the PEER would tear down its
        // whole process on emptyMessage. Assert the handle stays untouched.
        let pipe = Pipe()
        let framer = NativeMessagingFramer()
        #expect(throws: NativeMessagingFramingError.emptyMessage) {
            try framer.writeMessage(Data(), to: pipe.fileHandleForWriting)
        }
        try framer.writeMessage(Data(#"{"ok":true}"#.utf8), to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let written = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(written == (try framer.encode(Data(#"{"ok":true}"#.utf8))))
    }

    // MARK: relay.framing.readMessage.fileHandle

    @Test("the FileHandle overload reassembles a frame delivered in fragments with stalls")
    func fileHandleOverloadSurvivesFragmentedWrites() throws {
        // The FileHandle overload maps `read(upToCount:) ?? Data()` to EOF, so
        // a real pipe that hands back short reads must still reassemble. Three
        // fragments with stalls between them: split header, header/payload
        // boundary, split payload.
        let payload = Data(#"{"version":1,"type":"event","body":"fragmented"}"#.utf8)
        let framed = try NativeMessagingFramer().encode(payload)
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let fragments = [
            framed.prefix(2),
            framed.dropFirst(2).prefix(6),
            framed.dropFirst(8),
        ]
        let writer = Thread {
            for fragment in fragments {
                _ = writeAllBytes(writeHandle.fileDescriptor, Data(fragment))
                Thread.sleep(forTimeInterval: 0.03)
            }
            try? writeHandle.close()
        }
        writer.name = "fragmented-frame-writer"
        writer.start()

        let framer = NativeMessagingFramer()
        let result = try framer.readMessage(from: pipe.fileHandleForReading)
        #expect(result == payload)
        // And the very next read sees a CLEAN frame-boundary EOF, not a throw.
        #expect(try framer.readMessage(from: pipe.fileHandleForReading) == nil)
    }

    @Test("the FileHandle overload fails closed on a mid-frame EOF")
    func fileHandleOverloadFailsClosedMidFrame() throws {
        // The other half of the nil->EOF mapping: a writer that dies after the
        // header must produce unexpectedEndOfFile, never a short payload.
        let pipe = Pipe()
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = 12
        _ = writeAllBytes(pipe.fileHandleForWriting.fileDescriptor, Data(header + [0x7B, 0x7D]))
        try pipe.fileHandleForWriting.close()
        #expect(throws: NativeMessagingFramingError.unexpectedEndOfFile) {
            _ = try NativeMessagingFramer().readMessage(from: pipe.fileHandleForReading)
        }
    }
}
