import Foundation
import Dispatch
import Darwin
import Synchronization
// Blueprint: | `FaceLink.swift` | Ordered asynchronous binary framing with inline JSON and raw data over parent/child pipe handles |

extension FaceLink {
    public struct Requests: Sendable {
        private var last: UInt64 = 0
        private var tail: Task<Void, Error>?

        public init() {}

        public mutating func enqueue(on link: Connection, beginWrite: (@Sendable () -> Bool)? = nil,
                                     _ make: (UInt64) -> FaceEnvelope) throws -> (id: UInt64, write: Task<Void, Error>) {
            guard last < UInt64.max else { throw FaceWireError.invalidFeedOrder }
            last += 1
            let envelope = make(last)
            let write = Task { [tail] in
                try await tail?.value
                try await link.send(envelope, beginWrite: beginWrite)
            }
            tail = write
            return (last, write)
        }
    }

    /// A connection has one incoming consumer and one ordered writer. Its owner closes it on cancellation or process exit.
    public actor Connection {
        public nonisolated let incoming: AsyncThrowingStream<FaceEnvelope, Error>
        private let io: FacePipeIO
        private let reader: Task<Void, Never>
        private let registry: FaceValueRegistry
        private let lifetime: FaceLinkLifetime
        private var pending: [Write] = []
        private var writing = false
        private var activeWrite: UUID?
        private var failure: (any Error)?

        @concurrent nonisolated public static func open(input: FileHandle, output: FileHandle,
                                                       registry: FaceValueRegistry = .standard) async throws -> Connection {
            try Connection(input: input, output: output, registry: registry)
        }

        private init(input: FileHandle, output: FileHandle, registry: FaceValueRegistry) throws {
            let io = try FacePipeIO(input: input, output: output)
            self.io = io
            self.registry = registry
            let lifetime = FaceLinkLifetime()
            self.lifetime = lifetime
            let (incoming, continuation) = AsyncThrowingStream<FaceEnvelope, Error>.makeStream()
            self.incoming = incoming
            reader = Task.detached {
                do {
                    var frames = FaceFrameDecoder()
                    for try await bytes in io.chunks {
                        try Task.checkCancellation()
                        for data in try frames.append(bytes) {
                            continuation.yield(try FacePacket.decode(data, registry: registry))
                        }
                    }
                    try frames.finish()
                    await lifetime.end(reachedEOF: true)
                    continuation.finish()
                } catch {
                    await lifetime.end()
                    continuation.finish(throwing: error)
                }
                io.close()
            }
            continuation.onTermination = { _ in io.close() }
        }

        deinit {
            reader.cancel()
            io.close()
            Task { [lifetime] in await lifetime.end() }
            for write in pending { write.continuation.resume(throwing: FaceWireError.disconnected) }
        }

        /// Clean input EOF is known before the consumer finishes draining buffered envelopes.
        public var reachedEOF: Bool {
            get async { await lifetime.reachedEOF }
        }

        /// Completion means bytes reached the pipe; only a correlated reply establishes the other process's outcome.
        public func send(_ envelope: FaceEnvelope) async throws {
            try await send(envelope, beginWrite: nil)
        }

        fileprivate func send(_ envelope: FaceEnvelope, beginWrite: (@Sendable () -> Bool)?) async throws {
            try Task.checkCancellation()
            if let failure { throw failure }
            let frame = try FacePacket.encode(envelope, registry: registry)
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pending.append(Write(id: id, data: frame, beginWrite: beginWrite, continuation: continuation))
                    if !writing {
                        writing = true
                        Task { await self.drain() }
                    }
                }
            } onCancel: {
                Task { await self.cancelWrite(id) }
            }
        }

        public func close() async {
            await end(FaceWireError.disconnected)
            reader.cancel()
        }

        private func cancelWrite(_ id: UUID) async {
            if let index = pending.firstIndex(where: { $0.id == id }) {
                pending.remove(at: index).continuation.resume(throwing: CancellationError())
            } else if activeWrite == id {
                // A partially written frame cannot be withdrawn without ending its connection.
                await end(CancellationError())
            }
        }

        private func drain() async {
            while !pending.isEmpty {
                let write = pending.removeFirst()
                activeWrite = write.id
                do {
                    try await io.write(write.data, beginWrite: write.beginWrite)
                    write.continuation.resume()
                } catch {
                    write.continuation.resume(throwing: error)
                    await end(error)
                }
                activeWrite = nil
            }
            writing = false
        }

        private func end(_ cause: any Error) async {
            if failure == nil { failure = cause }
            io.close()
            let waiting = pending
            pending.removeAll()
            for write in waiting { write.continuation.resume(throwing: cause) }
            await lifetime.end()
        }

        private struct Write: Sendable {
            let id: UUID
            let data: Data
            let beginWrite: (@Sendable () -> Bool)?
            let continuation: CheckedContinuation<Void, Error>
        }
    }

}

private actor FaceLinkLifetime {
    private var terminationReachedEOF: Bool?

    var reachedEOF: Bool { terminationReachedEOF == true }

    func end(reachedEOF: Bool = false) {
        guard terminationReachedEOF == nil else { return }
        terminationReachedEOF = reachedEOF
    }
}

/// Dispatch owns nonblocking pipe readiness and cancellation; no read or write occupies the main actor.
private final class FacePipeIO: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let input: DispatchIO
    private let output: DispatchIO
    private let queue: DispatchQueue

    init(input: FileHandle, output: FileHandle) throws {
        let readFD = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard readFD >= 0 else { throw FaceWireError.io(errno) }
        let writeFD = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard writeFD >= 0 else {
            let cause = errno
            Darwin.close(readFD)
            throw FaceWireError.io(cause)
        }
        // SIGPIPE must report EPIPE to the writer rather than terminate the process.
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else {
            let cause = errno
            Darwin.close(readFD)
            Darwin.close(writeFD)
            throw FaceWireError.io(cause)
        }
        let queue = DispatchQueue(label: "NativeAgent.FaceLink", qos: .userInitiated)
        self.queue = queue
        let reader = DispatchIO(type: .stream, fileDescriptor: readFD, queue: queue) { _ in Darwin.close(readFD) }
        let writer = DispatchIO(type: .stream, fileDescriptor: writeFD, queue: queue) { _ in Darwin.close(writeFD) }
        self.input = reader
        self.output = writer
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.chunks = chunks
        continuation.onTermination = { _ in reader.close(flags: .stop) }
        reader.setLimit(lowWater: 1)
        reader.setLimit(highWater: 65_536)
        reader.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty { continuation.yield(Data(data)) }
            if error != 0 { continuation.finish(throwing: FaceWireError.io(error)) }
            else if done { continuation.finish() }
        }
    }

    func write(_ data: Data, beginWrite: (@Sendable () -> Bool)?) async throws {
        let bytes = unsafe data.withUnsafeBytes { unsafe DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if beginWrite?() == false {
                continuation.resume()
                return
            }
            output.write(offset: 0, data: bytes, queue: queue) { done, remaining, error in
                guard done else { return }
                if error != 0 { continuation.resume(throwing: FaceWireError.io(error)) }
                else if let remaining, !remaining.isEmpty { continuation.resume(throwing: FaceWireError.io(EIO)) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        input.close(flags: .stop)
        output.close(flags: .stop)
    }
}

private struct FaceFrameDecoder {
    private var buffer = Data()
    private var length: Int?

    /// Compact only after consuming a prefix, releasing framed bytes without copying a growing incomplete payload on each chunk.
    mutating func append(_ bytes: Data) throws(FaceWireError) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        var read = buffer.startIndex
        defer { if read != buffer.startIndex { buffer = Data(buffer[read...]) } }
        while true {
            if length == nil {
                guard buffer.endIndex - read >= 8 else { return frames }
                let count = buffer[read..<read + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard count > 0, let size = Int(exactly: count) else {
                    throw FaceWireError.invalidFrameLength(count)
                }
                read += 8
                length = size
            }
            guard let length, buffer.endIndex - read >= length else { return frames }
            frames.append(Data(buffer[read..<read + length]))
            read += length
            self.length = nil
        }
    }

    func finish() throws(FaceWireError) {
        guard buffer.isEmpty, length == nil else { throw FaceWireError.truncatedFrame }
    }
}

private enum FacePacket {
    private static let inlineLimit = 4096

    private enum Kind: UInt8 {
        case feed, call, reply, act, actReply
    }

    private struct Request<Value: Codable>: Codable {
        let id: UInt64
        let value: Value
    }

    private final class BlobTable: Sendable {
        let chunks = Mutex<[Int: Data]>([:])
    }

    private enum Bytes: Codable {
        case inline(String)
        case blob(Int)
    }

    static func encode(_ envelope: FaceEnvelope, registry: FaceValueRegistry) throws -> Data {
        guard let key = CodingUserInfoKey.faceValueRegistry else { throw FaceWireError.registryConfiguration }
        let encoder = JSONEncoder()
        encoder.userInfo[key] = registry
        let table = BlobTable()
        encoder.dataEncodingStrategy = .custom { data, encoder in
            let reference: Bytes
            if data.count > inlineLimit {
                reference = .blob(table.chunks.withLock { blobs in
                    let index = blobs.count
                    blobs[index] = data
                    return index
                })
            } else {
                reference = .inline(data.base64EncodedString())
            }
            try reference.encode(to: encoder)
        }
        let kind: Kind
        let header: Data
        switch envelope {
        case .feed(let batch):
            kind = .feed
            header = try encoder.encode(batch)
        case .call(let id, let value):
            kind = .call
            header = try encoder.encode(Request(id: id, value: value))
        case .reply(let id, let value):
            kind = .reply
            header = try encoder.encode(Request(id: id, value: value))
        case .act(let id, let value):
            kind = .act
            header = try encoder.encode(Request(id: id, value: value))
        case .actReply(let id, let value):
            kind = .actReply
            header = try encoder.encode(Request(id: id, value: value))
        }
        return try table.chunks.withLock { blobs in
            let size = blobs.values.reduce(17 + header.count) { $0 + 8 + $1.count }
            var frame = Data(capacity: 8 + size)
            func appendLength(_ length: Int) {
                withUnsafeBytes(of: UInt64(length).bigEndian) { unsafe frame.append(contentsOf: $0) }
            }
            appendLength(size)
            appendLength(header.count)
            appendLength(blobs.count)
            frame.append(kind.rawValue)
            frame.append(header)
            for index in 0..<blobs.count {
                guard let blob = blobs[index] else { throw FaceWireError.invalidFrame }
                appendLength(blob.count)
                frame.append(blob)
            }
            return frame
        }
    }

    static func decode(_ packet: Data, registry: FaceValueRegistry) throws -> FaceEnvelope {
        var cursor = packet.startIndex
        func take(_ count: Int) throws(FaceWireError) -> Data {
            guard count <= packet.endIndex - cursor else { throw FaceWireError.truncatedFrame }
            defer { cursor += count }
            return packet[cursor..<cursor + count]
        }
        func length() throws(FaceWireError) -> Int {
            let value = try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard let count = Int(exactly: value) else { throw FaceWireError.invalidFrameLength(value) }
            return count
        }
        let headerLength = try length()
        let count = try length()
        guard let tag = try take(1).first else { throw FaceWireError.truncatedFrame }
        let header = try take(headerLength)
        let table = BlobTable()
        for index in 0..<count {
            let size = try length()
            guard size > inlineLimit else { throw FaceWireError.invalidFrame }
            let blob = try take(size)
            table.chunks.withLock { $0[index] = blob }
        }
        guard cursor == packet.endIndex else { throw FaceWireError.invalidFrame }
        let decoder = JSONDecoder()
        guard let key = CodingUserInfoKey.faceValueRegistry else { throw FaceWireError.registryConfiguration }
        decoder.userInfo[key] = registry
        decoder.dataDecodingStrategy = .custom { decoder in
            switch try Bytes(from: decoder) {
            case .blob(let index):
                guard let blob = table.chunks.withLock({ $0.removeValue(forKey: index) }) else { throw FaceWireError.invalidFrame }
                return Data(blob)
            case .inline(let string):
                guard let data = Data(base64Encoded: string), data.count <= inlineLimit else { throw FaceWireError.invalidFrame }
                return data
            }
        }
        func readRequest<Value: Codable>(_ type: Value.Type) throws -> Request<Value> {
            try decoder.decode(Request<Value>.self, from: header)
        }
        let envelope: FaceEnvelope
        guard let kind = Kind(rawValue: tag) else { throw FaceWireError.invalidFrame }
        switch kind {
        case .feed:
            envelope = .feed(try decoder.decode(FaceBatch.self, from: header))
        case .call:
            let request = try readRequest(FaceCall.self)
            envelope = .call(id: request.id, request.value)
        case .reply:
            let request = try readRequest(FaceReply.self)
            envelope = .reply(id: request.id, request.value)
        case .act:
            let request = try readRequest(FaceAct.self)
            envelope = .act(id: request.id, request.value)
        case .actReply:
            let request = try readRequest(FaceActReply.self)
            envelope = .actReply(id: request.id, request.value)
        }
        guard table.chunks.withLock({ $0.isEmpty }) else { throw FaceWireError.invalidFrame }
        return envelope
    }
}
