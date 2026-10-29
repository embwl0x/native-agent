import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
// Blueprint: | `TriggerWireValues.swift` | Trigger configuration, errors, result envelopes and notification values; lossless saved-field round trips |

/// Invalid trigger input or unavailable configuration storage.
public enum TriggerSchedulerError: Error, LocalizedError {
    case invalidRequest(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return "schedule_input_invalid: \(msg). Correct the named input in the scheduled Desk task request."
        case .persistenceFailure(let m): return "schedule_store_unavailable: \(m). Inspect the named scheduler file and repair its contents or access before changing scheduled Desk tasks."
        }
    }
}

/// Preserve unknown top-level fields through extras and per-kind fields through config.
public struct TriggerConfig: Sendable, Equatable {
    // Required.
    public var name: String
    public var enabled: Bool

    // Optional typed fields. Absent → nil. Present → some(v).
    public var kind: String?
    public var description: String?

    // The trigger's own `config` dict — flexible bag of per-kind keys
    // (paths/hour/minute/idle_minutes/etc.). Always JSONValue.object(...)
    // when present, even if empty.
    public var config: JSONValue?

    /// Lossless unknown top-level fields, including execution metadata and saved migration markers.
    public var extras: JSONValue?

    public init(
        name: String,
        enabled: Bool,
        kind: String? = nil,
        description: String? = nil,
        config: JSONValue? = nil,
        extras: JSONValue? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.description = description
        self.config = config
        self.extras = extras
    }
}

extension TriggerConfig {
    /// Typed keys this struct claims directly. Everything else round-trips via extras.
    static let typedKeys: Set<String> = ["name", "enabled", "kind", "description", "config"]

    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        // name is required and must be non-empty.
        guard case .string(let nm) = obj["name"] ?? .null, !nm.isEmpty else { return nil }
        self.name = nm
        // Missing or non-Boolean enabled values are false.
        if case .bool(let b) = obj["enabled"] ?? .null {
            self.enabled = b
        } else {
            self.enabled = false
        }
        if case .string(let s) = obj["kind"] ?? .null { self.kind = s } else { self.kind = nil }
        if case .string(let s) = obj["description"] ?? .null { self.description = s } else { self.description = nil }
        if let v = obj["config"], case .object = v {
            self.config = v
        } else {
            self.config = nil
        }
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !TriggerConfig.typedKeys.contains(k) {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "enabled": .bool(enabled),
        ]
        if let kind { obj["kind"] = .string(kind) }
        if let description { obj["description"] = .string(description) }
        if let config { obj["config"] = config }
        if case .object(let extra)? = extras {
            for (k, v) in extra where !TriggerConfig.typedKeys.contains(k) {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

/// Enable/disable result with name, optional enabled state and status.
public struct TriggerStatus: Sendable, Equatable {
    public var name: String
    public var enabled: Bool?
    public var status: String     // "updated" | "not_found"

    public init(name: String, enabled: Bool?, status: String) {
        self.name = name
        self.enabled = enabled
        self.status = status
    }
}

/// Fire result with optional inbox-card or Workshop execution identity.
public struct TriggerFireResult: Sendable, Equatable {
    public var status: String           // "fired" | "not_found" | "error"
    public var name: String?
    public var itemId: String?          // inbox
    public var executionId: String?       // Workshop execution
    public var deskHandle: String?      // Workshop identity for scheduled work
    public var stub: Bool?              // inbox only
    public var error: String?
    /// The newly accepted card; nil when an existing card represents the fire.
    public var item: JSONValue?         // inbox only
    /// Whether notification delivery handled this accepted card.
    public var notified: Bool?          // inbox only

    public init(
        status: String,
        name: String? = nil,
        itemId: String? = nil,
        executionId: String? = nil,
        deskHandle: String? = nil,
        stub: Bool? = nil,
        error: String? = nil,
        item: JSONValue? = nil,
        notified: Bool? = nil
    ) {
        self.status = status
        self.name = name
        self.itemId = itemId
        self.executionId = executionId
        self.deskHandle = deskHandle
        self.stub = stub
        self.error = error
        self.item = item
        self.notified = notified
    }
}

/// What a fired trigger asks the app to push. App-agnostic by construction.
public struct TriggerNotification: Sendable, Equatable {
    public let triggerName: String
    public let kind: String
    public let title: String
    public let body: String        // the item summary, truncated for a push
    public let screen: String      // "inbox"
    public let source: String      // "trigger:<name>"
    public let urgency: String     // severity-derived: important → "high"
    /// The accepted card and its stable inbox identity.
    public var ownerWaiting: Bool { kind != "time" && urgency == "high" }
    public let itemId: String
    public let item: JSONValue

    public init(
        triggerName: String, kind: String, title: String, body: String,
        screen: String, source: String, urgency: String,
        itemId: String = "", item: JSONValue = .null
    ) {
        self.triggerName = triggerName
        self.kind = kind
        self.title = title
        self.body = body
        self.screen = screen
        self.source = source
        self.urgency = urgency
        self.itemId = itemId
        self.item = item
    }
}

/// Delivers an accepted card to snapshots, then optionally notifies. Returns
/// delivery fields or `.null` on failure; delivery never undoes card acceptance.
public typealias TriggerNotifier = @Sendable (TriggerNotification, Bool) async -> JSONValue
