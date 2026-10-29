import NativeAgentCore
import Foundation
import NativeAgentShared
import PersistenceCore
import Darwin
// Blueprint: | `ProcedureRetention.swift` | ProcedureArtifactStore root-scoped retention flight, reference-locked artifact sweeping and orphan lock reclamation |

extension ProcedureArtifactStore {
    private static let retention = Retention()

    /// The engine opens/closes one root; store instances only request its flight.
    private actor Retention {
        struct Root {
            let id = UUID()
            var open = true
            var owed: ProcedureArtifactStore?
            var flight: Task<Void, Never>?
        }
        var roots: [String: Root] = [:]

        func start(_ key: String) {
            if roots[key] == nil { roots[key] = Root() }
        }

        func request(_ store: ProcedureArtifactStore, key: String) {
            guard roots[key]?.open == true else { return }
            roots[key]?.owed = store
            guard roots[key]?.flight == nil, let id = roots[key]?.id else { return }
            roots[key]?.flight = Task.detached(priority: .utility) {
                while let store = await self.claim(key, id: id) {
                    _ = await store.sweepUnreferencedArtifacts()
                }
            }
        }

        func claim(_ key: String, id: UUID) -> ProcedureArtifactStore? {
            guard roots[key]?.id == id else { return nil }
            guard roots[key]?.open == true, !Task.isCancelled, let store = roots[key]?.owed else {
                roots[key]?.flight = nil
                return nil
            }
            roots[key]?.owed = nil
            return store
        }

        func stop(_ key: String) async {
            // Termination is terminal, including a launch continuation that
            // reaches start after this stop closed admission.
            if roots[key] == nil { roots[key] = Root() }
            guard let root = roots[key] else { return }
            roots[key]?.open = false
            roots[key]?.owed = nil
            root.flight?.cancel()
            await root.flight?.value
        }
    }

    private static func retentionKey(_ dataRoot: URL) -> String {
        dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func startRetention(dataRoot: URL) async { await retention.start(retentionKey(dataRoot)) }
    public static func stopRetention(dataRoot: URL) async { await retention.stop(retentionKey(dataRoot)) }

    /// Retention keeps installed artifacts below the admission ceiling.
    static let maxInstalledArtifacts = 1_024
    static let artifactRetentionTarget = 768
    /// Unreferenced artifacts become sweep-eligible after this file age.
    static let artifactRetentionAge: TimeInterval = 30 * 24 * 60 * 60

    /// Retention removes valid, unreferenced artifacts by age or oldest-first to its target.
    /// Active pointers and recent invocation receipts protect artifacts, including manual ones.
    /// Invalid artifacts stay put; unreadable pointers or invocation ledgers abort the sweep.
    /// GC failures never break install or discovery.
    /// One root-scoped, engine-owned flight; a request during a pass earns
    /// one more pass, including requests from another store instance.
    func requestRetentionSweep() async {
        let dataRoot = root.deletingLastPathComponent().deletingLastPathComponent()
        await Self.retention.request(self, key: Self.retentionKey(dataRoot))
    }

    @discardableResult
    public nonisolated func sweepUnreferencedArtifacts(now: Date = Date()) async -> Int {
        let invocationPath = root.appendingPathComponent("invocations.jsonl")
        do {
            return try await SwiftNativePersistenceCore.withFileLock(invocationPath) {
                await sweepUnreferencedArtifactsWithReferencesLocked(now: now)
            }
        } catch {
            nativeLog("ProcedureArtifactStore: retention sweep could not acquire reference lock: %@",
                      error.localizedDescription)
            return 0
        }
    }

    // The same ledger lock excludes activation publication and invocation
    // references across this entire eligibility snapshot and deletion pass,
    // including across store instances. Actor isolation alone cannot do that.
    private nonisolated func sweepUnreferencedArtifactsWithReferencesLocked(now: Date) async -> Int {
        guard !Task.isCancelled else { return 0 }
        let fm = FileManager.default
        let artifactsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: artifactsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        let urls = entries.filter { $0.pathExtension == "json" }
        let invocationLocks = Dictionary(grouping: entries.filter {
            $0.pathExtension == "lock" && ProcedureTrajectoryExtractor.isOpaqueIdentity($0.deletingPathExtension().pathExtension)
        }, by: { $0.deletingPathExtension().deletingPathExtension() })

        let cutoff = now.addingTimeInterval(-Self.artifactRetentionAge)

        // Referenced set: artifactIDs named by the active pointers. An
        // undecodable pointer aborts the sweep (fail-safe).
        var referenced = Set<String>()
        let activeDirectory = root.appendingPathComponent("active", isDirectory: true)
        let pointerURLs: [URL]
        do {
            pointerURLs = try fm.contentsOfDirectory(
                at: activeDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            pointerURLs = []
        } catch {
            return 0
        }
        for url in pointerURLs where url.pathExtension == "json" {
            guard let pointer = try? Self.checkedActivationPointer(url) else { return 0 }
            referenced.insert(pointer.artifactID)
        }

        // The same checked reader serves invocation and retention. Incomplete
        // reference coverage cannot establish that any artifact is unreferenced.
        do {
            for receipt in try await loadInvocationReceipts() {
                if let requested = Self.parsedTimestamp(receipt.requestedAt),
                   requested >= cutoff {
                    referenced.insert(receipt.artifactID)
                }
            }
        } catch {
            nativeLog("ProcedureArtifactStore: retention preserved artifacts; invocations.jsonl reference read failed: %@",
                      error.localizedDescription)
            return 0
        }
        struct Candidate {
            let url: URL
            let modified: Date
        }
        var candidates: [Candidate] = []
        for url in urls {
            guard !Task.isCancelled else { return 0 }
            let id = url.deletingPathExtension().lastPathComponent
            guard !referenced.contains(id),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let artifact = try? await load(id),
                  !artifact.requiresLegacyRevalidation || legacyRevalidationMatches(artifact),
                  artifact.id == id else { continue }
            candidates.append(Candidate(
                url: url, modified: values.contentModificationDate ?? now
            ))
        }
        candidates.sort { $0.modified < $1.modified }
        var removed = 0
        var remaining = urls.count
        var failures: [String] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            // Oldest-first: once a candidate is neither aged out nor needed
            // for the target, no later (newer) candidate is either.
            guard candidate.modified < cutoff || remaining > Self.artifactRetentionTarget else { break }
            // Counts follow effects: a file still present is neither removed
            // nor off the retention bound.
            do {
                let deleted = try await SwiftNativePersistenceCore.withFileLock(candidate.url, waitingAtMost: 0) {
                    // Admission needs the ledger lock held by this sweep, so
                    // every already-admitted invocation's sidecar is in the
                    // directory snapshot. Probe each without waiting: one busy
                    // invocation pins the artifact, but never another copy.
                    for entry in invocationLocks[candidate.url] ?? [] {
                        try await SwiftNativePersistenceCore.withFileLock(entry.deletingPathExtension(), waitingAtMost: 0) {
                            try FileManager.default.removeItem(at: entry)
                        }
                    }
                    guard !Task.isCancelled else { return false }
                    try FileManager.default.removeItem(at: candidate.url)
                    return true
                }
                if deleted {
                    removed += 1
                    remaining -= 1
                }
            } catch let error as NSError where error.domain == "FileLock" && error.code == Int(ETIMEDOUT) {
                // A live invocation pins this artifact. Never wait for it
                // while holding the reference lock it needs for settlement.
                continue
            } catch {
                failures.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            nativeLog("ProcedureArtifactStore: retention sweep removed %d unreferenced artifact(s)", removed)
        }
        if !failures.isEmpty {
            nativeLog("ProcedureArtifactStore: retention sweep could not remove %d artifact(s): %@",
                      failures.count, failures.joined(separator: "; "))
        }
        let reapedLocks = await reapOrphanArtifactLocks(in: artifactsDirectory, cutoff: cutoff)
        if reapedLocks > 0 {
            nativeLog("ProcedureArtifactStore: retention sweep removed %d orphan lock sidecar(s)", reapedLocks)
        }
        return removed
    }

    /// Reaps aged `<artifacts>/<id>.json.lock` sidecars under `withFileLock(artifact)`.
    /// Artifact absence and sidecar age are rechecked while holding the lock.
    /// `withFileLock` validates inode identity after flock and reopens detached waiters.
    private nonisolated func reapOrphanArtifactLocks(in directory: URL, cutoff: Date) async -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var reaped = 0
        for entry in entries where entry.lastPathComponent.hasSuffix(".json.lock") {
            let artifact = entry.deletingPathExtension()   // drop ".lock"
            // Cheap pre-filter outside the lock; both gates re-checked inside.
            guard !fm.fileExists(atPath: artifact.path) else { continue }
            guard Self.lockSidecarIsAgedOrphan(entry, cutoff: cutoff) else { continue }
            let didReap = (try? await SwiftNativePersistenceCore.withFileLock(artifact) { () -> Bool in
                // Holding the sidecar's flock: no install is mid-write for
                // this id. Re-check both gates — the world may have moved
                // while we waited for the lock.
                guard !FileManager.default.fileExists(atPath: artifact.path) else { return false }
                guard Self.lockSidecarIsAgedOrphan(entry, cutoff: cutoff) else { return false }
                return (try? FileManager.default.removeItem(at: entry)) != nil
            }) ?? false
            if didReap { reaped += 1 }
        }
        return reaped
    }

    private static func lockSidecarIsAgedOrphan(_ entry: URL, cutoff: Date) -> Bool {
        // Fresh URL so the stat can never be satisfied from cached resource
        // values — the in-lock re-check must see the current file.
        let fresh = URL(fileURLWithPath: entry.path)
        guard let values = try? fresh.resourceValues(
                  forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let modified = values.contentModificationDate else { return false }
        return modified < cutoff
    }

}
