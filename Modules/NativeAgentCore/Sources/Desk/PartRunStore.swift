import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `PartRunStore.swift` | HMAC-sealed checkpoints under skills/runs; stamps new saves with DataRootLife, reads cross-life journals stopped/restored; explicit Resume runs fresh without the old journal. Desk expiry/MyQueue closure, retention/discard and SwiftNativeManifestSigner signing remain here |

/// Stopped part runs, kept to resume: one file each under skills/runs in
/// the data root, sealed (`seal`), at most 256 KB, the newest 50.
/// Local backup/export include skills/; phone sync excludes runs; PrivacyMap lists skills.
/// The seal stops edits, not a local writer: whoever can write the data root can read the 0600 key beside it.
public enum PartRunStore {
    public static let keep = 50
    public static let byteLimit = 256 * 1024

    private static func file(_ id: String, root: URL) -> URL {
        root.appendingPathComponent("skills/runs/\(id).json")
    }

    public static func exists(_ id: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(id, root: root).path)
    }

    public static func discard(_ id: String, root: URL) {
        try? FileManager.default.removeItem(at: file(id, root: root))
    }

    public static func waitingIDs(root: URL) throws -> [String] {
        let paths: [URL]
        do { paths = try FileManager.default.contentsOfDirectory(at: file("", root: root).deletingLastPathComponent(), includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        return paths.filter { $0.lastPathComponent.range(of: "^run-[0-9a-f]{8}\\.json$", options: .regularExpression) != nil }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public static func save(_ run: [String: JSONValue], id: String, root: URL) async -> Bool {
        let fm = FileManager.default
        let url = file(id, root: root)
        var run = run
        if run["lifeID"] == nil {
            guard let life = try? DataRootLife.current(in: root) else { return false }
            run["lifeID"] = .string(life)
        }
        guard let mac = await seal(run, root: root) else { return false }
        run["seal"] = .string(mac)
        guard let data = try? JSONValue.object(run).serializedData(pretty: false), data.count <= byteLimit,
              (try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              (try? data.write(to: url, options: .atomic)) != nil else { return false }
        let runs = (try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = runs.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in newest.dropFirst(keep) { try? fm.removeItem(at: old) }
        return true
    }

    /// A same-life run is claimed by rename, then its seal checked again.
    /// A stopped prior life is kept; Resume starts fresh instead of replaying it.
    public static func take(_ id: String, root: URL) async -> [String: JSONValue]? {
        guard let run = await read(id, root: root) else { return nil }
        if run["status"] == .string("stopped"), run["reason"] == .string(DataRootLife.stoppedReason) { return run }
        let fm = FileManager.default
        let claimed = file(id, root: root).deletingPathExtension().appendingPathExtension("\(UUID().uuidString).claimed")
        guard (try? fm.moveItem(at: file(id, root: root), to: claimed)) != nil else { return nil }
        defer { try? fm.removeItem(at: claimed) }
        return await read(id, at: claimed, root: root)
    }

    /// A waiting run as it is kept, its seal checked, claiming nothing.
    public static func read(_ id: String, at url: URL? = nil, root: URL) async -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: url ?? file(id, root: root)), case .object(let run)? = try? JSONValue.parse(data),
              run["run_id"] == .string(id), case .string(let held)? = run["seal"], let mac = await seal(run, root: root),
              held.utf8.count == mac.utf8.count,
              zip(held.utf8, mac.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        guard let life = try? DataRootLife.current(in: root) else { return nil }
        var projected = run
        if DataRootLife.life(of: run["lifeID"]) != life {
            projected["status"] = .string("stopped")
            projected["reason"] = .string(DataRootLife.stoppedReason)
        }
        return projected
    }

    /// HMAC-SHA256 over the run's body (all of it but its seal), keyed by the
    /// install's signing key bound to this one use, so no tool manifest's
    /// signature ever verifies as a run, nor a run's as a manifest.
    static func seal(_ run: [String: JSONValue], root: URL) async -> String? {
        guard let base = try? await SwiftNativeManifestSigner(dataRoot: root).loadOrCreateSigningKey(),
              let body = try? JSONValue.object(run.filter { $0.key != "seal" }).serializedData(pretty: false) else { return nil }
        let key = HMAC<SHA256>.authenticationCode(for: Data("nativeagent.skill_run.v1".utf8), using: SymmetricKey(data: base))
        return HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(key)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
