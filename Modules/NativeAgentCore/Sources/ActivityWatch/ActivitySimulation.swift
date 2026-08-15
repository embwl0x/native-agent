import Foundation
import PersistenceCore

/// A scripted timeline of activity events, and the replay harness that drives it
/// through the REAL engine and the REAL store.
///
/// This exists because the capture path cannot be exercised where it matters:
/// AX and the window server are unavailable on a locked machine, and the P0
/// spike proved that what AX *does* answer while locked is plausible garbage. So
/// the state machine is driven from a script instead — and the live watcher runs
/// the same `ActivitySpanEngine` instance type, applying its commands through
/// the same `ActivitySpanStore.apply`. If the simulation is right, the live path
/// is right, because there is only one path.
public struct ActivityScript: Sendable, Equatable {
    public let version: Int
    public let policy: ActivityPolicy
    public let events: [ActivityInputEvent]
    /// Fixed offset recorded on every span the replay writes. Pinned in the
    /// script (not read from the host) so a replay is reproducible on any
    /// machine in any timezone.
    public let tzOffsetMin: Int
    /// When true, span ids are `sim-0`, `sim-1`, … instead of UUIDs, so a
    /// replay's output can be diffed byte-for-byte.
    public let deterministicIDs: Bool

    public init(
        version: Int = 1,
        policy: ActivityPolicy,
        events: [ActivityInputEvent],
        tzOffsetMin: Int = 0,
        deterministicIDs: Bool = true
    ) {
        self.version = version
        self.policy = policy
        self.events = events
        self.tzOffsetMin = tzOffsetMin
        self.deterministicIDs = deterministicIDs
    }

    public enum ParseError: Error, CustomStringConvertible {
        case notAnObject
        case unsupportedVersion(Int)
        case missingEvents
        case badEvent(index: Int, reason: String)

        public var description: String {
            switch self {
            case .notAnObject:
                return "script must be a JSON object"
            case .unsupportedVersion(let version):
                return "unsupported script version \(version) (expected 1)"
            case .missingEvents:
                return "script has no \"events\" array"
            case .badEvent(let index, let reason):
                return "events[\(index)]: \(reason)"
            }
        }
    }

    // MARK: Parsing

    public static func parse(data: Data) throws -> ActivityScript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        let version = root["version"] as? Int ?? 1
        guard version == 1 else { throw ParseError.unsupportedVersion(version) }

        var policy = ActivityPolicy()
        if let policyObject = root["policy"] {
            let policyData = try JSONSerialization.data(withJSONObject: policyObject)
            policy = try JSONDecoder().decode(ActivityPolicy.self, from: policyData)
        }

        guard let rawEvents = root["events"] as? [[String: Any]] else {
            throw ParseError.missingEvents
        }

        var events: [ActivityInputEvent] = []
        for (index, raw) in rawEvents.enumerated() {
            guard let type = raw["type"] as? String else {
                throw ParseError.badEvent(index: index, reason: "missing \"type\"")
            }
            guard let at = (raw["at"] as? NSNumber)?.doubleValue else {
                throw ParseError.badEvent(index: index, reason: "missing numeric \"at\"")
            }
            switch type {
            case "activate":
                guard let bundleId = raw["bundleId"] as? String else {
                    throw ParseError.badEvent(index: index, reason: "activate needs \"bundleId\"")
                }
                let appName = raw["appName"] as? String ?? bundleId
                events.append(.activate(bundleId: bundleId, appName: appName, at: at))
            case "focusEvent":
                events.append(.focusEvent(at: at))
            case "titleChange":
                events.append(.titleChange(raw: raw["raw"] as? String, at: at))
            case "idle":
                events.append(.idle(at: at))
            case "lock":
                events.append(.lock(at: at))
            case "unlock":
                events.append(.unlock(at: at))
            case "sleep":
                events.append(.sleep(at: at))
            case "wake":
                events.append(.wake(at: at))
            case "terminate":
                events.append(.terminate(at: at))
            case "crash":
                events.append(.crash(at: at))
            case "heartbeat":
                events.append(.heartbeat(at: at))
            default:
                throw ParseError.badEvent(index: index, reason: "unknown type \"\(type)\"")
            }
        }

        return ActivityScript(
            version: version,
            policy: policy,
            events: events,
            tzOffsetMin: (root["tzOffsetMin"] as? NSNumber)?.intValue ?? 0,
            deterministicIDs: (root["deterministicIDs"] as? Bool) ?? true
        )
    }

    /// Machine-readable description of the script format, emitted by
    /// `activity-probe simulate --emit-schema`.
    public static func schemaJSON() -> String {
        """
        {
          "version": 1,
          "description": "Scripted timeline replayed through the REAL ActivitySpanEngine and the REAL ActivitySpanStore. No window server, no AX, no LLM.",
          "fields": {
            "version": "int, must be 1",
            "tzOffsetMin": "int, UTC offset in minutes recorded on every span written by this replay (default 0). Provenance only -- rollups re-bucket in the asking timezone.",
            "deterministicIDs": "bool, default true. Span ids become sim-0, sim-1, ... so output can be diffed.",
            "policy": "object, an ActivityPolicy. Omitted keys take the SAFE default, which means captureEnabled=false and NOTHING is captured.",
            "events": "array, the timeline. Processed in the order given."
          },
          "policy": {
            "captureEnabled": "bool, default false -- the master switch",
            "captureTitles": "bool, default false",
            "browserTitlesEnabled": "bool, default false -- browser titles need BOTH this and captureTitles",
            "appNameOnlyMode": "bool, default false -- global override, no titles anywhere",
            "excludedBundleIDs": "array of strings, default is the shipped starter list (password managers, Keychain, health, finance)",
            "retentionDays": "int, default 30"
          },
          "events": [
            { "type": "activate",    "bundleId": "com.apple.Terminal", "appName": "Terminal", "at": 1700000000.0 },
            { "type": "focusEvent",  "at": 1700000010.0 },
            { "type": "titleChange", "raw": "notes.md - Terminal", "at": 1700000020.0 },
            { "type": "heartbeat",   "at": 1700000080.0 },
            { "type": "idle",        "at": 1700000300.0 },
            { "type": "lock",        "at": 1700000400.0 },
            { "type": "unlock",      "at": 1700000500.0 },
            { "type": "sleep",       "at": 1700000600.0 },
            { "type": "wake",        "at": 1700000700.0 },
            { "type": "terminate",   "at": 1700000800.0 },
            { "type": "crash",       "at": 1700000900.0 }
          ],
          "semantics": {
            "activate": "Frontmost app changed. Closes the open span (appChange) and opens a new one. An EXCLUDED bundle id closes the open span and opens nothing -- the exclusion is checked BEFORE any title read.",
            "focusEvent": "AX focus notification. Advances last_seen_at and bumps event_count.",
            "titleChange": "\\"raw\\" is the UNREDACTED title. It is redacted via MacScreenViewTextRedaction before it can touch a span; a secret-shaped title becomes \\"[redacted]\\". The span's FIRST title is its INITIAL title: it is stamped onto the open row in place (retitle) and counted as an event -- it does NOT split the span. Only a title arriving when the span ALREADY has one is a window change, which closes the span (windowChange) and opens a successor carrying the new title. An unchanged title is just an event. With captureTitles=false the title is dropped and only the event is recorded.",
            "idle": "Idle deadline elapsed. Closes the span (idle).",
            "lock": "Screen locked. Closes the span (lock). NOTHING is written until unlock.",
            "unlock": "Clears the lock gate. Opens no span -- the live watcher re-seeds from the frontmost app, which arrives as an activate.",
            "sleep": "Closes the span (sleep) and gates writes, same as lock.",
            "wake": "Clears the sleep gate. Opens no span.",
            "terminate": "Observed app quit or clean shutdown. Closes the span (quit).",
            "crash": "Process died. Emits NO close -- the row stays open with its last_seen_at, and the next event triggers startup reconciliation, which closes it AT last_seen_at with close_reason=abandoned.",
            "heartbeat": "60s liveness tick. Advances last_seen_at WITHOUT bumping event_count."
          },
          "invariants": {
            "no_zero_length_spans_from_the_first_title": "an activate immediately followed by the window's title (microseconds apart, which is what the LIVE watcher does) yields ONE span, not a 0 s row plus a successor",
            "every_open_has_one_close": "except a crash, which is settled by reconcileAbandoned",
            "nothing_while_gated": "no row is written between lock/sleep and unlock/wake",
            "last_seen_advances_on_every_event": "not just the heartbeat",
            "monotonic": "no emitted timestamp is earlier than the previous one; a backwards clock step yields a zero-length interval, never a negative or fabricated one; a new span's start is floored at the last emitted close"
          }
        }
        """
    }
}

// MARK: - Replay

public struct ActivitySimulator: Sendable {
    /// Replay a script through the real engine into the real store.
    ///
    /// - Returns: every span in the database afterwards, in start order.
    @discardableResult
    public static func replay(
        _ script: ActivityScript,
        into store: ActivitySpanStore
    ) async throws -> [ActivitySpan] {
        let counter = IDCounter()
        let deterministic = script.deterministicIDs
        var engine = ActivitySpanEngine(
            policy: script.policy,
            tzOffsetMin: script.tzOffsetMin,
            makeID: { deterministic ? "sim-\(counter.next())" : UUID().uuidString }
        )

        // Startup reconciliation, exactly as the live probe does on launch.
        try await store.apply(engine.startupReconcile())

        for event in script.events {
            try await store.apply(engine.process(event))
        }

        // The replay ends as an unclean exit would NOT: a script that wants a
        // dangling open row must end on `crash`. Anything still open here is
        // the script's intent, so it is left open and reported as such.
        let all = try await store.querySpans(
            from: 0, to: Double.greatestFiniteMagnitude, limit: 100_000
        )
        return all
    }

    /// Small monotonic counter for deterministic span ids.
    private final class IDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            defer { value += 1 }
            return value
        }
    }

    /// JSON rendering of replay output, used by `activity-probe simulate`.
    public static func spansJSON(_ spans: [ActivitySpan]) -> String {
        let objects: [[String: Any]] = spans.map { span in
            var object: [String: Any] = [
                "id": span.id,
                "started_at": span.startedAt,
                "ended_at": span.endedAt as Any,
                "last_seen_at": span.lastSeenAt,
                "bundle_id": span.bundleId,
                "app_name": span.appName,
                "event_count": span.eventCount,
                "close_reason": span.closeReason?.rawValue as Any,
                "tz_offset_min": span.tzOffsetMin,
                "duration": span.duration,
            ]
            object["ended_at"] = span.endedAt ?? NSNull()
            object["close_reason"] = span.closeReason?.rawValue ?? NSNull()
            object["title_redacted"] = span.titleRedacted ?? NSNull()
            return object
        }
        let payload: [String: Any] = ["spans": objects, "count": objects.count]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{\"spans\": [], \"count\": 0}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
