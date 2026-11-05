import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `MorningBriefAssembly.swift` | Authored brief cards and inactive schedule defaults |

extension SwiftNativeTriggerScheduler {
    // MARK: InboxItem builder

    internal func _buildMorningBriefItem() async throws -> JSONValue {
        let id = uuid()
        let createdAt = Self.isoTimestamp(now())

        let packet = await MorningBriefSources(root: root, now: now(), worklogPath: worklogPath).packet()
        let built = try await callBrief(packet, as: MorningBriefProposal.self)

        let item: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "source": .string("trigger:morning_brief"),
            "presentation": built.presentation,
            "severity": .string("important"),
            "title": .string(built.title),
            "summary": .string(built.summary),
            "detail": built.detail,
            "related_execution_id": .null,
            "related_approval_id": .null,
            "related_paths": .null,
            "related_groups": .null,
            "actions": built.actions,
            "status": .string("unread"),
            "read_at": .null,
        ])
        return item
    }

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    // MARK: Authored brief and inactive defaults

    private func callBrief<Value: Decodable>(_ input: JSONValue, as: Value.Type) async throws -> Value {
        guard let morningBriefPart else {
            throw TriggerSchedulerError.persistenceFailure("The native-morning-brief part has no originating app door.")
        }
        let value = try await morningBriefPart(input)
        return try JSONDecoder().decode(Value.self, from: value.serializedData(pretty: false))
    }

    internal func defaults() async throws -> MorningBriefDefaults {
        var value = try await callBrief(.object(["operation": .string("defaults")]), as: MorningBriefDefaults.self)
        // Seed behavior is not consent: only an explicit enable mutation activates the schedule.
        func inactive(_ rows: [JSONValue]) -> [JSONValue] {
            rows.map { row in
                guard case .object(var fields) = row else { return row }
                fields["enabled"] = .bool(false)
                return .object(fields)
            }
        }
        value.inbox = inactive(value.inbox)
        return value
    }
}
