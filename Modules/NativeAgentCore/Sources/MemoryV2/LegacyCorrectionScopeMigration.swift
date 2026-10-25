// Astra audit 2026-09-11 finding 5 — the legacy correction budget.
//
// The former `CorrectionScopeAtIntake` (2026-09-11) scoped arriving corrections,
// never atoms already in the store. It is retired; intake now uses explicit
// context_topics only (docs/MEMORY_SYSTEM_MAP.md).
// That left the thing the audit actually measured untouched. The live Context
// store holds 31 current correction atoms, 13 of them with no `context_topic`
// entity, and `ContextCorrectionScope.applies` is fail-open — no scoping entity
// means MANDATORY on every turn. 14 corrections were injected ahead of the
// ordinary memories in the first fresh prompt of the day, among them an
// image-decode-cache diagnosis, a git stash/reflog lesson and a
// shell-versus-connectors distinction, on turns about none of those things.
// They are real lessons. They are not every turn's business, and they were
// spending the relevance budget ordinary memories needed.
//
// WHY THIS PATCHES MEMORY ROWS AND NOT context.sqlite. A correction atom is a
// PROJECTION of its memory row (`NativeMemoryContextProjection`), and the
// projection's change detector compares a `sourceHash` computed FROM that row —
// `context_topics` included. Hand-writing `context_atom_versions` would be
// silently reverted by the next reconcile, which would recompute the hash from
// the untouched memory row and republish the atom without the entities. So the
// scope goes where scope comes from: `metadata.context_topics` on the record,
// exactly the key `commit_memory` writes, after which the ordinary projection
// mints the `context_topic` entities itself (same atom id, new version).
//
// WHY A HARD-CODED TABLE AND NOT A CLASSIFIER. The former intake
// deliberately refused to guess without dispatch evidence from the turn that
// produced the correction, and for a legacy row that evidence is gone. The
// audit asked for a legacy scope REVIEW, so this is the review: thirteen
// decisions, made once, by hand, listed here. Seven get a topic. Six stay
// global — every interpersonal one and every one that speaks about what she may
// do, because a boundary that only holds on turns about its own subject is not
// a boundary. The six are named in `keptGlobal` below so the judgment is on the
// record rather than implied by absence.
//
// Idempotence is the house pattern: a version-stamped `.done` marker under
// <dataRoot>/memory/migrations/, written ONLY after the pass completes, so a
// crash re-runs it; plus a per-row guard that skips any record which already
// carries topics from any source. Receipt JSON lands beside the marker.

import Foundation
import NativeAgentCore
import PersistenceCore
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
        let atomPrefix: String
        let phrase: String
        let topics: [String]
        let why: String
    }

    /// The seven task-specific corrections. Topics are plain words a later turn
    /// on the same subject would actually use, because `ContextCorrectionScope`
    /// matches topic labels as whole-word sequences against the message with no
    /// stemming — a label nobody types is a correction nobody gets.
    static let entries: [Entry] = [
        Entry(
            atomPrefix: "atom:861474c3b72d",
            phrase: "Callable tool names come from the live catalog",
            topics: ["tool", "tools", "tool name", "tool catalog", "capability"],
            why: "how tools are named and found; no boundary in it"
        ),
        Entry(
            atomPrefix: "atom:a2c29c30ad51",
            phrase: "An isolated transcript bar soaking clean",
            topics: ["hang", "freeze", "soak", "transcript", "performance"],
            why: "what proves a hang diagnosis; a performance-turn lesson"
        ),
        Entry(
            atomPrefix: "atom:98a30e202c58",
            phrase: "A shell network restriction does not prove",
            topics: ["sandbox", "network", "shell", "connector", "connectors"],
            why: "epistemic — it warns against ASSUMING a restriction, so scoping "
                + "it cannot remove a boundary; the audit named this one"
        ),
        Entry(
            atomPrefix: "atom:035df08cf0ee",
            phrase: "Delegate one coherent unit at a time",
            topics: ["delegation", "delegate", "worker", "workers", "subagent"],
            why: "how to hand work to a worker; 'before sending' is about "
                + "delegating, not about contacting anyone"
        ),
        Entry(
            atomPrefix: "atom:9a6f42a30a06",
            phrase: "I mistook a provider outage for a broken bridge",
            topics: ["bridge", "provider", "outage", "delegate", "claude"],
            why: "one diagnosis of one failure mode on the bridge"
        ),
        Entry(
            atomPrefix: "atom:6aea2c427db3",
            phrase: "Image working-set thrash, not transcript length",
            topics: ["image", "images", "cache", "decode", "thrash"],
            why: "the image-decode-cache diagnosis the audit quoted"
        ),
        Entry(
            atomPrefix: "atom:2c2367d8bb48",
            phrase: "When shared-tree changes disappear",
            topics: ["git", "stash", "reflog", "worktree", "commit"],
            why: "a git-command lesson; scoping it puts it on exactly the turns "
                + "that can hit it"
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
        var applied: [JSONValue] = []
        var skipped: [JSONValue] = []
        // SATISFIED IS NOT SKIPPED (Astra comb 3, lane1 finding 5, 2026-09-12).
        // A row that already carries a scope needs nothing from this migration
        // ever again — whether this pass wrote it, a hand edit did, or intake
        // derived it. Counting those as unresolved made a retry unfinishable:
        // after a run that scoped some rows and died before its marker, the next
        // run correctly preserved the scopes, classified all seven as
        // "already scoped", and therefore never wrote the marker — so every
        // subsequent launch repeated the pass and added another receipt. The
        // seven rows of receipt `correction_scope_review_v1_2026-09-11T21-16-29
        // .992Z.json` (memory rowids 163, 165, 167, 281, 290, 343, 359, all
        // `context_topics_origin=legacy_scope_review_v1`) are exactly the rows
        // that would have deadlocked it.
        var satisfied: [JSONValue] = []
        var anyMatched = false

        for entry in entries {
            let matches = corrections.filter { $0.content.contains(entry.phrase) }
            anyMatched = anyMatched || !matches.isEmpty
            guard matches.count == 1, let row = matches.first else {
                // Not the row the review read. Say which and move on — a guess
                // here would scope the wrong correction.
                skipped.append(.object([
                    "atom_prefix": .string(entry.atomPrefix),
                    "reason": .string("matched \(matches.count) active corrections, expected 1"),
                ]))
                continue
            }
            // Any topics at all — hand-supplied, intake-derived, or a previous
            // run of this migration — mean the scope is already someone's
            // decision. Never overwrite it.
            if case .array(let existing)? = metadataValue(row.metadata, "context_topics"), !existing.isEmpty {
                satisfied.append(.object([
                    "atom_prefix": .string(entry.atomPrefix),
                    "memory_id": .string(row.id),
                    "reason": .string("already scoped"),
                    "origin": .string(metadataString(row.metadata, "context_topics_origin") ?? "unknown"),
                ]))
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
                    skipped.append(.object([
                        "atom_prefix": .string(entry.atomPrefix),
                        "memory_id": .string(row.id),
                        "reason": .string("row changed or already scoped"),
                    ]))
                    continue
                }
            } catch {
                // A failed write must not be stamped done.
                nativeLog("[correctionScope] write failed for \(row.id); migration deferred: \(String(describing: error))")
                return
            }
            applied.append(.object([
                "atom_prefix": .string(entry.atomPrefix),
                "memory_id": .string(row.id),
                "topics": .array(entry.topics.map { .string($0) }),
                "why": .string(entry.why),
            ]))
        }

        // The atoms only change once the projection recompiles the memory
        // sources whose `sourceHash` just moved.
        if !applied.isEmpty {
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "memory-v2",
                stableID: "correction_scope_review_v\(version)",
                operation: .reconcile,
                reason: "legacy_correction_scope_review"
            ))
        }

        if skipped.isEmpty || !anyMatched {
            do {
                let marker = markerPath(dataRoot: dataRoot)
                try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await SwiftNativePersistenceCore().writeDataAtomicDurable(
                    Data(MemoryStorage.nowISO8601().utf8), to: marker)
            } catch {
                nativeLog("[correctionScope] completion marker write failed: %@", String(describing: error))
            }
        }
        nativeLog("[correctionScope] legacy scope review: scoped=\(applied.count) already_scoped=\(satisfied.count) skipped=\(skipped.count) kept_global=\(keptGlobal.count)")
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
