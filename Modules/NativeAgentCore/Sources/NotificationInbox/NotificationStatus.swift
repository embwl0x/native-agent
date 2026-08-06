// Reader protocol + factory for the read-only NOTIFICATION-STATUS surface
// (Subsystem #25b — wave 38 W20).
//
// Mirrors the wave-pattern used by Browser / MacAssistantStatus:
//   - a `NotificationStatusReader` protocol with the one read call,
//   - `SwiftNativeNotificationStatus` (reads the local files each call),
//   - `makeNotificationStatus()` factory.
//
// The SwiftNative reader returns the SAME envelope the daemon GET route does:
//   GET /v1/notifications/status -> NativeAgentRuntime.notification_status()
//:
//     receipts = list(reversed(tail_jsonl(self.notification_actions_path, 20)))
//     pending_approvals = len([item for item in self.list_approval_requests()
//                              if item.get("status") == "pending"])
//     return {
//       "status": "ready",
//       "authorization": "app_requested",
//       "actionCategories": [
//         {"id":"approval","actions":["approve","deny"],"risk":"medium"},
//         {"id":"doctor","actions":["open_doctor","repair_safe"],"risk":"low"},
//         {"id":"mission","actions":["open_mission"],"risk":"low"},
//       ],
// (Wave 5 P2-6: the ported literal now emits "open_execution" for that action.
//  The category `id` stays "mission" — it is a different token, unrelated to
//  this wave, and moves with the category rename if one is ever scheduled.)
//       "pendingApprovals": pending_approvals,
//       "receiptCount": len(receipts),
//       "latestReceipt": receipts[0] if receipts else None,
//       "createdAt": now_iso(),
//     }
//
// PURE-READ PORT (no write-back). The daemon side only APPENDS to
//   <dataRoot>/native_power/notifications/receipts.jsonl   (append_jsonl, atomic
//                                                            single-line append)
// and read_json's
//   <dataRoot>/workflows/approvals/requests.json
// so this status read never sees a torn snapshot and needs NO cross-process
// flock. (The approvals file's read-modify-write on the daemon side is already
// `approvals_lock`-guarded and write_json is tmp+os.replace atomic, so a
// concurrent daemon write lands wholesale — our reader either sees the old or
// the new file, never a partial.) There is no WRITE route on this surface.
//
// DATA PATHS:
//   self.notification_actions_path = root/"native_power"/"notifications"/"receipts.jsonl"  (L2339)
//   self.approvals_path            = root/"workflows"/"approvals"/"requests.json"          (L2314)
// where `root` is the data root. PersistenceCore.defaultDataRoot() mirrors the
// daemon's data-root resolution.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Protocol

public protocol NotificationStatusReader: Sendable {
    /// GET /v1/notifications/status — the full status envelope, or nil when no
    /// native status is available.
    func notificationStatus() async -> JSONValue?
}

// MARK: - SwiftNative impl

public struct SwiftNativeNotificationStatus: NotificationStatusReader {
    /// Absolute path to `<dataRoot>/native_power/notifications/receipts.jsonl`.
    public let receiptsPath: URL
    /// Absolute path to `<dataRoot>/workflows/approvals/requests.json`.
    public let approvalsPath: URL
    public let persistence: any PersistenceCoreProtocol
    public let now: @Sendable () -> Date

    public init(
        receiptsPath: URL,
        approvalsPath: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.receiptsPath = receiptsPath
        self.approvalsPath = approvalsPath
        self.persistence = persistence
        self.now = now
    }

    /// Resolve the paths the daemon uses:
    ///   self.notification_actions_path = root/"native_power"/"notifications"/"receipts.jsonl"
    ///   self.approvals_path            = root/"workflows"/"approvals"/"requests.json"
    /// where `root` is the data root. PersistenceCore.defaultDataRoot() mirrors
    /// the daemon's data-root resolution (env NATIVE_AGENT_DATA_ROOT, literal
    /// tilde, default ~/.nativeagent).
    public static func defaultClient(
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) -> SwiftNativeNotificationStatus {
        let root = PersistenceCore.defaultDataRoot()
        return SwiftNativeNotificationStatus(
            receiptsPath: root
                .appendingPathComponent("native_power", isDirectory: true)
                .appendingPathComponent("notifications", isDirectory: true)
                .appendingPathComponent("receipts.jsonl"),
            approvalsPath: root
                .appendingPathComponent("workflows", isDirectory: true)
                .appendingPathComponent("approvals", isDirectory: true)
                .appendingPathComponent("requests.json"),
            persistence: persistence
        )
    }

    public func notificationStatus() async -> JSONValue? {
        // receipts = list(reversed(tail_jsonl(self.notification_actions_path, 20)))
        // -> last 20 receipt lines, NEWEST FIRST. tail_jsonl returns oldest-first
        // (file order); reversed() makes newest-first. Match Python's tail_jsonl
        // DEFAULT scan window of 1 MiB (the retired daemon `max_bytes:
        // int | None = 1_048_576`) — notification_status calls
        // `tail_jsonl(self.notification_actions_path, 20)` with that default, so a
        // huge receipts.jsonl is tail-scanned, NOT fully read. Passing nil would
        // (a) read the whole file unbounded and (b) diverge on receiptCount /
        // latestReceipt for >1 MiB logs. limit:20, maxBytes:1_048_576 are the
        // exact daemon defaults (and the Swift tailJSONL(_:) convenience default).
        var receipts: [JSONValue] = (try? await persistence.tailJSONL(receiptsPath, limit: 20, maxBytes: 1_048_576)) ?? []
        receipts.reverse()

        // pending_approvals = len([item for item in self.list_approval_requests()
        //                          if item.get("status") == "pending"])
        // list_approval_requests = read_json(self.approvals_path, []) then sort.
        // We only need the COUNT of pending items; the sort order is irrelevant to
        // a length, so we skip the sort the daemon applies (a non-pending sort is
        // a no-op for a count). read_json defaults to [] on missing/torn/non-list.
        let approvalsRaw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
        var pendingApprovals = 0
        if case .array(let arr) = approvalsRaw {
            for item in arr {
                if case .object(let obj) = item,
                   case .string(let status)? = obj["status"],
                   status == "pending" {
                    pendingApprovals += 1
                }
            }
        }

        // notification_status() emits createdAt = now_iso() (response timestamp).
        // actionCategories is a fixed literal in the daemon (no data dependency).
        return .object([
            "status": .string("ready"),
            "authorization": .string("app_requested"),
            "actionCategories": .array([
                .object([
                    "id": .string("approval"),
                    "actions": .array([.string("approve"), .string("deny")]),
                    "risk": .string("medium"),
                ]),
                .object([
                    "id": .string("doctor"),
                    "actions": .array([.string("open_doctor"), .string("repair_safe")]),
                    "risk": .string("low"),
                ]),
                .object([
                    "id": .string("mission"),
                    // Wave 5 (P2-6 residue): the EMITTER flips to the canonical
                    // spelling. Safe to flip here and nowhere else because this
                    // id has no consumer — the category array is dropped by
                    // `NotificationRuntimeStatus`'s decoder (it has no
                    // `actionCategories` field), no `UNNotificationCategory` is
                    // ever registered with this id, no delivery handler matches
                    // on `response.actionIdentifier`, and nothing persists it.
                    // Any future reader must go through
                    // `WorkshopOpenNotificationAction.matches`, which still
                    // accepts the legacy `open_mission`.
                    "actions": .array([.string(WorkshopOpenNotificationAction.canonical)]),
                    "risk": .string("low"),
                ]),
            ]),
            "pendingApprovals": .int(Int64(pendingApprovals)),
            "receiptCount": .int(Int64(receipts.count)),
            "latestReceipt": receipts.first ?? .null,
            "createdAt": .string(Self.nowISO(now())),
        ])
    }

    /// Reproduce the daemon's `now_iso()` shape EXACTLY:
    ///   `datetime.now(timezone.utc).isoformat()`
    /// -> microseconds + `+00:00` offset (NOT `Z`), e.g.
    /// "2026-06-02T17:08:42.123456+00:00". The `createdAt` envelope field is the
    /// RESPONSE timestamp and is non-load-bearing (no consumer parses it), so we
    /// always emit 6 fractional digits rather than special-casing zero-fraction.
    static func nowISO(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: date)
    }
}

// MARK: - Factory

/// Returns the SwiftNative reader. The client is injectable for tests;
/// production callers omit it and get `defaultClient()`.
public func makeNotificationStatus(
    client: SwiftNativeNotificationStatus? = nil
) -> any NotificationStatusReader {
    return client ?? SwiftNativeNotificationStatus.defaultClient()
}
