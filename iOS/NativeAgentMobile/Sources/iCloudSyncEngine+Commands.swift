import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Commands.swift` | Subject commands and receipt adoption through the signed action transaction |

extension iCloudSyncEngine {
    // MARK: - Higher-level mutation helpers

    @discardableResult
    func createDeskItem(
        kind: String, project: String, title: String, summary: String?,
        submission: InboxAction? = nil, intentionalNewRequest: Bool = false,
        onReplacement: ((InboxAction) async throws -> Void)? = nil
    ) async throws -> [String: String] {
        var payload = ["kind": kind, "project": project, "title": title]
        if let summary, !summary.isEmpty { payload["summary"] = summary }
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            submission ?? .make(action: "createDeskItem", payload: payload),
            intentionalNewRequest: intentionalNewRequest || submission == nil,
            onReplacement: onReplacement
        ))
    }

    @discardableResult
    func setDeskItemStatus(handle: String, status: String) async throws -> [String: String] {
        try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            .make(action: "setDeskItemStatus", payload: ["handle": handle, "status": status])
        ))
    }

    /// `submission` carries an identity this phone already retained durably, so
    /// a note written away from the Mac is delivered as the SAME signed action
    /// when the app comes back — never as a second note.
    @discardableResult
    func appendDeskItemNote(
        handle: String,
        text: String,
        submission: InboxAction? = nil,
        intentionalNewRequest: Bool = false,
        onReplacement: ((InboxAction) async throws -> Void)? = nil
    ) async throws -> [String: String] {
        let action = submission
            ?? .make(action: "appendDeskItemNote", payload: ["handle": handle, "text": text])
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            action,
            intentionalNewRequest: intentionalNewRequest || submission == nil,
            onReplacement: onReplacement
        ))
    }

    // Route Workshop submission through signature retry so a
    // signature_required rejection auto-retries with a fresh signature.
    @discardableResult
    func submitWorkshopTask(
        title: String, objective: String,
        submission: InboxAction? = nil,
        intentionalNewRequest: Bool = false,
        onReplacement: ((InboxAction) async throws -> Void)? = nil,
        onRefusal: (() -> Void)? = nil
    ) async throws -> String {
        let action = submission ?? InboxAction.make(action: "submitWorkshopTask", payload: [
            "title": title, "objective": objective
        ])
        // Fresh submissions bypass payload recovery; retained retries do not.
        var currentSubmission = action
        let response = try await sendActionWithSignatureRetry(
            action, intentionalNewRequest: intentionalNewRequest || submission == nil,
            onReplacement: {
                currentSubmission = $0
                try await onReplacement?($0)
            }
        )
        // A refusal for an earlier signature attempt cannot unlock a replacement
        // whose delivery is still uncertain. Generic failures may follow execution.
        if response["msgId"] == currentSubmission.msgId,
           response["applied"] == "false" || response["status"] == "orphaned"
            || ["signature_required", "signature_invalid", "device_not_verified",
                "expired_before_execution", "timestamp_invalid", "invalid_action"].contains(response["code"] ?? "") {
            onRefusal?()
        }
        let result = try requireSuccessfulActionResponse(response)
        return result["result"] ?? result["status"] ?? "submitted"
    }

    // Approval sends retry a verified pre-execution signature refusal once.

    @discardableResult
    func decideWorkshopStep(executionId: String, stepId: String, approve: Bool) async throws -> [String: String] {
        let action = InboxAction.make(action: approve ? "approveStep" : "rejectStep", payload: [
            // Compatibility wire key; the Mac maps it to the Workshop execution.
            "missionId": executionId, "stepId": stepId
        ])
        return try requireSuccessfulActionResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func approveApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "approveApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "rejectApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func cancelApproval(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "cancelApproval", payload: ["approvalId": id])
        return try adoptApprovalResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    private func adoptApprovalResponse(_ response: [String: String]) throws -> [String: String] {
        // The decision can settle even when its execution fails.
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
        return try adoptMemoryResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func rejectMemoryProposal(proposalId: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "rejectMemoryProposal", payload: ["proposalId": proposalId])
        return try adoptMemoryResponse(await sendDecisionActionWithSignatureRetry(action))
    }

    @discardableResult
    func deleteMemory(id: String) async throws -> [String: String] {
        let action = InboxAction.make(action: "deleteMemory", payload: ["memoryId": id])
        return try adoptMemoryResponse(await sendActionWithSignatureRetry(action))
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
        let response = try await sendActionWithSignatureRetry(action)
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

    @discardableResult
    func registerPushToken(token: String, environment: String, bundleId: String, deviceId: String = "ios") async throws -> [String: String] {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Throw on invalid tokens so the caller's registration-freshness cache cannot advance.
        guard !cleanToken.isEmpty else {
            throw SyncError.unsupported("Missing APNS device token")
        }
        let action = InboxAction.make(action: "registerPushToken", payload: [
            "token": cleanToken,
            "environment": environment,
            "bundleId": bundleId,
            "deviceId": deviceId,
        ])
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action, pollTimeoutSeconds: 45))
    }

    // MARK: - Mac Control (iOS → Mac remote actions)
    // The Mac enforces control authority; these actions use the signed retry boundary.
    private func macControlResult(_ action: InboxAction, pollTimeoutSeconds: Double = 120) async throws -> String {
        let raw = try await sendActionWithSignatureRetry(action, pollTimeoutSeconds: pollTimeoutSeconds)
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

    /// Post a macOS notification on the Mac.
    func macNotify(title: String, message: String, sound: String? = nil) async throws -> String {
        var arguments = ["title": title, "message": message]
        if let sound { arguments["sound"] = sound }
        return try await sendMacControl(.notification, arguments: arguments)
    }

    /// Set Mac output volume (0–100) through its native volume executor.
    func macSetVolume(percent: Int) async throws -> String {
        guard MacVolumeControlPresentation.isValid(percent: percent) else {
            throw SyncError.unsupported("Volume must be between 0% and 100%.")
        }
        return try await sendMacControl(.volume, arguments: ["value": "\(percent)"])
    }

    /// Run a Spotlight search on the Mac and return its JSON results object.
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
        let response = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
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
        return try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action,
            intentionalNewRequest: true, pollTimeoutSeconds: 90))
    }

    /// Encrypt before any transport persistence. Only the Mac credential owner
    /// receives plaintext; replies contain verified state, never provider output.
    @discardableResult
    func configureProvider(providerId: String, apiKey: String) async throws -> String {
        guard let secret = pairingStore?.iCloudPairingSecret else { throw SyncError.notSigned }
        var action = InboxAction.make(action: "configure_provider_secret", payload: [:])
        action.payload = [SecretActionEnvelope.field: try SecretActionEnvelope.seal(
            ["providerId": providerId, "api_key": apiKey], secret: secret,
            actionID: action.msgId, actionName: action.action
        )]
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            action, intentionalNewRequest: true, pollTimeoutSeconds: 90
        ))
        guard result["provider_id"] == providerId,
              ["verified", "unverified"].contains(result["connection_state"] ?? "") else {
            throw SyncError.persistence("The Mac did not return a verified provider receipt.")
        }
        return result["message"] ?? "Connection not verified."
    }

    /// The short start receipt identifies the exact flow to observe in snapshots.
    func startProviderSignIn(providerId: String) async throws -> String {
        let action = InboxAction.make(action: "start_provider_sign_in", payload: ["providerId": providerId])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        guard result["provider_id"] == providerId, result["connection_state"] == "pending",
              let requestID = result["request_id"], UUID(uuidString: requestID) != nil else {
            throw SyncError.persistence("The Mac did not confirm the sign-in request.")
        }
        return requestID
    }

    /// Run a connection test for a provider on the Mac. Result arrives in responses/<msgId>.json.
    @discardableResult
    func testProvider(providerId: String) async throws -> String {
        let action = InboxAction.make(action: "test_provider", payload: ["providerId": providerId])
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        return result["result"] ?? result["status"] ?? ""
    }

    /// Atomically commit the complete execution tuple to the Mac-owned
    /// ProviderRouting transaction. Chat metadata is not routing authority.
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
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
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
        guard confirmed == (expected == "missions" ? "workshop" : expected), surfaces.contains(confirmed),
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

    func setConnectorEnabled(id: String, enabled: Bool) async throws -> MobileConnectorSnapshot {
        try await connectorMutation(action: "set_connector_enabled", id: id, enabled: enabled)
    }

    func disconnectConnector(id: String) async throws -> MobileConnectorSnapshot {
        try await connectorMutation(action: "disconnect_connector", id: id, enabled: nil)
    }

    private func connectorMutation(action: String, id: String, enabled: Bool?) async throws -> MobileConnectorSnapshot {
        let lifecycle = lifecycleGeneration
        var payload = ["id": id]
        if let enabled { payload["enabled"] = String(enabled) }
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
            InboxAction.make(action: action, payload: payload)
        ))
        guard let json = result["connector"],
              let row = try? JSONDecoder().decode(MobileConnectorSnapshot.self, from: Data(json.utf8)),
              row.id == id, row.enabled == (enabled ?? false),
              row.canToggle != nil, row.canDisconnect != nil, row.supportsSetup != nil,
              enabled != nil || row.authState == "not_connected" else {
            throw SyncError.persistence("The Mac did not return confirmed connector settings. Refresh before trying again.")
        }
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        applyConnectorSnapshot(connectors.filter { $0.id != id } + [row])
        return row
    }

    /// Mutate Mac integration authority through the signed action ledger and
    /// return the canonical read-back tuple from the Mac owner.
    func setTrustPolicy(_ request: MobileTrustAction) async throws -> TrustPolicy {
        guard MobileTrustAction(payload: request.payload) != nil else {
            throw SyncError.unsupported("Invalid or unconfirmed trust change.")
        }
        let action = InboxAction.make(action: "set_trust_policy", payload: request.payload)
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(action))
        guard let raw = result["policy"],
              let recovered = try? JSONDecoder().decode(TrustPolicy.self, from: Data(raw.utf8)),
              recovered.permissionLevel != nil, recovered.autonomyDefault != nil,
              recovered.effectiveRequireBackups != nil, recovered.effectiveOutsideDefault != nil,
              recovered.developerMode != nil else {
            throw SyncError.persistence("Mac did not return the saved trust policy. Refresh Trust before trying again.")
        }
        trustPolicy = recovered
        return recovered
    }

    /// The Mac's settings page, every row as the Mac reads it.
    func refreshAppSettings() async {
        guard !appSettingsLoading, appSettingsSaving.isEmpty else { return }
        appSettingsLoading = true
        defer { appSettingsLoading = false }
        let lifecycle = lifecycleGeneration
        do {
            _ = try await appSettingsRead.read({
                let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
                    .make(action: "app_settings", payload: [:])))
                guard let raw = result["settings"] else { throw SyncError.persistence("The Mac did not return its settings.") }
                guard lifecycle == lifecycleGeneration else { throw CancellationError() }
                return try JSONDecoder().decode([MobileAppSetting].self, from: Data(raw.utf8))
            }, publish: { appSettingRows = $0; appSettingsFailure = nil })
        } catch { if lifecycle == lifecycleGeneration { appSettingsFailure = "The Mac's settings could not be read: \(error.localizedDescription)" } }
    }

    /// One setting, set through the Mac page's own control; adopts its read-back.
    func setAppSetting(_ setting: MobileAppSetting, to value: String) async {
        guard !appSettingsSaving.contains(setting.id), value != setting.value else { return }
        appSettingsRead.write { appSettingsSaving.insert(setting.id) }
        defer { appSettingsSaving.remove(setting.id) }
        let lifecycle = lifecycleGeneration
        do {
            let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
                .make(action: "app_setting_set", payload: ["id": setting.id, "value": value])))
            guard let raw = result["setting"] else { throw SyncError.persistence("The Mac did not return the saved setting.") }
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            let row = try JSONDecoder().decode(MobileAppSetting.self, from: Data(raw.utf8))
            if let index = appSettingRows.firstIndex(where: { $0.id == row.id }) { appSettingsRead.write { appSettingRows[index] = row } }
            appSettingsFailure = nil
        } catch { if lifecycle == lifecycleGeneration { appSettingsFailure = "\(setting.label) was not changed: \(error.localizedDescription)" } }
    }

    func helperAction(_ name: String, payload: [String: String]) async throws -> (MobileHelperEdit, [String: String]) {
        let lifecycle = lifecycleGeneration
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(.make(action: name, payload: payload)))
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        guard let raw = result["helper"] else { throw SyncError.persistence("The Mac did not return the saved helper.") }
        let helper = try JSONDecoder().decode(MobileHelperEdit.self, from: Data(raw.utf8))
        if let id = helper.id, (helper.revision ?? 0) >= max(helperDetails[id]?.revision ?? 0,
            helpersSnapshot?.helpers.first(where: { $0.id == id })?.revision ?? 0) {
            helperDetails[id] = helper
        }
        // Accept the action receipt independently of the broader refresh.
        do {
            guard let rawSnapshot = result["helpers_snapshot"] else { throw SyncError.persistence("The Mac did not return the helper status.") }
            applyHelpersSnapshot(try JSONDecoder().decode(MobileHelpersSnapshot.self, from: Data(rawSnapshot.utf8)))
            staleSnapshotGroups["helpers_agents"] = nil
        } catch {
            staleSnapshotGroups["helpers_agents"] = result["helpers_snapshot_error"] ?? error.localizedDescription
        }
        return (helper, result)
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
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
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
        let result = try requireSuccessfulActionResponse(await sendActionWithSignatureRetry(
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
