import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `TriggerWireValues.swift` | Trigger configuration, errors, result envelopes and notification values; lossless saved-field round trips |

public enum TriggerSchedulerError: Error, LocalizedError {
    case invalidRequest(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return "schedule_input_invalid: \(msg). Correct the named input in the scheduled Desk task request."
        case .persistenceFailure(let m):
            return """
                schedule_store_unavailable: \(m). Inspect the named scheduler file and repair its contents or access before changing \
                scheduled Desk tasks.
                """
        }
    }
}

/// Preserve unknown top-level fields through extras and per-kind fields through config.
public struct TriggerConfig: Sendable, Equatable {
    public var name: String
    public var enabled: Bool

    public var kind: String?
    public var description: String?

    // Keep per-kind config as an object even when empty so its shape survives round trips.
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
        guard case .string(let nm) = obj["name"] ?? .null, !nm.isEmpty else { return nil }
        self.name = nm
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

public struct TriggerStatus: Sendable, Equatable {
    public var name: String
    public var enabled: Bool?
    public var status: String

    public init(name: String, enabled: Bool?, status: String) {
        self.name = name
        self.enabled = enabled
        self.status = status
    }
}

public struct TriggerFireResult: Sendable, Equatable {
    public var status: String
    public var name: String?
    public var itemId: String?
    public var executionId: String?
    public var deskHandle: String?
    public var stub: Bool?
    public var error: String?
    /// The newly accepted card; nil when an existing card represents the fire.
    public var item: JSONValue?
    /// Whether the router projected transport acceptance or queueing for this card.
    public var notified: Bool?

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

public struct TriggerNotification: Sendable, Equatable {
    public let triggerName: String
    public let kind: String
    public let title: String
    public let body: String
    public let screen: String
    public let source: String
    public let urgency: String
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

/// Delivers an accepted card to snapshots, then optionally notifies. Returns delivery fields or `.null` on failure; delivery never undoes card acceptance.
public typealias TriggerNotifier = @Sendable (TriggerNotification, Bool) async -> JSONValue
