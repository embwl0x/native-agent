// Reviewed scopes update canonical metadata so Context projects them normally.
// Existing topics are preserved; the completion marker admits retries until settled.

import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `LegacyCorrectionScopeMigration.swift` | Reviewed scope application and its consumed completion marker; no dated write-only audit copies; `runIfNeeded`, `migrationsDir` |

/// Completion marker: local backup/export and memory PrivacyMap, no phone sync.
public enum LegacyCorrectionScopeMigration {
    static let version = 1

    /// Stamped into `metadata.context_topics_origin`, so a later reader can tell
    /// a hand-reviewed legacy scope from `commit_memory`'s own `intake_derived`.
    static let originValue = "legacy_scope_review_v1"

    /// One reviewed legacy correction.
    ///
    /// `phrase` is a verbatim, distinctive opening fragment of the correction. It
    /// is matched as a substring and REQUIRED TO BE UNIQUE among active
    /// corrections: zero or several matches means this is not the row the review
    /// looked at, and the entry is skipped rather than guessed at. Content hashes
    /// would be stricter still and unreadable here; the uniqueness requirement
    /// buys the same safety while keeping the table reviewable.
    struct Entry: Sendable {
        let phrase: String
        let topics: [String]
    }

    /// The seven task-specific corrections. Topics are plain words a later turn
    /// on the same subject would actually use, because `ContextCorrectionScope`
    /// matches topic labels as whole-word sequences against the message with no
    /// stemming — a label nobody types is a correction nobody gets.
    static let entries: [Entry] = [
        Entry(
            phrase: "Callable tool names come from the live catalog",
            topics: ["tool", "tools", "tool name", "tool catalog", "capability"]
        ),
        Entry(
            phrase: "An isolated transcript bar soaking clean",
            topics: ["hang", "freeze", "soak", "transcript", "performance"]
        ),
        Entry(
            phrase: "A shell network restriction does not prove",
            topics: ["sandbox", "network", "shell", "connector", "connectors"]
        ),
        Entry(
            phrase: "Delegate one coherent unit at a time",
            topics: ["delegation", "delegate", "worker", "workers", "subagent"]
        ),
        Entry(
            phrase: "I mistook a provider outage for a broken bridge",
            topics: ["bridge", "provider", "outage", "delegate", "claude"]
        ),
        Entry(
            phrase: "Image working-set thrash, not transcript length",
            topics: ["image", "images", "cache", "decode", "thrash"]
        ),
        Entry(
            phrase: "When shared-tree changes disappear",
            topics: ["git", "stash", "reflog", "worktree", "commit"]
        ),
    ]

    /// The six that stay global, and why: the source record of the review.
    static let keptGlobal: [(atomPrefix: String, why: String)] = [
        ("atom:34ab290566", "interpersonal — greeting him, and his timezone"),
        ("atom:118f106ff378", "authorization — his quiet-desktop boundary"),
        ("atom:93d8e6e42c7c", "interpersonal — a callback between the two of them"),
        ("atom:ae0b6a7b0e2b", "interpersonal — her emotional range and endearments"),
        ("atom:bb409c01b3bf", "integrity — never report work she did not verify"),
        ("atom:b0b7f17380f3", "authorization — external-send and approval receipts"),
    ]

    // MARK: - Entry point

    /// Applies the reviewed scopes once. Never throws: a store that is not ready
    /// yet leaves the marker unwritten, and the next launch retries.
    public static func runIfNeeded(dataRoot: URL = PersistenceCore.defaultDataRoot()) async {
        let marker = markerPath(dataRoot: dataRoot)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let storage: MemoryStorage
        let rows: [StoredMemory]
        do {
            storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            rows = try await storage.listMemories(status: "active")
        } catch {
            nativeLog("[correctionScope] store not ready; migration deferred: \(String(describing: error))")
            return
        }

        let corrections = rows.filter { metadataString($0.metadata, "kind") == "correction" }
        var applied = 0
        var skipped = 0
        // Existing scopes are satisfied, so retries can complete after partial writes.
        var satisfied = 0
        var anyMatched = false

        for entry in entries {
            let matches = corrections.filter { $0.content.contains(entry.phrase) }
            anyMatched = anyMatched || !matches.isEmpty
            guard matches.count == 1, let row = matches.first else {
                skipped += 1
                continue
            }
            // Any topics at all — hand-supplied, intake-derived, or a previous
            // run of this migration — mean the scope is already someone's
            // decision. Never overwrite it.
            if case .array(let existing)? = metadataValue(row.metadata, "context_topics"), !existing.isEmpty {
                satisfied += 1
                continue
            }
            let patch = MemoryPatch(metadataMerge: [
                "context_topics": .array(entry.topics.map { .string($0) }),
                "context_topics_origin": .string(originValue),
            ])
            do {
                guard try await storage.updateMemory(
                    id: row.id, patch: patch, expectedContent: row.content,
                    onlyIf: { current in
                        guard current.status == row.status, current.lifecycle == row.lifecycle,
                              metadataString(current.metadata, "kind") == "correction" else { return false }
                        if case .array(let topics)? = metadataValue(current.metadata, "context_topics"), !topics.isEmpty {
                            return false
                        }
                        return true
                    }
                ) != nil else {
                    skipped += 1
                    continue
                }
            } catch {
                // A failed write must not be stamped done.
                nativeLog("[correctionScope] write failed for \(row.id); migration deferred: \(String(describing: error))")
                return
            }
            applied += 1
        }

        // The atoms only change once the projection recompiles the memory
        // sources whose `sourceHash` just moved.
        if applied > 0 {
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "memory-v2",
                stableID: "correction_scope_review_v\(version)",
                operation: .reconcile,
                reason: "legacy_correction_scope_review"
            ))
        }

        if skipped == 0 || !anyMatched {
            do {
                let marker = markerPath(dataRoot: dataRoot)
                try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(
                    Data(MemoryStorage.nowISO8601().utf8), to: marker)
            } catch {
                nativeLog("[correctionScope] completion marker write failed: %@", String(describing: error))
            }
        }
        nativeLog("[correctionScope] legacy scope review: scoped=\(applied) already_scoped=\(satisfied) skipped=\(skipped) kept_global=\(keptGlobal.count)")
    }

    // MARK: - Paths

    static func migrationsDir(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("migrations", isDirectory: true)
    }

    static func markerPath(dataRoot: URL) -> URL {
        migrationsDir(dataRoot: dataRoot)
            .appendingPathComponent("correction_scope_review_v\(version).done")
    }

    // MARK: - Metadata helpers

    private static func metadataValue(_ metadata: JSONValue?, _ key: String) -> JSONValue? {
        guard case .object(let obj)? = metadata else { return nil }
        return obj[key]
    }

    private static func metadataString(_ metadata: JSONValue?, _ key: String) -> String? {
        guard case .string(let value)? = metadataValue(metadata, key) else { return nil }
        return value
    }
}
