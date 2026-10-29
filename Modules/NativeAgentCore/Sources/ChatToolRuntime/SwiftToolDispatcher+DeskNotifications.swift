import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import ToolExecution
import AuthoredCapabilities
import StandingBots
import Research
import CryptoKit
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `SwiftToolDispatcher+DeskNotifications.swift` | `SwiftToolDispatcher`: item notification preferences and explicit nag controls; permanent-handle scopes, mute windows, proposal validation and unmute drift settlement |

extension SwiftToolDispatcher {
    func impl_desk_set_notify(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let levelRaw = try deskString(input, "level").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let level = NotifyLevel(rawValue: levelRaw) else {
            throw deskInvalid("level",
                reason: "desk_set_notify: unknown level '\(levelRaw)' (expected one of \(NotifyLevel.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let policy = NotifyPolicy(
            level: level,
            on: deskCSV(input, "on"),
            cooldown: optionalString(input, "cooldown")
        )
        let store = deskStore()
        _ = try await store.setNotify(handle, policy: policy)
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "notify \(level.rawValue)")
    }

    /// Explicit notification controls never infer the person’s intent.
    /// Unmute clears the mute, opens a new attention window, re-arms each item’s nag
    /// and returns the drift digest in the same reply.
    func impl_desk_nag_control(input: [String: JSONValue]) async throws -> JSONValue {
        let action = try deskString(input, "action")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kindRaw = (optionalString(input, "scope_kind") ?? "global")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["global", "project", "item"].contains(kindRaw) else {
            throw deskInvalid("scope_kind",
                reason: "desk_nag_control: unknown scope_kind '\(kindRaw)' (expected global|project|item)")
        }
        let scopeIdRaw = optionalString(input, "scope_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let untilRaw = optionalString(input, "until")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configStore = DeskNagConfigStore(dataRoot: dataRoot)

        switch action {
        case "enable", "disable":
            let on = (action == "enable")
            switch kindRaw {
            case "global":
                let next = try await configStore.update { $0.settingGlobal(on) }
                return .object([
                    "status": .string("ok"),
                    "confirmation": .string("nagging \(on ? "ON" : "OFF") globally (window \(next.windowId))"),
                    "config": deskNagConfigJSON(next),
                ])
            case "project":
                guard let scopeIdRaw, !scopeIdRaw.isEmpty else {
                    throw deskInvalid("scope_id", reason: "desk_nag_control: scope_kind 'project' needs scope_id (the project name)")
                }
                let next = try await configStore.update { $0.settingScope(kind: .project, id: scopeIdRaw, enabled: on) }
                return .object([
                    "status": .string("ok"),
                    "confirmation": .string(deskNagScopeConfirmation(
                        "project \(scopeIdRaw)", on: on, config: next)),
                    "config": deskNagConfigJSON(next),
                ])
            default:
                guard let scopeIdRaw, !scopeIdRaw.isEmpty else {
                    throw deskInvalid("scope_id", reason: "desk_nag_control: scope_kind 'item' needs scope_id (the desk number or handle)")
                }
                // Resolve visible numbers to stable handles before persisting scope identity.
                let handle = try resolveDeskRef(scopeIdRaw, in: try await deskStore().liveState(), field: "scope_id")
                let next = try await configStore.update { $0.settingScope(kind: .item, id: handle, enabled: on) }
                let alias = (try? await deskStore().liveState())?.items.first { $0.handle == handle }?.alias
                return .object([
                    "status": .string("ok"),
                    "handle": .string(handle),
                    "confirmation": .string(deskNagScopeConfirmation(
                        "item \(alias ?? handle)", on: on, config: next)),
                    "config": deskNagConfigJSON(next),
                ])
            }

        case "mute":
            // Refuse bad dates instead of muting indefinitely.
            if let untilRaw, !untilRaw.isEmpty, !DeskClock.isParseableDate(untilRaw) {
                return .object([
                    "status": .string("refused"),
                    "reason": .string("desk_nag_control: cannot mute until '\(untilRaw)' — expected a yyyy-MM-dd day or a full ISO timestamp (omit `until` to mute indefinitely)"),
                ])
            }
            let next = try await configStore.update { $0.muted(until: untilRaw?.isEmpty == false ? untilRaw : nil) }
            let phrase = (next.mutedUntil == DeskNagConfig.indefiniteMuteSentinel)
                ? "indefinitely" : "until \(next.mutedUntil ?? "?")"
            return .object([
                "status": .string("ok"),
                "confirmation": .string("nagging muted \(phrase) — still tracking, nothing will ping"),
                "config": deskNagConfigJSON(next),
            ])

        case "unmute", "proposal":
            // AppChatToolDispatcher.withAuthoredProgramHost binds the originating door.
            let preview = action == "proposal"
            let read = try await DeskNotificationRead.read(dataRoot: dataRoot, now: Date(), unmute: !preview)
            let proposal: DeskNotificationProposal
            switch await Parts(root: dataRoot).call(id: "desk-notify", input: read.input, preview: preview, as: DeskNotificationProposal.self) {
            case .success(let value): proposal = value
            case .failure(let error): throw error
            }
            if preview {
                try read.validate(proposal)
                return .object(["status": .string("ok"), "effects": .string("none"),
                    "as_of": .string(read.state.generatedTs), "evaluated_at": .double(read.now.timeIntervalSince1970),
                    "proposal": try .fromEncodable(proposal)])
            }
            let next = try await read.commit(proposal, dataRoot: dataRoot)
            let digest = proposal.digest
            let summary = digest.isEmpty
                ? "nagging back on (window \(next.windowId)) — nothing drifted while you were quiet"
                : "nagging back on (window \(next.windowId)) — \(digest.count) item(s) moved while quiet"
            return .object([
                "status": .string("ok"),
                "confirmation": .string(summary),
                "drift": .array(digest.map { .string($0) }),
                "config": deskNagConfigJSON(next),
            ])

        case "status", "read":
            let config = await configStore.load()
            let muted = config.isMuted(now: Date())
            var lines: [String] = ["nagging \(config.enabled ? "ON" : "OFF") globally · window \(config.windowId)"]
            if muted {
                lines.append(config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
                    ? "muted indefinitely" : "muted until \(config.mutedUntil ?? "?")")
            } else if config.mutedUntil != nil {
                lines.append("mute has elapsed (\(config.mutedUntil ?? "")) — the next tick reports the drift")
            }
            if config.scopes.isEmpty {
                lines.append("no scopes — nothing nags until you name a project or item")
            } else {
                for scope in config.scopes {
                    lines.append("  \(scope.kind.rawValue) \(scope.id): \(scope.enabled ? "on" : "off")")
                }
            }
            lines.append("\(config.ledger.count) item(s) already nagged in this window; \(config.observed.count) tracked")
            return .object([
                "status": .string("ok"),
                "summary": .string(lines.joined(separator: "\n")),
                "config": deskNagConfigJSON(config),
            ])

        default:
            throw deskInvalid("action",
                reason: "desk_nag_control: unknown action '\(action)' (expected enable|disable|mute|unmute|proposal|status|read)")
        }
    }

    /// Scope confirmation names a disabled global switch so it cannot imply live notifications.
    private func deskNagScopeConfirmation(_ label: String, on: Bool, config: DeskNagConfig) -> String {
        let base = "nagging \(on ? "ON" : "OFF") for \(label)"
        if on && !config.enabled {
            return base + " — but the GLOBAL nag switch is off, so nothing will ping until you enable it"
        }
        return base
    }

    /// Return the whole config, including its ledger.
    private func deskNagConfigJSON(_ config: DeskNagConfig) -> JSONValue {
        config.toJSON()
    }
}
