// FullMacExpiry — Full Mac duration picker options, READ-ONLY expiry-state
// mirror of the gate that sweeps the agent's tool catalog, and the
// inbox-card notifier that surfaces "expiring soon" / "expired" instead of
// letting the sweep happen silently (2026-06-10: the restart tool vanished
// mid-afternoon with zero surfacing — this file is the fix's surfacing half).
//
// SCOPE GUARANTEE: nothing in this file changes gate behavior. The
// ACTIVE/INACTIVE verdict is delegated to the real gate
// (`MacControlGate.fullMacActive` — the same function
// `SwiftToolDispatcher.fullMacToolAccess` consults before including the
// Full-Mac file-ops tool block in the chat catalog). Only the expiry
// *instant*, which the gate computes internally but never exposes, is
// mirrored here — field-for-field against MacControlGate.fullMacActive's
// ordering (permission gate → never → explicit fullMacExpiresAt →
// fullMacConfirmedAt + clamped fullMacMaxDurationHours window). If the gate
// changes, change it there first, then re-mirror here.
import Foundation
import CryptoKit
import MacControl
import PersistenceCore
import NativeAgentShared
import TrustCenter

// MARK: - Duration picker options

/// The four operator-facing Full Mac duration choices (the user's spec
/// 2026-06-10: "four hours, twenty four hours, forty eight, and then it
/// never expires").
enum FullMacDurationOption: String, CaseIterable, Identifiable, Sendable {
    case fourHours
    case twentyFourHours
    case fortyEightHours
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fourHours: return "4 hours"
        case .twentyFourHours: return "24 hours"
        case .fortyEightHours: return "48 hours"
        case .never: return "Never expires"
        }
    }

    /// Hours written to `fullMacMaxDurationHours`; nil for the never case
    /// (which writes `fullMacNeverExpires` instead and leaves the stored
    /// duration untouched).
    var hours: Double? {
        switch self {
        case .fourHours: return 4
        case .twentyFourHours: return 24
        case .fortyEightHours: return 48
        case .never: return nil
        }
    }

    /// Derive the selection the persisted policy currently encodes.
    static func from(_ policy: TrustPolicy?) -> FullMacDurationOption {
        guard let policy else { return .fourHours }
        let expires = (policy.fullMacExpiresAt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if policy.fullMacNeverExpires == true || expires == "never" {
            return .never
        }
        let hours = policy.fullMacMaxDurationHours ?? 4
        if hours >= 48 { return .fortyEightHours }
        if hours >= 24 { return .twentyFourHours }
        return .fourHours
    }
}

// MARK: - Expiry state

enum FullMacExpiryState: Equatable, Sendable {
    /// Full Mac permission mode is off, or Full Mac was never confirmed.
    case off
    /// Active with no expiry.
    case never
    /// Active until `expiresAt`.
    case active(expiresAt: Date)
    /// Window closed at `at` — the file-ops tool block is swept from the
    /// agent's catalog until reconfirmed.
    case expired(at: Date)
    /// Trust timestamps present but unparseable — the gate fails closed
    /// (tools swept), and no expiry instant can be shown.
    case unreadable
}

enum FullMacExpiry {
    /// Inbox warning fires when an active window has ≤ this much left.
    static let warningWindow: TimeInterval = 30 * 60

    /// Build the gate's input struct from the app-side TrustPolicy model —
    /// same field sourcing as `MacControlPolicy.fromTrustPolicyObject`
    /// (defaults: outside "deny", permission "balanced", duration 4).
    static func trustFields(_ policy: TrustPolicy) -> MacControlTrustPolicy {
        MacControlTrustPolicy(
            outsideWorkspaceDefault: policy.filePolicy?.outsideWorkspaceDefault ?? "deny",
            permissionLevel: policy.permissionLevel.isEmpty ? "balanced" : policy.permissionLevel,
            fullMacExpiresAt: policy.fullMacExpiresAt ?? "",
            fullMacNeverExpires: policy.fullMacNeverExpires ?? false,
            fullMacConfirmedAt: policy.fullMacConfirmedAt ?? "",
            fullMacMaxDurationHours: policy.fullMacMaxDurationHours ?? 4,
            developerMode: policy.developerMode,
            allowDestructiveActions: policy.filePolicy?.allowDestructiveActions ?? false
        )
    }

    static func state(_ policy: TrustPolicy?, now: Date = Date()) -> FullMacExpiryState {
        guard let policy else { return .off }
        return state(trustFields(policy), now: now)
    }

    /// Raw-field entry point (tests use this so they don't need to import
    /// MacControl directly).
    static func state(
        permissionLevel: String,
        outsideWorkspaceDefault: String,
        neverExpires: Bool,
        expiresAt: String,
        confirmedAt: String,
        maxDurationHours: Double,
        now: Date = Date()
    ) -> FullMacExpiryState {
        state(
            MacControlTrustPolicy(
                outsideWorkspaceDefault: outsideWorkspaceDefault,
                permissionLevel: permissionLevel,
                fullMacExpiresAt: expiresAt,
                fullMacNeverExpires: neverExpires,
                fullMacConfirmedAt: confirmedAt,
                fullMacMaxDurationHours: maxDurationHours
            ),
            now: now
        )
    }

    static func state(_ trust: MacControlTrustPolicy, now: Date = Date()) -> FullMacExpiryState {
        // The verdict comes from the REAL gate — the one the tool-catalog
        // sweep consults. Everything below only classifies that verdict.
        let active = MacControlGate.fullMacActive(trust, now: now)
        let expiresRaw = trust.fullMacExpiresAt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmedRaw = trust.fullMacConfirmedAt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if active {
            if trust.fullMacNeverExpires || expiresRaw.lowercased() == "never" {
                return .never
            }
            if let instant = expiryInstant(
                expiresRaw: expiresRaw,
                confirmedRaw: confirmedRaw,
                maxDurationHours: trust.fullMacMaxDurationHours
            ) {
                return .active(expiresAt: instant)
            }
            // Gate said active but the mirror can't reproduce the instant —
            // should be unreachable (same parse); stay honest, don't invent
            // a countdown.
            return .unreadable
        }
        // Inactive — distinguish "mode off / never confirmed" from
        // "window closed" the way the gate's short-circuits do.
        let outside = trust.outsideWorkspaceDefault.isEmpty
            ? "deny" : trust.outsideWorkspaceDefault
        let permission = trust.permissionLevel.isEmpty
            ? "balanced" : trust.permissionLevel
        if outside != "allow"
            && !(permission == "wide_open_receipts" || permission == "full_mac_os") {
            return .off
        }
        if expiresRaw.isEmpty && confirmedRaw.isEmpty { return .off }
        if let instant = expiryInstant(
            expiresRaw: expiresRaw,
            confirmedRaw: confirmedRaw,
            maxDurationHours: trust.fullMacMaxDurationHours
        ) {
            return .expired(at: instant)
        }
        return .unreadable
    }

    /// The instant the gate's window closes. Mirrors the gate's precedence:
    /// explicit `fullMacExpiresAt` wins (NO fallback to the confirmed
    /// window when it fails to parse — the gate fails closed there too);
    /// otherwise `fullMacConfirmedAt` + the [0.01, 24]h-clamped duration
    /// window (0 → default 4).
    static func expiryInstant(
        expiresRaw: String,
        confirmedRaw: String,
        maxDurationHours: Double
    ) -> Date? {
        if !expiresRaw.isEmpty {
            return parseGateISO8601(expiresRaw)
        }
        guard !confirmedRaw.isEmpty,
              let ts = parseGateISO8601(confirmedRaw) else { return nil }
        // max(0.01, min(hours or 4, 24.0)) — MacControlGate.fullMacActive's
        // Python-parity clamp. NOTE the 24h ceiling: this is why the 48h
        // picker option also writes an explicit fullMacExpiresAt (see
        // NativeClient.fullMacDurationPatchBody).
        let raw = maxDurationHours == 0 ? 4 : maxDurationHours
        let maxHours = max(0.01, min(raw, 24.0))
        return ts.addingTimeInterval(maxHours * 3600)
    }

    // MARK: status line

    /// One-line, always-visible status string for the Trust Center panel
    /// and the inbox cards.
    static func statusLine(_ state: FullMacExpiryState, now: Date = Date()) -> String {
        switch state {
        case .off:
            return "Full Mac not active"
        case .never:
            return "Full Mac active — expires never"
        case .active(let expiresAt):
            let remaining = expiresAt.timeIntervalSince(now)
            return "Full Mac active — expires in \(compactInterval(remaining))"
        case .expired(let at):
            let ago = now.timeIntervalSince(at)
            return "Full Mac EXPIRED \(compactInterval(ago)) ago — reconfirm to restore file tools"
        case .unreadable:
            return "Full Mac trust timestamps unreadable — gate fails closed; reconfirm to restore file tools"
        }
    }

    /// "2h 13m" / "13m" / "under 1m".
    static func compactInterval(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "under 1m"
    }

    // MARK: gate-parity timestamp parsing

    /// THE gate's parser, read-only. Was a byte-for-byte private mirror
    /// while `MacControlGate.parseISO8601` was module-internal; the review
    /// blocker fix (2026-06-10) made the gate's parser public for exactly
    /// this kind of consumer, so the mirror (and its drift risk) is gone.
    static func parseGateISO8601(_ raw: String) -> Date? {
        MacControlGate.parseISO8601(raw)
    }
}

// MARK: - Expiry notifier (background check)

/// Runs from the cheap `full_mac_expiry` background loop and stages at most ONE
/// inbox card per expiry cycle for each of:
///   - "expiring soon" (≤ 30 minutes left on an active window)
///   - "expired" (window closed — the file-ops tool block is already swept)
///
/// Idempotency: a stamp file under flock, keyed on the CURRENT
/// `fullMacConfirmedAt` + the resolved expiry instant. A reconfirm (new
/// confirmedAt) or a duration change (new instant) starts a fresh cycle and
/// re-arms both cards. Cards land in `notifications/inbox.jsonl` — the
/// store the Inbox UI reads — with the same field shape as
/// `BackgroundLoopsAssembly.ensureREMProposalInboxCard`, but informational
/// (view/dismiss only; no linked approval).
enum FullMacExpiryRunOutcome: Sendable, Equatable {
    case completed(String)
    case skipped(String)
    case failed(String)
}

struct FullMacExpiryNotifier: Sendable {
    let dataRoot: URL
    /// Injectable clock (tests).
    var now: @Sendable () -> Date = { Date() }

    private enum CardKind: String {
        case warning
        case expired
    }

    /// Production entry: load the policy through the SAME loader the gate's
    /// caller uses (SwiftNativeTrustCenter → MacControlPolicy
    /// .fromTrustPolicyObject) so the check reads exactly the fields the
    /// sweep reads — but read the cycle-key stamps RAW from disk.
    ///
    /// REVIEW BLOCKER FIX (gpt-5.5, 2026-06-10): loadTrustPolicy BACKFILLS
    /// a missing `fullMacConfirmedAt` with now() in memory on every load
    /// (no write-back). Keying the card cycle on that backfilled stamp
    /// minted a NEW cycle every 5-minute tick whenever the stamp was
    /// missing on disk → a fresh card id per tick → inbox spam. The cycle
    /// key must come from ON-DISK values only.
    @discardableResult
    func runOnce() async -> FullMacExpiryRunOutcome {
        let policyPath = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        if FileManager.default.fileExists(atPath: policyPath.path) {
            do {
                let data = try Data(contentsOf: policyPath)
                guard case .object = try JSONValue.parse(data) else {
                    return .failed("trust policy is not a JSON object")
                }
            } catch {
                return .failed("trust policy unreadable: \(error.localizedDescription)")
            }
        }
        let policyObj = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        let macPolicy = MacControlPolicy.fromTrustPolicyObject(policyObj)
        let (onDiskConfirmedAt, onDiskExpiresAt) = await onDiskTrustStamps()
        return await runOnce(
            trust: macPolicy.trustPolicy ?? MacControlTrustPolicy(),
            onDiskConfirmedAt: onDiskConfirmedAt,
            onDiskExpiresAt: onDiskExpiresAt
        )
    }

    /// The two cycle-key stamps exactly as `trust/policy.json` carries them
    /// (missing/null/non-string → ""). No normalizer backfill.
    private func onDiskTrustStamps() async -> (confirmedAt: String, expiresAt: String) {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let raw = await SwiftNativePersistenceCore().readJSON(path, defaultValue: .object([:]))
        guard case .object(let obj) = raw else { return ("", "") }
        func str(_ key: String) -> String {
            if case .string(let s)? = obj[key] {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        return (str("fullMacConfirmedAt"), str("fullMacExpiresAt"))
    }

    /// `trust` drives the STATE verdict (same fields the gate's caller
    /// loads, normalizer backfills included — the mirror must agree with
    /// the sweep). `onDiskConfirmedAt`/`onDiskExpiresAt` drive the card
    /// CYCLE KEY and must be the raw on-disk strings.
    @discardableResult
    func runOnce(
        trust: MacControlTrustPolicy,
        onDiskConfirmedAt: String,
        onDiskExpiresAt: String
    ) async -> FullMacExpiryRunOutcome {
        let current = now()
        let state = FullMacExpiry.state(trust, now: current)
        let instantKey: String
        switch state {
        case .off, .never:
            return .skipped("Full Mac expiry is not active")
        case .active(let d):
            instantKey = Self.isoTimestamp(d)
        case .expired(let d):
            instantKey = Self.isoTimestamp(d)
        case .unreadable:
            instantKey = "unreadable"
        }
        let cycleKey = Self.cycleKey(
            onDiskConfirmedAt: onDiskConfirmedAt,
            onDiskExpiresAt: onDiskExpiresAt,
            instantKey: instantKey
        )

        switch state {
        case .active(let expiresAt):
            let remaining = expiresAt.timeIntervalSince(current)
            guard remaining <= FullMacExpiry.warningWindow else {
                return .skipped("Full Mac expiry is outside the warning window")
            }
            return await stageOnce(
                kind: .warning,
                cycleKey: cycleKey,
                title: "Full Mac access expires soon",
                summary: "Full Mac access expires in "
                    + FullMacExpiry.compactInterval(remaining)
                    + ". File tools will be swept from the agent's catalog at expiry — reconfirm in Trust Center to extend.",
                detail: "Full Mac access expires at \(Self.isoTimestamp(expiresAt)). "
                    + "When the window closes, the Full-Mac file-ops tool block (including restart and outside-workspace file tools) "
                    + "is removed from the agent's tool catalog until you reconfirm in Trust Center.",
                severity: "important"
            )
        case .expired(let at):
            return await stageOnce(
                kind: .expired,
                cycleKey: cycleKey,
                title: "Full Mac expired — tools swept",
                summary: "Full Mac expired — tools swept from the agent's catalog; reconfirm in Trust Center.",
                detail: "The Full Mac window closed at \(Self.isoTimestamp(at)) "
                    + "(\(FullMacExpiry.compactInterval(now().timeIntervalSince(at))) ago). "
                    + "The Full-Mac file-ops tool block is no longer offered to the agent. "
                    + "Reconfirm Full Mac in Trust Center to restore it.",
                severity: "actionable"
            )
        case .unreadable:
            return await stageOnce(
                kind: .expired,
                cycleKey: cycleKey,
                title: "Full Mac expired — tools swept",
                summary: "Full Mac trust timestamps are unreadable — the gate fails closed and tools are swept from the agent's catalog; reconfirm in Trust Center.",
                detail: "fullMacConfirmedAt/fullMacExpiresAt in trust/policy.json could not be parsed, "
                    + "so the Full Mac gate treats the grant as inactive and the file-ops tool block is swept. "
                    + "Reconfirm Full Mac in Trust Center to write fresh timestamps.",
                severity: "actionable"
            )
        case .off, .never:
            return .skipped("Full Mac expiry is not active")
        }
    }

    // MARK: internals

    /// Card-cycle key from ON-DISK values only (review blocker fix,
    /// 2026-06-10 — see runOnce()):
    ///   - explicit on-disk `fullMacExpiresAt` present → key on it (a
    ///     duration change rewrites it → new cycle re-arms; ticks don't).
    ///   - else on-disk `fullMacConfirmedAt` present → key on it plus the
    ///     derived instant (both stable on disk; a duration change moves
    ///     the instant → new cycle, matching the original re-arm design).
    ///   - neither on disk → ONE stable "unstamped" cycle. The in-memory
    ///     backfilled stamp varies per load and must never reach the key.
    static func cycleKey(
        onDiskConfirmedAt: String,
        onDiskExpiresAt: String,
        instantKey: String
    ) -> String {
        if !onDiskExpiresAt.isEmpty {
            return "expires|\(onDiskExpiresAt)"
        }
        if !onDiskConfirmedAt.isEmpty {
            return "\(onDiskConfirmedAt)|\(instantKey)"
        }
        return "unstamped"
    }

    private var stampPath: URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("fullmac_expiry_state.json")
    }

    private var inboxPath: URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// Stage one card for `kind` in the current cycle. Order is
    /// crash-safe: check stamp → ensure card (idempotent scan-before-append
    /// under the inbox flock) → set stamp. A crash between card and stamp
    /// self-heals next tick (the scan finds the existing card id).
    private func stageOnce(
        kind: CardKind,
        cycleKey: String,
        title: String,
        summary: String,
        detail: String,
        severity: String
    ) async -> FullMacExpiryRunOutcome {
        do {
            if try await stampSet(kind: kind, cycleKey: cycleKey) {
                return .skipped("\(kind.rawValue) card already staged for this expiry cycle")
            }
        } catch {
            // Continue through the deterministic inbox-card scan. If card and
            // final stamp both succeed, this tick repaired the unreadable stamp.
        }
        let cardId = Self.cardId(kind: kind, cycleKey: cycleKey)
        do {
            try await ensureCard(
                id: cardId,
                title: title,
                summary: summary,
                detail: detail,
                severity: severity
            )
        } catch {
            return .failed("\(kind.rawValue) card persistence failed: \(error.localizedDescription)")
        }
        do {
            try await markStamp(kind: kind, cycleKey: cycleKey)
            return .completed("\(kind.rawValue) card and expiry stamp are durable")
        } catch {
            return .failed("\(kind.rawValue) card exists but expiry stamp persistence failed: \(error.localizedDescription)")
        }
    }

    /// Deterministic per-cycle card id, so the inbox scan dedupes even if
    /// the stamp file is lost.
    static func cardId(kind: String, cycleKey: String) -> String {
        let digest = SHA256.hash(data: Data(cycleKey.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "fullmac_expiry_\(kind)_\(suffix)"
    }

    private static func cardId(kind: CardKind, cycleKey: String) -> String {
        cardId(kind: kind.rawValue, cycleKey: cycleKey)
    }

    private func stampSet(kind: CardKind, cycleKey: String) async throws -> Bool {
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(stampPath) {
            guard FileManager.default.fileExists(atPath: stampPath.path) else { return false }
            let data = try Data(contentsOf: stampPath)
            guard case .object(let obj) = try JSONValue.parse(data),
                  case .string(let cycle)? = obj["cycle"],
                  cycle == cycleKey,
                  case .bool(true)? = obj[kind.rawValue]
            else { return false }
            return true
        }
    }

    private func markStamp(kind: CardKind, cycleKey: String) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(stampPath) {
            let raw: JSONValue
            if FileManager.default.fileExists(atPath: stampPath.path) {
                raw = try JSONValue.parse(Data(contentsOf: stampPath))
            } else {
                raw = .object([:])
            }
            var obj: [String: JSONValue] = [:]
            if case .object(let o) = raw { obj = o }
            let sameCycle: Bool = {
                if case .string(let cycle)? = obj["cycle"] { return cycle == cycleKey }
                return false
            }()
            if !sameCycle {
                // New cycle (reconfirm / duration change) — reset flags.
                obj = ["cycle": .string(cycleKey)]
            }
            obj["cycle"] = .string(cycleKey)
            obj[kind.rawValue] = .bool(true)
            obj["updated_at"] = .string(Self.isoTimestamp(now()))
            try await persistence.writeJSON(.object(obj), to: stampPath)
        }
    }

    /// Append the card unless a card with this id already exists —
    /// whole-file scan under the same flock, mirroring
    /// `BackgroundLoopsAssembly.ensureREMProposalInboxCard`.
    private func ensureCard(
        id: String,
        title: String,
        summary: String,
        detail: String,
        severity: String
    ) async throws {
        let card: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(Self.isoTimestamp(now())),
            "source": .string("trust_center"),
            "severity": .string(severity),
            "title": .string(title),
            "summary": .string(summary),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([
                .string(dataRoot
                    .appendingPathComponent("trust", isDirectory: true)
                    .appendingPathComponent("policy.json").path),
            ]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let persistence = SwiftNativePersistenceCore()
        let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
            let rows = try await persistence.tailJSONL(
                inboxPath, limit: Int.max, maxBytes: nil)
            let exists = rows.contains { row in
                guard case .object(let obj) = row,
                      case .string(let existing)? = obj["id"] else { return false }
                return existing == id
            }
            if exists { return false }
            try await persistence.appendJSONL(card, to: inboxPath)
            return true
        }
        if inserted {
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: id,
                title: title,
                summary: summary,
                source: "trust_center",
                severity: severity
            )
        }
    }

    static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }
}
