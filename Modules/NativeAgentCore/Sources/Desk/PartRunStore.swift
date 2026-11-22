import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Synchronization
import TrustCenter
// Blueprint: | `PartRunStore.swift` | Sealed bounded checkpoints; rename claims bytes until explicit settlement |

/// Seal bounded resumable checkpoints, retaining at most 50 waiting runs.
/// The key prevents accidental edits, not a writer that controls the data root.
/// Local export retains runs; phone sync excludes them.
public enum PartRunStore {
    public static let keep = 50
    public static let byteLimit = 256 * 1024

    private static func file(_ id: String, root: URL) -> URL {
        root.appendingPathComponent("skills/runs/\(id).json")
    }

    private static func claimedFile(_ id: String, root: URL) -> URL {
        file(id, root: root).deletingPathExtension().appendingPathExtension("claimed")
    }

    private static func present(_ url: URL) throws -> Bool {
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw failure("run_checkpoint_invalid", "Checkpoint is not a regular file at \(url.path).", at: url)
            }
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return false }
        catch let error as ToolFailureError { throw error }
        catch { throw failure("run_presence_unavailable", "Checkpoint presence at \(url.path) could not be read: \(error.localizedDescription).", at: url) }
    }

    public static func exists(_ id: String, root: URL) throws -> Bool {
        try ClaimOwnership.withLocations {
            let waiting = try present(file(id, root: root))
            let claimed = try present(claimedFile(id, root: root))
            return waiting || claimed
        }
    }

    /// Discard waiting bytes. Moving claimed bytes requires claim ownership.
    public static func discard(_ id: String, root: URL) throws {
        _ = try discardWaiting(at: file(id, root: root))
    }

    private static func discardWaiting(at url: URL) throws -> Bool {
        do { try FileManager.default.removeItem(at: url); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return false }
        catch { throw failure("run_cleanup_failed", "Checkpoint cleanup at \(url.path) failed: \(error.localizedDescription).", at: url) }
    }

    public static func waitingIDs(root: URL) throws -> [String] {
        let paths: [URL]
        let directory = file("", root: root).deletingLastPathComponent()
        do { paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        catch { throw failure("run_inventory_unavailable", "Saved-run inventory at \(directory.path) could not be read: \(error.localizedDescription).",
            at: directory) }
        return paths.filter { $0.lastPathComponent.range(of: "^run-[0-9a-f]{8}\\.json$", options: .regularExpression) != nil }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public static func save(_ run: [String: JSONValue], id: String, root: URL) async throws {
        let fm = FileManager.default
        let url = file(id, root: root)
        do {
            var run = run
            if run["lifeID"] == nil {
                let life = try DataRootLife.current(in: root)
                run["lifeID"] = .string(life)
            }
            let mac = try await seal(run, root: root)
            run["seal"] = .string(mac)
            let data = try JSONValue.object(run).serializedData(pretty: false)
            guard data.count <= byteLimit else {
                throw failure("run_checkpoint_too_large", "Checkpoint exceeds \(byteLimit) bytes; nothing was saved.", at: url)
            }
            try ClaimOwnership.withLocations {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
                do {
                    let runs = try fm.contentsOfDirectory(at: url.deletingLastPathComponent(),
                        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                        .filter { $0.lastPathComponent != url.lastPathComponent
                            && $0.lastPathComponent.range(of: "^run-[0-9a-f]{8}\\.json$", options: .regularExpression) != nil }
                    let newest = try runs.map { path -> (URL, Date) in
                        let properties = try path.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                        guard properties.isRegularFile == true, let date = properties.contentModificationDate else {
                            throw failure("run_retention_unavailable", "Checkpoint modification time is unavailable at \(path.path).", at: path)
                        }
                        return (path, date)
                    }.sorted { $0.1 > $1.1 }
                    for (old, _) in newest.dropFirst(keep - 1) { try fm.removeItem(at: old) }
                } catch {
                    throw failure("run_retention_failed", "Checkpoint was saved at \(url.path), but retention failed: \(error.localizedDescription).",
                        at: url, effects: .occurred)
                }
            }
        } catch let error as ToolFailureError { throw error }
        catch { throw failure("run_save_failed",
            "Checkpoint save at \(url.path) failed: \(error.localizedDescription). Inspect the path to reconcile whether the write committed.", at: url,
            effects: .unknown) }
    }

    /// A live claim and an explicit drop cannot own the same checkpoint at once.
    final class ClaimOwnership: Sendable {
        private static let owned = Mutex(Set<URL>())
        let waiting: URL
        let claimed: URL

        init(_ id: String, root: URL) throws {
            let root = root.standardizedFileURL
            let url = claimedFile(id, root: root)
            guard Self.owned.withLock({ $0.insert(url).inserted }) else {
                throw failure("run_claim_busy", "Run \(id) already has a live claim or drop. Try again after it settles.", at: url)
            }
            waiting = file(id, root: root)
            claimed = url
        }

        // A reservation read cannot straddle a move between the two retained locations.
        static func withLocations<T: Sendable>(_ body: () throws -> T) rethrows -> T {
            try owned.withLock { _ in try body() }
        }

        deinit {
            _ = Self.owned.withLock { $0.remove(claimed) }
        }

        /// Retire an ownerless claim without erasing the record of what may have run.
        @discardableResult
        func abandon() throws -> Bool {
            guard try present(claimed) else { return try discardWaiting(at: waiting) }
            let evidence = claimed.deletingPathExtension().appendingPathExtension("abandoned")
            do { try FileManager.default.moveItem(at: claimed, to: evidence) }
            catch {
                throw failure("run_abandon_failed", "Could not preserve the abandoned checkpoint at \(evidence.path): \(error.localizedDescription).",
                              at: claimed)
            }
            _ = try discardWaiting(at: waiting)
            return true
        }
    }

    public struct Claim: Sendable {
        public let run: [String: JSONValue]
        private let ownership: ClaimOwnership
        public var path: String { ownership.claimed.path }
        fileprivate init(run: [String: JSONValue], ownership: ClaimOwnership) {
            self.run = run
            self.ownership = ownership
        }
        public func consume() throws {
            let claimed = ownership.claimed
            do { try FileManager.default.removeItem(at: claimed) }
            catch { throw PartRunStore.failure("run_cleanup_failed", "Could not consume checkpoint at \(claimed.path): \(error.localizedDescription).",
                at: claimed) }
        }
        public func release() throws {
            try PartRunStore.release(ownership.claimed, to: ownership.waiting)
        }
    }

    private static func release(_ claimed: URL, to waiting: URL) throws {
        do { try ClaimOwnership.withLocations { try FileManager.default.moveItem(at: claimed, to: waiting) } }
        catch { throw failure("run_release_failed",
            "Could not release checkpoint at \(claimed.path): \(error.localizedDescription). Its bytes remain claimed.", at: claimed) }
    }

    /// Claim one byte image before reading. Transient admission failures return it to waiting.
    public static func take(_ id: String, root: URL) async throws -> Claim {
        let ownership = try ClaimOwnership(id, root: root)
        let (waiting, claimed) = (ownership.waiting, ownership.claimed)
        do { try ClaimOwnership.withLocations { try FileManager.default.moveItem(at: waiting, to: claimed) } }
        catch { throw failure("run_claim_failed",
            "Could not claim \(waiting.path): \(error.localizedDescription). Inspect both waiting and claimed checkpoints.", at: claimed) }
        do {
            let run = try await read(id, at: claimed, root: root)
            try Task.checkCancellation()
            return Claim(run: run, ownership: ownership)
        } catch {
            let admission = error
            if let failure = admission as? ToolFailureError, let code = failure.code,
               ["run_checkpoint_invalid", "run_seal_invalid"].contains(code) {
                throw failure
            }
            throw await settle { () -> any Error in
                do {
                    try release(ownership.claimed, to: waiting)
                } catch {
                    return failure("run_release_failed", "\(admission.localizedDescription) \(error.localizedDescription)", at: claimed)
                }
                if admission is CancellationError { return admission }
                let code = (admission as? ToolFailureError)?.code ?? "run_validation_failed"
                return failure(code, "\(admission.localizedDescription) The checkpoint is waiting at \(waiting.path).", at: waiting)
            }
        }
    }

    /// Validate waiting bytes without claiming them so inspection cannot consume resumable work.
    public static func read(_ id: String, at url: URL? = nil, root: URL) async throws -> [String: JSONValue] {
        let url = url ?? file(id, root: root)
        do {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw failure("run_read_failed", "Checkpoint at \(url.path) could not be read: \(error.localizedDescription).", at: url) }
            guard data.count <= byteLimit, case .object(let run)? = try? JSONValue.parse(data),
                  run["run_id"] == .string(id), case .string(let held)? = run["seal"] else {
                throw failure("run_checkpoint_invalid", "Checkpoint at \(url.path) has invalid size, identity or seal fields. Its bytes were preserved.",
                    at: url)
            }
            let mac = try await seal(run, root: root)
            guard
                  held.utf8.count == mac.utf8.count,
                  zip(held.utf8, mac.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                throw failure("run_seal_invalid", "Checkpoint seal at \(url.path) does not verify. Its bytes were preserved.", at: url)
            }
            let life = try DataRootLife.current(in: root)
            var projected = run
            if DataRootLife.life(of: run["lifeID"]) != life {
                projected["status"] = .string("stopped")
                projected["reason"] = .string(DataRootLife.stoppedReason)
            }
            return projected
        } catch let error as ToolFailureError { throw error }
        catch { throw failure("run_validation_failed",
            "Checkpoint validation at \(url.path) failed: \(error.localizedDescription). Its bytes were preserved.", at: url) }
    }

    /// Bind HMAC to the run domain so manifest signatures cannot authenticate checkpoints or vice versa.
    static func seal(_ run: [String: JSONValue], root: URL) async throws -> String {
        let base = try await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey()
        let body = try JSONValue.object(run.filter { $0.key != "seal" }).serializedData(pretty: false)
        let key = HMAC<SHA256>.authenticationCode(for: Data("nativeagent.skill_run.v1".utf8), using: SymmetricKey(data: base))
        return HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(key)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ code: String, _ message: String, at url: URL, effects: ToolFailureError.Effects = .none) -> ToolFailureError {
        ToolFailureError(message, effects: effects, owner: url.path, code: code,
            instruction: "Inspect the checkpoint at this path and its affected state; repair this owner before resuming. Do not repeat completed effects.",
            recovery: .inspect)
    }
}
