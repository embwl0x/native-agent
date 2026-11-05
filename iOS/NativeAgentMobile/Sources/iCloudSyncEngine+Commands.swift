import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Commands.swift` | Subject commands and receipt adoption through the signed action transaction |

extension iCloudSyncEngine {
    // MARK: - Higher-level mutation helpers

    // A Desk task waits on its original identity; a refusal never submits another task.

    @discardableResult
    func approveApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "approveApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionAndWait(action))
    }

    @discardableResult
    func rejectApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "rejectApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionAndWait(action))
    }

    @discardableResult
    func cancelApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "cancelApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionAndWait(action))
    }

    private func adoptApprovalResponse(_ response: [String: String]) throws -> [String: String] {
        // Approval decision settlement is independent of execution success.
        if let json = response["approvalJSON"], let id = response["approvalId"],
           let revision = response["approvalReadbackRevision"].flatMap(Double.init) {
            let row = try JSONDecoder().decode(ApprovalRequest?.self, from: Data(json.utf8))
            if installReadback(revision: revision, file: "approvals.json", id: id) {
                if let index = approvals.firstIndex(where: { $0.id == id }) {
                    if let row { approvals[index] = row } else { approvals.remove(at: index) }
                } else if let row { approvals.append(row) }
            }
        }
        return try requireSuccessfulActionResponse(response)
    }

    @discardableResult
    func approveMemoryProposal(proposalId: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "approveMemoryProposal", payload: ["proposalId": proposalId])
        return try adoptMemoryResponse(await sendDecisionActionAndWait(action))
    }

    @discardableResult
    func rejectMemoryProposal(proposalId: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "rejectMemoryProposal", payload: ["proposalId": proposalId])
        return try adoptMemoryResponse(await sendDecisionActionAndWait(action))
    }

    private func adoptMemoryResponse(_ response: [String: String]) throws -> [String: String] {
        if let id = response["resolvedProposalId"],
           let revision = response["memoryReadbackRevision"].flatMap(Double.init),
           installReadback(revision: revision, file: "memory_proposals.json", id: id) {
            memoryProposals.removeAll { $0.id == id }
            memoryProposalsSnapshotLoaded = true
        }
        if let id = response["memoryId"], let json = response["memoryJSON"],
           let revision = response["memoryReadbackRevision"].flatMap(Double.init) {
            let row = try JSONDecoder().decode(MemoryRecord?.self, from: Data(json.utf8))
            if installReadback(revision: revision, file: "memories.json", id: id) {
                memories.removeAll { $0.id == id }
                if let row { memories.insert(row, at: 0) }
            }
        }
        return try requireSuccessfulActionResponse(response)
    }

    @discardableResult
    func inboxAction(itemId: String, actionId: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "inboxAction", payload: [
            "itemId": itemId,
            "actionId": actionId,
        ])
        let response = try await sendActionAndWait(action)
        if let id = response["inboxItemId"], let json = response["inboxItemJSON"],
           let revision = response["inboxReadbackRevision"].flatMap(Double.init) {
            let row = try JSONDecoder().decode(InboxItemRecord?.self, from: Data(json.utf8))
            if installReadback(revision: revision, file: "inbox.json", id: id) {
                if let index = inboxItems.firstIndex(where: { $0.id == id }) {
                    if let row { inboxItems[index] = row } else { inboxItems.remove(at: index) }
                } else if let row { inboxItems.insert(row, at: 0) }
                inboxSnapshotLoaded = true
            }
        }
        return try adoptApprovalResponse(response)
    }

    /// A face row's action, answered by the page's owner on the Mac: its words, or its refusal thrown.
    func faceAction(page: String, row: String, action: String, value: String?) async throws -> String? {
        var payload = ["page": page, "row": row, "action": action]
        if let value { payload["value"] = value }
        let response = try await sendActionAndWait(InboxAction.make(action: "faceAction", payload: payload))
        return try requireSuccessfulActionResponse(response)["message"]
    }

    @discardableResult
    func registerPushToken(token: String, environment: String, bundleId: String, deviceId: String = "ios") async throws -> [String: String] {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject invalid tokens before registration freshness can advance.
        guard !cleanToken.isEmpty else {
            throw SyncError.unsupported("Missing APNS device token")
        }
        let action = InboxAction.make(action: "registerPushToken", payload: [
            "token": cleanToken,
            "environment": environment,
            "bundleId": bundleId,
            "deviceId": deviceId,
        ])
        return try requireSuccessfulActionResponse(await sendActionAndWait(action, pollTimeoutSeconds: 45))
    }

    // MARK: - Mac Control (iOS → Mac remote actions)
    // Mac authority checks own control admission; all actions retain signed retry identity.
    private func macControlResult(_ action: InboxAction, pollTimeoutSeconds: Double = 120) async throws -> String {
        let raw = try await sendActionAndWait(action, pollTimeoutSeconds: pollTimeoutSeconds)
        let result = try requireSuccessfulActionResponse(
            raw
        )
        if result["blocked"] == "true" {
            throw SyncError.unsupported(result["message"] ?? result["error"] ?? result["code"] ?? "Mac control denied.")
        }
        return result["result"] ?? result["message"] ?? result["status"] ?? "ok"
    }

    private func sendMacControl(_ action: PhoneMacControlAction, arguments: [String: String]) async throws -> String {
        try await macControlResult(InboxAction.make(action: "mac_control", payload: action.payload(arguments)))
    }

    func macNotify(title: String, message: String, sound: String? = nil) async throws -> String {
        var arguments = ["title": title, "message": message]
        if let sound { arguments["sound"] = sound }
        return try await sendMacControl(.notification, arguments: arguments)
    }

    func macSetVolume(percent: Int) async throws -> String {
        guard MacVolumeControlPresentation.isValid(percent: percent) else {
            throw SyncError.unsupported("Volume must be between 0% and 100%.")
        }
        return try await sendMacControl(.volume, arguments: ["value": "\(percent)"])
    }

    func macSpotlight(query: String, hoursAhead: Int? = nil, limit: Int? = nil) async throws -> String {
        var arguments = ["query": query]
        if let hoursAhead { arguments["hours_ahead"] = "\(hoursAhead)" }
        if let limit { arguments["limit"] = "\(limit)" }
        return try await sendMacControl(.spotlight, arguments: arguments)
    }

    // MARK: - Telegram control
    func disconnectTelegram() async throws -> MobileTelegramSnapshot {
        let lifecycle = lifecycleGeneration
        let action = InboxAction.make(action: "disconnect_telegram", payload: ["confirmed": "true"])
        let response = try requireSuccessfulActionResponse(await sendActionAndWait(action))
        guard let json = response["telegram"],
              let recovered = try? JSONDecoder().decode(MobileTelegramSnapshot.self, from: Data(json.utf8)) else {
            throw SyncError.unsupported("The Mac did not return readable Telegram settings. Refresh before trying again.")
        }
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        applyTelegramSnapshot(recovered)
        return recovered
    }

    // MARK: - Provider control (signed actions; credential bodies are encrypted)

    func answerInteraction(_ card: InlineInteraction, sessionID: String, actionName: String,
                           values: [String: String] = [:]) async throws -> [String: String] {
        guard let secret = pairingStore?.iCloudPairingSecret else { throw SyncError.notSigned }
        var action = InboxAction.make(action: "interaction_action", payload: [:])
        var fields = values
        fields["sessionID"] = sessionID
        fields["interactionID"] = card.id
        fields["revision"] = String(card.revision)
        fields["action"] = actionName
        action.payload = [SecretActionEnvelope.field: try SecretActionEnvelope.seal(fields, secret: secret,
            actionID: action.msgId, actionName: action.action)]
        return try requireSuccessfulActionResponse(await sendActionAndWait(action,
            intentionalNewRequest: true, pollTimeoutSeconds: 90))
    }

    /// Commit the full tuple atomically through ProviderRouting; Chat metadata is not routing authority.
    func configureSurfaceSelection(
        surface: String,
        providerId: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String
    ) async throws {
        let lifecycle = lifecycleGeneration
        let action = InboxAction.make(action: "configure_surface_selection", payload: [
            "surface": surface,
            "provider_id": providerId,
            "model": model,
            "reasoning_effort": reasoningEffort,
            "service_tier": serviceTier,
        ])
        let result = try requireSuccessfulActionResponse(await sendActionAndWait(action))
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        func required(_ key: String) throws -> String {
            guard let value = result[key], !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw SyncError.persistence("Mac selection response omitted canonical \(key) state")
            }
            return value
        }
        let expected = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let confirmed = try required("surface")
        let surfaces = try required("surfaces").split(separator: ",").map(String.init)
        let preference = NAProviderSurfaceSelection(
            providerID: try required("provider_id"), model: try required("model"),
            reasoningEffort: try required("reasoning_effort"), serviceTier: try required("service_tier")
        )
        guard confirmed == expected, surfaces.contains(confirmed),
              preference.serviceTier == "default" || preference.serviceTier == "priority" else {
            throw SyncError.persistence("Mac selection response did not confirm the requested surface's canonical tuple")
        }
        guard let revision = result["modelReadbackRevision"].flatMap(Double.init) else {
            throw SyncError.persistence("The Mac did not return the saved model selection revision.")
        }
        for surface in surfaces where revision >= (surfaceModelRevisions[surface] ?? 0) {
            surfaceModelRevisions[surface] = revision
            surfaceModels[surface] = preference
        }
    }

    func refreshAppSettings() async {
        guard !appSettingsLoading, appSettingsSaving.isEmpty else { return }
        appSettingsLoading = true
        defer { appSettingsLoading = false }
        let lifecycle = lifecycleGeneration
        do {
            _ = try await appSettingsRead.read({
                let result = try requireSuccessfulActionResponse(await sendActionAndWait(
                    .make(action: "app_settings", payload: [:])))
                guard let raw = result["settings"] else { throw SyncError.persistence("The Mac did not return its settings.") }
                guard lifecycle == lifecycleGeneration else { throw CancellationError() }
                return try JSONDecoder().decode([MobileAppSetting].self, from: Data(raw.utf8))
            }, publish: { appSettingRows = $0; appSettingsFailure = nil })
        } catch { if lifecycle == lifecycleGeneration { appSettingsFailure = "The Mac's settings could not be read: \(error.localizedDescription)" } }
    }

    /// Adopt settings only through the owning Mac control's readback.
    func setAppSetting(_ setting: MobileAppSetting, to value: String) async {
        guard setting.writable, setting.unavailableReason == nil, let currentValue = setting.value,
              !appSettingsSaving.contains(setting.id), value != currentValue else { return }
        appSettingsRead.write { appSettingsSaving.insert(setting.id) }
        defer { appSettingsSaving.remove(setting.id) }
        let lifecycle = lifecycleGeneration
        do {
            let result = try requireSuccessfulActionResponse(await sendActionAndWait(
                .make(action: "app_setting_set", payload: ["id": setting.id, "value": value])))
            guard let raw = result["setting"] else { throw SyncError.persistence("The Mac did not return the saved setting.") }
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            let row = try JSONDecoder().decode(MobileAppSetting.self, from: Data(raw.utf8))
            if let index = appSettingRows.firstIndex(where: { $0.id == row.id }) { appSettingsRead.write { appSettingRows[index] = row } }
            appSettingsFailure = nil
        } catch { if lifecycle == lifecycleGeneration { appSettingsFailure = "\(setting.label) could not be confirmed: \(error.localizedDescription)" } }
    }

    func agentThreadAction(id: String, text: String? = nil, sessionID: String? = nil) async throws -> MobileAgentThread {
        let lifecycle = lifecycleGeneration
        var payload = ["id": id]
        if let text {
            guard let session = ChatStore.cleanSessionID(sessionID) else {
                throw SyncError.persistence("Open a chat before sending to an agent.")
            }
            payload["text"] = text; payload["session_id"] = session
        }
        let result = try requireSuccessfulActionResponse(await sendActionAndWait(
            .make(action: text == nil ? "get_agent_thread" : "send_agent_message", payload: payload), pollTimeoutSeconds: text == nil ? 30 : 120))
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        guard let raw = result["thread"] else { throw SyncError.persistence("The Mac did not return the agent thread.") }
        let thread = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(MobileAgentThread.self, from: Data(raw.utf8))
        }.value
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        if (thread.lines.last?.at ?? 0) >= (agentThreads[id]?.lines.last?.at ?? 0) {
            agentThreads[id] = thread
            if let index = helpersSnapshot?.agents.firstIndex(where: { $0.id == id }) {
                helpersSnapshot?.agents[index] = thread.agent.summary
            }
        }
        return thread
    }

    @discardableResult
    func changeSchedulerJob(action: String, payload: [String: String]) async throws -> MobileSchedulerJob {
        let lifecycle = lifecycleGeneration
        let result = try requireSuccessfulActionResponse(await sendActionAndWait(
            InboxAction.make(action: action, payload: payload)
        ))
        guard lifecycle == lifecycleGeneration,
              let data = result["scheduler_job"]?.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(MobileSchedulerSnapshot.self, from: data),
              snapshot.jobs.count == 1,
              let id = result["id"],
              payload["id"] == nil || payload["id"] == id,
              let job = snapshot.jobs.first(where: { $0.id == id }) else {
            throw SyncError.persistence("The Mac did not return the saved scheduler job. Refresh before trying again.")
        }
        // This receipt proves one job, not a successful full-list refresh.
        var merged = schedulerSnapshot ?? MobileSchedulerSnapshot(capturedAt: 0, jobs: [])
        if snapshot.capturedAt >= max(merged.capturedAt, schedulerJobReceiptTimes[id] ?? 0) {
            if let index = merged.jobs.firstIndex(where: { $0.id == id }) {
                merged.jobs[index] = job
            } else {
                merged.jobs.append(job)
            }
            if snapshot.capturedAt >= (schedulerJobReceiptTimes.values.max() ?? 0) {
                merged.mac_time_zone = snapshot.mac_time_zone
            }
            schedulerJobReceiptTimes[id] = snapshot.capturedAt
            schedulerSnapshot = merged
        }
        return job
    }
}

/// The Mac's reply to a Desk task: the item it opened and the agent's line that carries it.
struct MobileDeskTaskStart: Sendable, Equatable {
    let deskHandle: String
    let deskAlias: String
    let job: String
}
