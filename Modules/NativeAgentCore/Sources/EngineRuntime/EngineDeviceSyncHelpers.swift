import Foundation
import AuthoredCapabilities
import BackgroundWork
import DeviceSync
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import ChatToolRuntime
import Experiences
// Blueprint: | `EngineDeviceSyncHelpers.swift` | `botsShelfRead`, the phone's helpers snapshot and its agent thread: read, or the person's words sent through the door |

extension NativeAgentEngine {
    public func deviceHelpersSnapshot() async throws -> MobileHelpersSnapshot {
        let root = dataRoot
        let records = try await botsShelfRead()
        return try await Task.detached(priority: .utility) {
            let threads = try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts)
            var snapshot = MobileHelpersSnapshot()
            for record in records.prefix(100) {
                var row = MobileHelperRow(id: record.id, name: record.definition.name,
                    status: record.statusWord,
                    paused: record.definition.paused,
                    canPause: record.definition.cadence != .manual || record.definition.eventTrigger != nil || record.definition.paused)
                row.revision = record.definition.updatedAt.timeIntervalSinceReferenceDate
                if let latest = try await AgentContactThreads.helperResults(record, root: root, historyLimit: 0).latestCompleted {
                    row.resultID = latest.id.uuidString
                    row.resultPreview = latest.preview.map {
                        MobileDeskProjectionBounds.clipped($0, to: 160)
                    }
                }
                snapshot.helpers.append(row)
            }
            snapshot.agents = threads.prefix(100).map { $0.agent.summary }
            snapshot.truncated = records.count > 100 || threads.count > 100
            return snapshot
        }.value
    }

    /// The phone's agent thread: read it, or send the person's own words to that agent through the door (`agent.send`) as the act of the
    /// paired phone the router verified, then read it again.
    public func deviceAgentThreadAction(action: String, payload: [String: String], device: String) async throws -> [String: String] {
        let root = dataRoot
        guard let id = payload["id"] else { throw HelperRemoteError.invalid }
        let threads = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts) }.value
        guard threads.contains(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        var refreshed = threads
        if action == "send_agent_message" {
            guard let text = payload["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let session = payload["session_id"] else { throw HelperRemoteError.session }
            let call = PartFace.Call("agent.send", ["agent": .string(id), "value": .string(text), "session": .string(session)])
            do {
                let outcome = try await tools.personTap(call, PartFaces.Tap(page: "agents", row: id, action: "agent.send", door: "phone", device: device,
                    chat: nil, decided: true))
                if outcome.unresolved {
                    return ["status": "outcome_unknown", "effects": outcome.effects.rawValue,
                            "message": outcome.failure?.localizedDescription ?? outcome.words ?? "The send's outcome is unconfirmed. Read the agent thread before sending again."]
                }
                if let failure = outcome.failure { throw failure }
            } catch let refused as PartCallError {
                return ["status": "error", "message": refused.message]
            }
            refreshed = try await Task.detached(priority: .utility) { try await AgentContactThreads.mobileThreads(root: root, contacts: self.contacts) }.value
        }
        guard let thread = refreshed.first(where: { $0.agent.id == id }) else { throw HelperRemoteError.contact }
        return ["status": "ok", "thread": String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)]
    }
}

private enum HelperRemoteError: LocalizedError {
    case invalid, contact, session
    var errorDescription: String? {
        switch self {
        case .invalid: "Name the agent this thread is with."
        case .contact: "This agent is no longer reachable. Refresh the Agents page."
        case .session: "Open a chat before sending to an agent. Messages must be between 1 and 16,000 characters."
        }
    }
}

extension NativeAgentEngine {
    public func botsShelfRead(unattendedChanged: @MainActor (Bool) -> Void = { _ in }) async throws -> [BotsShelfRecord] {
        let root = dataRoot
        let timing = try await bots.effectiveSchedule()
        await unattendedChanged(timing.unattended)
        let followingModel = try? await SwiftNativeProviderRouting(dataRoot: root).modelForSurface("chat").model
        return try await Task.detached(priority: .userInitiated) {
            try BotsShelfRecord.read(root: root, timing: timing, followingModel: followingModel)
        }.value
    }
}
