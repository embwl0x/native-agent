import Foundation
import Dispatch
import Darwin
// Blueprint: | `FaceLink.swift` | Ordered asynchronous binary property-list framing over parent/child pipe handles |

extension FaceLink {
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
                            let decoder = PropertyListDecoder()
                            guard let key = CodingUserInfoKey.faceValueRegistry else { throw FaceWireError.registryConfiguration }
                            decoder.userInfo[key] = registry
                            continuation.yield(try decoder.decode(FaceEnvelope.self, from: data))
                        }
                    }
                    try frames.finish()
                    await lifetime.end(FaceWireError.disconnected, reachedEOF: true)
                    continuation.finish()
                } catch {
                    await lifetime.end(error)
                    continuation.finish(throwing: error)
                }
                io.close()
            }
            continuation.onTermination = { _ in io.close() }
        }

        deinit {
            reader.cancel()
            io.close()
            Task { [lifetime] in await lifetime.end(FaceWireError.disconnected) }
            for write in pending { write.continuation.resume(throwing: FaceWireError.disconnected) }
        }

        /// Clean input EOF is known before the consumer finishes draining buffered envelopes.
        public var reachedEOF: Bool {
            get async { await lifetime.reachedEOF }
        }

        /// Completion means bytes reached the pipe; only a correlated reply establishes the other process's outcome.
        public func send(_ envelope: FaceEnvelope) async throws {
            try Task.checkCancellation()
            if let failure { throw failure }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let key = CodingUserInfoKey.faceValueRegistry else { throw FaceWireError.registryConfiguration }
            encoder.userInfo[key] = registry
            let payload = try encoder.encode(envelope)
            guard !payload.isEmpty else {
                throw FaceWireError.invalidFrameLength(UInt64(payload.count))
            }
            var length = UInt64(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(payload)
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pending.append(Write(id: id, data: frame, continuation: continuation))
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

        /// One forwarding task owns this sink until cancellation, pipe failure or source closure.
        public func forward(_ source: FaceFeedSource) async throws {
            let sink = try await lifetime.attach(source)
            do {
                for try await batch in sink.batches {
                    try Task.checkCancellation()
                    try await send(.feed(batch))
                }
                try Task.checkCancellation()
                await lifetime.detach(sink.epoch, cause: FaceWireError.disconnected)
            } catch {
                await lifetime.detach(sink.epoch, cause: error)
                throw error
            }
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
                    try await io.write(write.data)
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
            await lifetime.end(cause)
        }

        private struct Write: Sendable {
            let id: UUID
            let data: Data
            let continuation: CheckedContinuation<Void, Error>
        }
    }

}

private actor FaceLinkLifetime {
    private var sources: [UUID: FaceFeedSource] = [:]
    private var termination: (cause: any Error, reachedEOF: Bool)?

    var reachedEOF: Bool { termination?.reachedEOF == true }

    func attach(_ source: FaceFeedSource) async throws -> FaceFeedSink {
        if let termination { throw termination.cause }
        let sink = await source.attachSink()
        if let termination {
            await source.detachSink(sink.epoch, cause: termination.cause)
            throw termination.cause
        }
        sources[sink.epoch] = source
        return sink
    }

    func detach(_ epoch: UUID, cause: any Error) async {
        guard let source = sources.removeValue(forKey: epoch) else { return }
        await source.detachSink(epoch, cause: cause)
    }

    func end(_ cause: any Error, reachedEOF: Bool = false) async {
        guard termination == nil else { return }
        termination = (cause, reachedEOF)
        let attached = sources
        sources.removeAll()
        for (epoch, source) in attached { await source.detachSink(epoch, cause: cause) }
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

    func write(_ data: Data) async throws {
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            if length == nil {
                guard buffer.count >= 8 else { return frames }
                let count = buffer.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard count > 0, let size = Int(exactly: count) else {
                    throw FaceWireError.invalidFrameLength(count)
                }
                buffer.removeFirst(8)
                length = size
            }
            guard let length, buffer.count >= length else { return frames }
            frames.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length)
            self.length = nil
        }
    }

    func finish() throws {
        guard buffer.isEmpty, length == nil else { throw FaceWireError.truncatedFrame }
    }
}
