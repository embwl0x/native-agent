import Foundation
import CryptoKit

/// Downloads the standalone release without changing the serving embedding model.
public actor EmbeddingModelDownload {
    public struct Status: Sendable {
        public var phase: String = "Not started"
        public var completed: Int64 = 0
        public var total: Int64 = 0
        public var running = false
        public var available = false
        public init() {}
    }

    public struct ByteRange: Sendable, Equatable {
        public let start: Int64
        public let end: Int64
        public var count: Int64 { end - start + 1 }
    }

    public enum Failure: Error, Equatable {
        case invalidRelease, invalidRange, incompletePart, digestMismatch, invalidModel, extractionFailed
    }

    /// The release packager's embedding-download.json is the only download authority.
    public struct Descriptor: Decodable, Sendable {
        public let url: URL
        public let sha256: String
        public let byteLength: Int64
        public let distribution: String
        private let schemaVersion: Int
        private let archiveRoot: String

        enum CodingKeys: String, CodingKey {
            case url, sha256, distribution
            case byteLength = "byte_length", schemaVersion = "schema_version", archiveRoot = "archive_root"
        }

        public static func parse(_ data: Data) throws -> Descriptor {
            let value: Descriptor
            do { value = try JSONDecoder().decode(Self.self, from: data) }
            catch { throw Failure.invalidRelease }
            guard value.schemaVersion == 1, value.archiveRoot == "embedding",
                  ["separate-download", "bundled"].contains(value.distribution),
                  value.url.scheme == "https", value.url.host?.isEmpty == false,
                  value.byteLength > 0, value.sha256.utf8.count == 64,
                  value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw Failure.invalidRelease }
            return value
        }
    }

    public static func ranges(size: Int64, parts: Int = 48) -> [ByteRange] {
        guard size > 0, parts > 0 else { return [] }
        let chunk = (size - 1) / Int64(parts) + 1
        return stride(from: Int64(0), to: size, by: Int(chunk)).map {
            ByteRange(start: $0, end: min(size - 1, $0 + chunk - 1))
        }
    }

    /// Size and digest are both gates; callers may activate only after this returns.
    public static func assemble(parts: [URL], ranges: [ByteRange], destination: URL, sha256: String) throws {
        guard parts.count == ranges.count, !parts.isEmpty else { throw Failure.incompletePart }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        var hash = SHA256()
        var offset: Int64 = 0
        for (part, range) in zip(parts, ranges) {
            try Task.checkCancellation()
            guard range.start == offset, try fileSize(part) == range.count else { throw Failure.incompletePart }
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
            }
            offset = range.end + 1
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { throw Failure.digestMismatch }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// An absent installation may download; existing directories require positive
    /// downloader ownership before any replacement, including incomplete models.
    static func preservesCustomInstallation(at target: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        guard let marker = try? String(contentsOf: target.appendingPathComponent("release.sha256"), encoding: .utf8),
              marker.utf8.count == 64,
              marker.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return true }
        return false
    }

    private let root: URL
    private let descriptorURL: URL?
    private var status = Status()
    private var observers: [UUID: AsyncStream<Status>.Continuation] = [:]
    public init(dataRoot: URL, bundle: Bundle = .main) {
        root = dataRoot
        descriptorURL = bundle.url(forResource: "embedding-download", withExtension: "json")
        status.available = descriptorURL != nil
    }

    public func updates() -> AsyncStream<Status> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish(_ phase: String? = nil, bytes: Int64 = 0) {
        if let phase { status.phase = phase }
        status.completed += bytes
        for observer in observers.values { observer.yield(status) }
    }

    /// A release digest names the resume directory, so changed assets cannot reuse old bytes.
    /// Completed 1 MiB subranges survive cancellation, failures, and process restarts.
    public func install() async throws -> Bool {
        guard !status.running else { return false }
        guard let descriptorURL else {
            NSLog("[embedding-download] No bundled descriptor; download not required")
            return false
        }
        status = Status()
        status.available = true
        status.running = true
        publish("Checking memory model…")
        defer { status.running = false; publish() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 48
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let descriptor = try Descriptor.parse(Data(contentsOf: descriptorURL))
            guard descriptor.distribution == "separate-download" else {
                status.available = false
                publish("Memory model bundled")
                return false
            }
            let sha = descriptor.sha256
            let size = descriptor.byteLength
            let extras = root.appendingPathComponent("extras", isDirectory: true)
            let target = extras.appendingPathComponent("coreml", isDirectory: true)
            let marker = target.appendingPathComponent("release.sha256")
            if Self.preservesCustomInstallation(at: target) {
                publish("Custom memory model in use")
                return false
            }
            if (try? String(contentsOf: marker, encoding: .utf8)) == sha,
               CoreMLEmbeddingProvider.extrasModel(inDirectory: target) != nil {
                publish("Memory model up to date")
                return false
            }
            let work = extras.appendingPathComponent(".coreml-download/\(sha)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let ranges = Self.ranges(size: size)
            let parts = ranges.indices.map { work.appendingPathComponent("part-\($0)") }
            status.total = size
            for (part, range) in zip(parts, ranges) {
                let have = (try? Self.fileSize(part)) ?? 0
                if have > range.count { try FileManager.default.removeItem(at: part) }
                else { status.completed += have }
            }
            publish("Downloading memory model…")
            let url = descriptor.url
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (part, range) in zip(parts, ranges) {
                    group.addTask {
                        var have = (try? Self.fileSize(part)) ?? 0
                        while have < range.count {
                            try Task.checkCancellation()
                            let start = range.start + have
                            let end = min(range.end, start + 1_048_575)
                            var request = URLRequest(url: url)
                            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                            let (bytes, response) = try await session.data(for: request)
                            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                                  http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(size)",
                                  bytes.count == Int(end - start + 1)
                            else { throw Failure.invalidRange }
                            try Task.checkCancellation()
                            if !FileManager.default.fileExists(atPath: part.path) {
                                FileManager.default.createFile(atPath: part.path, contents: nil)
                            }
                            let output = try FileHandle(forWritingTo: part)
                            do {
                                try output.seekToEnd()
                                try output.write(contentsOf: bytes)
                                try output.close()
                            } catch { try? output.close(); throw error }
                            have += Int64(bytes.count)
                            await self.publish(bytes: Int64(bytes.count))
                        }
                    }
                }
                try await group.waitForAll()
            }
            publish("Verifying memory model…")
            let archive = work.appendingPathComponent("model.zip")
            do {
                try Self.assemble(parts: parts, ranges: ranges, destination: archive, sha256: sha)
            } catch Failure.digestMismatch {
                // A corrupt completed part must not poison every future resume.
                try FileManager.default.removeItem(at: work)
                throw Failure.digestMismatch
            }
            try Task.checkCancellation()
            publish("Installing memory model…")
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            if FileManager.default.fileExists(atPath: unpacked.path) { try FileManager.default.removeItem(at: unpacked) }
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, unpacked.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.extractionFailed }
            #else
            throw Failure.extractionFailed
            #endif
            let candidate = unpacked.appendingPathComponent("embedding", isDirectory: true)
            guard CoreMLEmbeddingProvider.extrasModel(inDirectory: candidate) != nil else { throw Failure.invalidModel }
            try sha.write(to: candidate.appendingPathComponent("release.sha256"), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            // A manual installation may have arrived while the transfer awaited.
            if Self.preservesCustomInstallation(at: target) {
                publish("Custom memory model in use")
                return false
            }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: candidate)
            } else {
                try FileManager.default.moveItem(at: candidate, to: target)
            }
            try? FileManager.default.removeItem(at: work)
            publish("Memory model installed")
            return true
        } catch {
            publish(Task.isCancelled ? "Download paused" : "Download failed: \(error.localizedDescription)")
            throw error
        }
    }
}
