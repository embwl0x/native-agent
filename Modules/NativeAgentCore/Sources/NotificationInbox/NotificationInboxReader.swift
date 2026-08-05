// RETIRED — reader protocol + factory for the DECOMMISSIONED daemon inbox silo
// at <dataRoot>/inbox/ (items.jsonl + index.json).
//
// THIS IS NOT THE PRODUCTION READ OR WRITE PATH. The live inbox is
// <dataRoot>/notifications/inbox.jsonl — the append-only event log the macOS
// and iOS UIs read; status changes go through
// `NativeClient.updateVisibleNotificationInboxStatus`, and cards are appended
// by `TriggerNotifierBinding.mirrorCardIntoRealInbox` and the provider-vitals
// notice lane. Verified 2026-08-01: no code outside this module and its tests
// constructs `SwiftNativeNotificationInbox` or calls `makeNotificationInbox`.
// The module is kept — not deleted — because the parity port and its tests are
// the record of the retired daemon's exact `Inbox` semantics. Do not wire new
// callers here; point them at notifications/inbox.jsonl.
//
// Everything below describes the daemon-parity contract as it was.
//
// Mirrors the wave-pattern of KnowledgeGraph / MacAssistantStatus:
//   - a `NotificationInboxReader` protocol with the READ + safe-status-write calls,
//   - `SwiftNativeNotificationInbox` (reads the local inbox dir each call),
//   - `makeNotificationInbox()` factory.
//
// READ envelopes match the daemon routes exactly:
//   GET /v1/inbox          -> JSON ARRAY of inbox_item_payload(i) dicts
//   GET /v1/inbox/<id>     -> single inbox_item_payload(item) dict, or .notFound (404)
//
// IMPORTANT — payload-enrichment caveat (why list/get can still fall back):
// The daemon does NOT return raw `InboxItem.to_dict()` over HTTP. It wraps each
// item in `runtime.inbox_item_payload(item)`, which
// for `proactive_autonomy:*` items (except goal_idea / inbox_digest) INSERTS a
// synthetic "act" action into the actions array when one is absent. That
// enrichment depends on `_proactive_source_parts()` runtime parsing. This
// module returns the FAITHFUL stored item (no enrichment). To preserve exact
// wire parity, the SwiftNative reader serves the native payload ONLY for items
// whose source is NOT a proactive_autonomy card; for proactive_autonomy items it
// returns nil so the caller can surface unsupported instead of serving an
// under-enriched payload. The enrichment port remains open.
//
// STATUS WRITES (read/archive/dismiss) — route through
// `NotificationInboxStore.updateStatusLocked`, which takes the SAME flock
// target the daemon's `_update_status` did (<dataRoot>/inbox/items.jsonl.lock).
// The `statusWritesEnabled` flag can disable them entirely (methods return
// nil). Retired-silo caveat: these writes land in frozen storage nothing else
// maintains — they are exercised by tests only.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Protocol

public protocol NotificationInboxReader: Sendable {
    /// GET /v1/inbox?unread=  — JSON array of item payloads, or nil when the
    /// native path cannot faithfully serve the payload.
    func list(unreadOnly: Bool) async -> JSONValue?
    /// GET /v1/inbox/<id>  — single item payload, .notFound, or nil when the
    /// native path cannot faithfully serve the payload.
    func get(id: String) async -> NotificationInboxGetResult?
    /// POST /v1/inbox/<id>/read  — true on native handle, nil on native failure.
    func markRead(id: String) async -> Bool?
    /// POST /v1/inbox/<id>/archive  — true on native handle, nil on native failure.
    /// NOTE: the daemon route ALSO fires `maybe_record_proactive_inbox_outcome`
    /// before archiving; that proactive-outcome ledger
    /// is not yet in Swift, so archive stays gated (see factory).
    func markArchived(id: String) async -> Bool?
    /// POST /v1/inbox/<id>/dismiss  — true on native handle, nil on native failure.
    /// Same proactive-outcome caveat as archive.
    func dismiss(id: String) async -> Bool?
}

/// Result of a single-item GET: the payload, or an explicit not-found marker so
/// the caller reproduces the daemon's 404 contract.
public enum NotificationInboxGetResult: Sendable {
    case found(JSONValue)
    case notFound
}

// MARK: - SwiftNative impl

public struct SwiftNativeNotificationInbox: NotificationInboxReader {
    /// `<dataRoot>/inbox` directory.
    public let inboxDir: URL
    /// The daemon data ROOT (parent of `inbox/`) — needed by the proactive
    /// outcome ledger, which writes `<root>/nextgen/proactive/outcomes.jsonl`
    /// and `<root>/activity/events.jsonl`. Defaults to `inboxDir`'s parent.
    public let dataRoot: URL
    /// Persistence used for the cross-process flock + the ledger appends.
    public let persistence: any PersistenceCoreProtocol
    /// Whether status-mutation writes (read/archive/dismiss) are allowed to run
    /// natively against the RETIRED silo.
    ///
    /// Wave 32 W16 made this default TRUE once
    /// `NotificationInboxStore.updateStatusLocked` wrapped the index.json
    /// read-modify-write in `withFileLock(itemsPath)`. That is now moot in
    /// production: nothing constructs this reader outside tests, so the flag
    /// only affects the parity-test surface.
    public let statusWritesEnabled: Bool
    /// Whether the proactive-outcome ledger side-effect is wired in Swift.
    ///
    /// Wave 32 W16: defaults TRUE. `ProactiveOutcomeLedger` ports
    /// `maybe_record_proactive_inbox_outcome` + `record_proactive_outcome`, so
    /// archive/dismiss fire the ledger BEFORE the status write exactly as the
    /// retired daemon route did. Also test-surface-only today.
    public let proactiveOutcomeWired: Bool

    public init(
        inboxDir: URL,
        dataRoot: URL? = nil,
        persistence: (any PersistenceCoreProtocol)? = nil,
        statusWritesEnabled: Bool = true,
        proactiveOutcomeWired: Bool = true
    ) {
        self.inboxDir = inboxDir
        self.dataRoot = dataRoot ?? inboxDir.deletingLastPathComponent()
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.statusWritesEnabled = statusWritesEnabled
        self.proactiveOutcomeWired = proactiveOutcomeWired
    }

    /// Resolve the path the daemon uses: `Inbox(self.root)` builds
    /// `<root>/inbox`, where `root` is the data root.
    /// PersistenceCore.defaultDataRoot() mirrors the daemon's data-root
    /// resolution (env NATIVE_AGENT_DATA_ROOT, literal tilde, default
    /// ~/.nativeagent).
    public static func defaultInboxDir() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("inbox", isDirectory: true)
    }

    private func store() -> NotificationInboxStore {
        NotificationInboxStore(inboxDir: inboxDir)
    }

    private func ledger() -> ProactiveOutcomeLedger {
        ProactiveOutcomeLedger(root: dataRoot, persistence: persistence)
    }

    /// True iff the item's source would trigger the daemon's
    /// `inbox_item_payload` action enrichment. For those we return nil and let
    /// HTTP apply the synthetic "act" action so the wire stays byte-identical.
    private func sourceNeedsEnrichment(_ source: String) -> Bool {
        // the retired daemon: enrichment applies when source starts
        // with "proactive_autonomy:" AND kind is NOT goal_idea / inbox_digest.
        // We conservatively treat ANY proactive_autonomy:* source as
        // needs-enrichment (a superset) so we never serve an under-enriched
        // payload; goal_idea/inbox_digest items then merely take the HTTP path
        // too — correctness over coverage.
        source.hasPrefix("proactive_autonomy:")
    }

    public func list(unreadOnly: Bool) async -> JSONValue? {
        let items = store().list(unreadOnly: unreadOnly, limit: 50)
        // If ANY item needs enrichment, fall back to HTTP for the whole list so
        // the action sets stay identical (the daemon enriches per-item; we can't
        // partially enrich without the runtime parser). This is the conservative
        // parity choice — most inboxes contain at least one proactive card, so
        // in practice list often falls back today; reads of a pure
        // trigger/execution inbox are served natively. The enrichment port closes
        // this (CUTOVER_PLAN.md §6.55).
        if items.contains(where: { sourceNeedsEnrichment($0.source) }) {
            return nil
        }
        return .array(items.map { $0.toJSONValue() })
    }

    public func get(id: String) async -> NotificationInboxGetResult? {
        guard let item = store().get(id) else {
            // Daemon route 404s on a missing item.
            return .notFound
        }
        if sourceNeedsEnrichment(item.source) {
            return nil   // let HTTP apply the enrichment
        }
        return .found(item.toJSONValue())
    }

    public func markRead(id: String) async -> Bool? {
        guard statusWritesEnabled else { return nil }
        // mark_read has NO proactive-outcome side-effect in the daemon
        //, so no ledger call
        // here. The write goes through the flock-wrapped path so it cannot tear
        // against the daemon's `_update_status` (which locks items.jsonl). On a
        // write/lock failure updateStatusLocked returns false; surface nil so the
        // caller falls back to HTTP rather than acknowledging a write that never
        // landed (gpt-5.5 wave-31 review finding #12).
        let ok = await store().updateStatusLocked(
            id, status: .read, readAt: NotificationInboxStore.nowISO(), persistence: persistence
        )
        return ok ? true : nil
    }

    public func markArchived(id: String) async -> Bool? {
        guard statusWritesEnabled, proactiveOutcomeWired else { return nil }
        // Daemon route order:
        //   maybe_record_proactive_inbox_outcome(id, "archive")  THEN  mark_archived(id)
        // We mirror the order EXACTLY — ledger fires before the status flip. The
        // ledger resolves the item's source itself; we read the item once here
        // (already needed to know whether it exists) and hand the source in to
        // avoid a redundant load. The daemon's `maybe_record_*` is wrapped in
        // try/except and never blocks the write, so a ledger IO error must not
        // veto the archive — `maybeRecordInboxOutcome` swallows its own errors.
        let source = store().get(id)?.source ?? ""
        await ledger().maybeRecordInboxOutcome(itemSource: source, itemId: id, action: "archive")
        let ok = await store().updateStatusLocked(id, status: .archived, persistence: persistence)
        return ok ? true : nil
    }

    public func dismiss(id: String) async -> Bool? {
        guard statusWritesEnabled, proactiveOutcomeWired else { return nil }
        // Same outcome-before-write order as archive (the retired daemon
        // L52967-52971), useful=False for dismiss.
        let source = store().get(id)?.source ?? ""
        await ledger().maybeRecordInboxOutcome(itemSource: source, itemId: id, action: "dismiss")
        let ok = await store().updateStatusLocked(id, status: .dismissed, persistence: persistence)
        return ok ? true : nil
    }
}

// MARK: - Factory

/// Returns the SwiftNative inbox reader. `inboxDir` is injectable for tests;
/// production callers omit it and get `defaultInboxDir()`.
///
/// Wave 32 W16: `statusWritesEnabled` / `proactiveOutcomeWired` now default TRUE
/// — the cross-process flock (NotificationInboxStore.updateStatusLocked) and the
/// proactive-outcome ledger (ProactiveOutcomeLedger) are wired, so read/archive/
/// dismiss all run natively when the flag is ON. Pass FALSE to force a write
/// surface locally without enabling any fallback.
public func makeNotificationInbox(
    inboxDir: URL? = nil,
    persistence: (any PersistenceCoreProtocol)? = nil,
    statusWritesEnabled: Bool = true,
    proactiveOutcomeWired: Bool = true
) -> any NotificationInboxReader {
    let resolvedInboxDir = inboxDir ?? SwiftNativeNotificationInbox.defaultInboxDir()
    return SwiftNativeNotificationInbox(
        inboxDir: resolvedInboxDir,
        dataRoot: resolvedInboxDir.deletingLastPathComponent(),
        persistence: persistence,
        statusWritesEnabled: statusWritesEnabled,
        proactiveOutcomeWired: proactiveOutcomeWired
    )
}
