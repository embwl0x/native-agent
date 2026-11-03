import Foundation
import CryptoKit
import Observation
import PersistenceCore
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import NativeAgentShared
// Blueprint: | `EmbeddingModelDownload.swift` | `EmbeddingModelDownload` actor; checked descriptor, installation ownership and resumable part reads; target commit independent of cleanup failure; only changed installs release/reconcile the resident model; retained cancellation-aware extraction through actual subprocess exit |

/// One owner task survives navigation; status surfaces observe Core's push stream.
@MainActor @Observable
public final class EmbeddingModelDownloadController {
    public static let shared = EmbeddingModelDownloadController()
    public var status = EmbeddingModelDownload.Status()
    public var activating = false
    private var lastDoctorInstallCompleted = false
    private var installCommitted = false
    private let downloader = EmbeddingModelDownload(dataRoot: PersistenceCore.defaultDataRoot())
    private var task: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    public func start(createOnly: Bool = true) {
        guard task == nil, pauseTask == nil else { return }
        lastDoctorInstallCompleted = false
        installCommitted = false
        if observation == nil {
            observation = Task {
                for await value in await downloader.updates() { status = value }
            }
        }
        task = Task {
            defer {
                observation?.cancel()
                observation = nil
                task = nil
            }
            guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else { return }
            if runtime.requestedBackend == ManagedEmbeddingProvider.mockBackend {
                _ = await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
                return
            }
            do {
                if createOnly, try await downloader.isUserPaused() { return }
                if !createOnly { try await downloader.resumeByUser() }
                if try await downloader.install(createOnly: createOnly) {
                    installCommitted = true
                    activating = true
                    // Once the verified directory has committed, a late Pause must
                    // not cancel corpus convergence and strand two vector spaces.
                    let converged = await Task.detached(priority: .utility) {
                        _ = await SwiftNativeMemoryV2.shared.releaseEmbeddingMemory(reason: "verified model installed")
                        return await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
                    }.value
                    activating = false
                    lastDoctorInstallCompleted = converged
                }
            } catch { await downloader.reportFailure(error) }
            // Read the terminal value before retiring the never-ending stream.
            status = await downloader.currentStatus()
        }
    }

    public func cancel() {
        guard let active = task, pauseTask == nil else { return }
        active.cancel()
        pauseTask = Task {
            await active.value
            if !installCommitted {
                do { try await downloader.pauseByUser() }
                catch { await downloader.reportFailure(error) }
            }
            pauseTask = nil
        }
    }

    public func doctorSnapshot() async -> EmbeddingModelDownload.Status {
        await downloader.currentStatus()
    }

    public func doctorUserPaused() async throws -> Bool { try await downloader.isUserPaused() }

    /// Doctor joins the same owner task used by the two visible rows.
    public func resumeForDoctor() async -> Bool {
        guard task == nil else { return false }
        start()
        await task?.value
        return lastDoctorInstallCompleted
    }
}

/// Downloads the standalone release without changing the serving embedding model.
/// extras/coreml and extras/.coreml-download are local installation state:
/// excluded from backup/export and phone sync, listed in PrivacyMap.
public actor EmbeddingModelDownload {
    public struct Status: Sendable {
        public var phase: String = "Not started"
        public var completed: Int64 = 0
        public var total: Int64 = 0
        public var running = false
        public var available = false
        /// Set only by this operation's target commit, never by inspection of
        /// an already-current target. Cleanup has its own outcome.
        public var installedRelease: String?
        public var cleanupFailure: String?
        public init() {}
    }

    public struct ByteRange: Sendable, Equatable {
        public let start: Int64
        public let end: Int64
        public var count: Int64 { end - start + 1 }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidRelease, invalidRange, incompletePart, digestMismatch, invalidModel, extractionFailed
        case descriptor(path: String, reason: String)
        case installation(path: String, reason: String)
        case part(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .invalidRelease: return "The embedding release descriptor is invalid."
            case .invalidRange: return "The embedding download range is invalid."
            case .incompletePart: return "An embedding download part is incomplete."
            case .digestMismatch: return "The embedding archive digest does not match its release."
            case .invalidModel: return "The embedding installation has no usable model manifest."
            case .extractionFailed: return "The embedding archive could not be extracted."
            case .descriptor(let path, let reason): return "Embedding descriptor \(path): \(reason)"
            case .installation(let path, let reason): return "Embedding installation \(path): \(reason)"
            case .part(let path, let reason): return "Embedding download part \(path): \(reason)"
            }
        }
    }

    /// nil is reserved for no configured descriptor. Configured bytes must be
    /// readable and valid; corruption never selects bundled distribution.
    public static func configuredDescriptor(at url: URL?) throws -> Descriptor? {
        guard let url else { return nil }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let length = (attrs[.size] as? NSNumber)?.int64Value, length <= 8_192 else {
                throw Failure.invalidRelease
            }
            return try Descriptor.parse(Data(contentsOf: url))
        }
        catch { throw Failure.descriptor(path: url.path, reason: error.localizedDescription) }
    }

    public static func configuredDescriptor(bundle: Bundle = .main) throws -> Descriptor? {
        try configuredDescriptor(at: bundle.url(forResource: "embedding-download", withExtension: "json"))
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
            let value = try JSONDecoder().decode(Self.self, from: data)
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
            ByteRange(start: $0, end: $0 + min(chunk - 1, size - 1 - $0))
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
            guard range.start == offset, try partByteLength(at: part) == range.count else { throw Failure.incompletePart }
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

    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                      userInfo: [NSFilePathErrorKey: url.path])
    }

    public static func partByteLength(at url: URL) throws -> Int64 {
        guard try exists(url) else { return 0 }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 0 else {
            throw Failure.part(path: url.path, reason: "Expected a regular file with a readable byte length.")
        }
        return size
    }

    private static func removeStagingArtifacts(in work: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            let archive = name == "model.zip"
                || (name.hasPrefix("model-") && name.hasSuffix(".zip")
                    && UUID(uuidString: String(name.dropFirst(6).dropLast(4))) != nil)
            let unpacked = name == "unpacked"
                || (name.hasPrefix("unpacked-")
                    && UUID(uuidString: String(name.dropFirst(9))) != nil)
            if archive || unpacked { try FileManager.default.removeItem(at: item) }
        }
    }

    public enum InstallationOwnership: Sendable {
        case absent
        case downloader(release: String)
        case unknown(reason: String)
    }

    public struct Installation: Sendable {
        public let ownership: InstallationOwnership
        public let model: CoreMLEmbeddingProvider.InstalledExtrasModel?
        public let modelFailure: String?
    }

    /// Unknown ownership cannot authorize replacement or a fabricated marker.
    public static func ownershipRepairInstruction(at target: URL) -> String {
        "Preserve \(target.path) by moving the whole directory intact to a sibling recovery name, then choose Check / resume on the Memory model download row to install the verified release. Do not invent release.sha256."
    }

    /// Ownership and manifest usability are independent checked facts. Unknown
    /// ownership preserves bytes and states the gap; it never means "custom".
    public static func inspectInstallation(at target: URL) throws -> Installation {
        guard try exists(target) else {
            return Installation(ownership: .absent, model: nil, modelFailure: nil)
        }
        let ownership: InstallationOwnership
        let marker = target.appendingPathComponent("release.sha256")
        do {
            if try exists(marker) {
                let release = try String(contentsOf: marker, encoding: .utf8)
                if release.utf8.count == 64,
                   release.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    ownership = .downloader(release: release)
                } else { ownership = .unknown(reason: "\(marker.path) is not a release SHA-256.") }
            } else { ownership = .unknown(reason: "\(marker.path) is missing.") }
        } catch { ownership = .unknown(reason: "\(marker.path): \(error.localizedDescription)") }
        do {
            let model = try CoreMLEmbeddingProvider.extrasModel(inDirectory: target)
            return Installation(ownership: ownership, model: model,
                                modelFailure: model == nil ? "\(target.path)/embedding.json is missing." : nil)
        } catch {
            return Installation(ownership: ownership, model: nil, modelFailure: error.localizedDescription)
        }
    }

    private func replacementAllowed(at target: URL, release: String, createOnly: Bool) throws -> Bool {
        let installation = try Self.inspectInstallation(at: target)
        switch installation.ownership {
        case .absent: return true
        case .unknown(let reason):
            let usability = installation.modelFailure ?? "The model manifest and artifacts passed inspection."
            throw Failure.installation(path: target.path, reason: "Installation unverified: ownership unknown; preserved unchanged. \(reason) \(usability) \(Self.ownershipRepairInstruction(at: target))")
        case .downloader(let installed):
            if installed == release, installation.model != nil {
                publish("Memory model up to date")
                nativeLog("[embedding-download] Memory model up to date; installation unchanged")
                return false
            }
            if createOnly {
                let detail = installation.modelFailure ?? "Installed release \(installed) differs from requested release \(release)."
                throw Failure.installation(path: target.path, reason: "Existing installation needs explicit Check / resume; preserved unchanged. \(detail)")
            }
            return true
        }
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

    public func currentStatus() -> Status { status }

    private func pauseMarker() throws -> URL? {
        guard let descriptor = try Self.configuredDescriptor(at: descriptorURL),
              descriptor.distribution == "separate-download" else { return nil }
        return root.appendingPathComponent("extras/.coreml-download/user-paused-\(descriptor.sha256)")
    }

    public func isUserPaused() throws -> Bool {
        guard let marker = try pauseMarker() else { return false }
        return try Self.exists(marker)
    }

    public func pauseByUser() throws {
        guard let marker = try pauseMarker() else { return }
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        if try !Self.exists(marker) {
            guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else {
                throw Failure.invalidRelease
            }
        }
    }

    public func resumeByUser() throws {
        guard let marker = try pauseMarker(), try Self.exists(marker) else { return }
        try FileManager.default.removeItem(at: marker)
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func reportFailure(_ error: Error) {
        publish(error is CancellationError ? "Download paused" : "Download failed: \(error.localizedDescription)")
    }
    private func publish(_ phase: String? = nil, bytes: Int64 = 0) {
        if let phase { status.phase = phase }
        status.completed += bytes
        for observer in observers.values { observer.yield(status) }
    }

    /// A release digest names the resume directory, so changed assets cannot reuse old bytes.
    /// Completed 1 MiB subranges survive cancellation, failures, and process restarts.
    /// True only when this invocation commits a replacement/new target.
    public func install(createOnly: Bool = false) async throws -> Bool {
        guard !status.running else { return false }
        guard let descriptorURL else {
            nativeLog("[embedding-download] No bundled descriptor; download not required")
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
            guard let descriptor = try Self.configuredDescriptor(at: descriptorURL) else { throw Failure.invalidRelease }
            guard descriptor.distribution == "separate-download" else {
                status.available = false
                publish("Memory model bundled")
                return false
            }
            let sha = descriptor.sha256
            let size = descriptor.byteLength
            let extras = root.appendingPathComponent("extras", isDirectory: true)
            let target = extras.appendingPathComponent("coreml", isDirectory: true)
            guard try replacementAllowed(at: target, release: sha, createOnly: createOnly) else {
                return false
            }
            let work = extras.appendingPathComponent(".coreml-download/\(sha)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Self.removeStagingArtifacts(in: work)
            let invalidParts = work.appendingPathComponent("invalid-parts")
            if FileManager.default.fileExists(atPath: invalidParts.path) { throw Failure.digestMismatch }
            let ranges = Self.ranges(size: size)
            let parts = ranges.indices.map { work.appendingPathComponent("part-\($0)") }
            status.total = size
            for (part, range) in zip(parts, ranges) {
                let have = try Self.partByteLength(at: part)
                if have > range.count {
                    if createOnly { throw Failure.invalidRange }
                    try FileManager.default.removeItem(at: part)
                }
                else { status.completed += have }
            }
            publish("Downloading memory model…")
            let url = descriptor.url
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (part, range) in zip(parts, ranges) {
                    group.addTask {
                        var have = try Self.partByteLength(at: part)
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
                            if try !Self.exists(part) {
                                guard have == 0, FileManager.default.createFile(atPath: part.path, contents: nil) else {
                                    throw Failure.part(path: part.path, reason: "The checked part disappeared or could not be created.")
                                }
                            }
                            let output = try FileHandle(forWritingTo: part)
                            do {
                                guard try output.seekToEnd() == UInt64(have) else {
                                    throw Failure.part(path: part.path, reason: "Byte length changed before append.")
                                }
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
                // Preserve suspect bytes for a deliberate recovery decision.
                FileManager.default.createFile(atPath: invalidParts.path, contents: Data())
                throw Failure.digestMismatch
            }
            try Task.checkCancellation()
            publish("Installing memory model…")
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            #if os(macOS)
            let extraction = Extraction(archive: archive, destination: unpacked)
            guard try await extraction.run() == 0 else { throw Failure.extractionFailed }
            #else
            throw Failure.extractionFailed
            #endif
            let candidate = unpacked.appendingPathComponent("embedding", isDirectory: true)
            guard try CoreMLEmbeddingProvider.extrasModel(inDirectory: candidate) != nil else { throw Failure.invalidModel }
            try sha.write(to: candidate.appendingPathComponent("release.sha256"), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            // A manual installation may have arrived while the transfer awaited.
            guard try replacementAllowed(at: target, release: sha, createOnly: createOnly) else {
                return false
            }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: candidate)
            } else {
                try FileManager.default.moveItem(at: candidate, to: target)
            }
            // This is the target commit boundary. Optional cleanup cannot
            // change the result or suppress the controller's convergence.
            status.installedRelease = sha
            publish("Memory model installed")
            do { try FileManager.default.removeItem(at: work) }
            catch {
                status.cleanupFailure = "\(work.path): \(error.localizedDescription)"
                nativeLog("[embedding-download] Installed %@; staging cleanup failed: %@", sha, error.localizedDescription)
                publish("Memory model installed; staging cleanup failed: \(error.localizedDescription)")
            }
            return true
        } catch Failure.digestMismatch {
            publish("Download failed: archive digest mismatch")
            throw Failure.digestMismatch
        } catch {
            publish(Task.isCancelled ? "Download paused" : "Download failed: \(error.localizedDescription)")
            throw error
        }
    }
}

#if os(macOS)
private extension EmbeddingModelDownload {
    /// The install flight retains this child until actual exit. Cancellation
    /// kills extraction before install's staging cleanup can remove its files.
    final class Extraction: @unchecked Sendable {
        private struct State {
            var cancelled = false
            var continuation: CheckedContinuation<Int32, Error>?
        }
        private let state = Mutex(State())
        private let process = Process()

        init(archive: URL, destination: URL) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
        }

        func run() async throws -> Int32 {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    state.withLock { state in
                        guard !state.cancelled else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        state.continuation = continuation
                        process.terminationHandler = { [weak self] child in
                            self?.finish(status: child.terminationStatus)
                        }
                        do { try process.run() }
                        catch {
                            process.terminationHandler = nil
                            state.continuation = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                self.state.withLock { state in
                    state.cancelled = true
                    // Start and cancel share the lock, including cancellation
                    // before launch. Never report exit while ditto is writing.
                    if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                }
            }
            try Task.checkCancellation()
            return result
        }

        private func finish(status: Int32) {
            let continuation = state.withLock { state in
                defer { state.continuation = nil }
                process.terminationHandler = nil
                return state.continuation
            }
            continuation?.resume(returning: status)
        }
    }
}
#endif
