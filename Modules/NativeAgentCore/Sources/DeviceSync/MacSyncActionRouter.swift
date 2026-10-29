import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import os
import ApprovalInbox
import Cognition
import CognitiveSubstrate
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import MemoryV2
import PersistenceCore
import Desk
import ProviderRouting
import Transcripts
// Blueprint: | `MacSyncActionRouter.swift` | `MacSyncActionRouter` struct; `surfaceSelection`; routing receipts use committed selection snapshots; approval, memory and inbox mutations return affected canonical records/removals for the shared phone projection; no complete inbox or memory lists in action replies; other readback revisions are captured on the Mac before the canonical read |

@MainActor
struct MacSyncActionRouter {
    struct SurfaceSelection: Equatable, Sendable {
        let surface: String
        let providerID: String
        let model: String
        let reasoningEffort: String
        let serviceTier: String
    }

    nonisolated static func surfaceSelection(
        from payload: [String: String]
    ) -> SurfaceSelection? {
        func clean(_ key: String) -> String {
            (payload[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fold the legacy `missions` spelling before the MODEL_SURFACES guard —
        // an iOS build or signed action one version behind still sends it.
        let surface = WorkshopSurfaceVocabulary.canonicalSurface(clean("surface").lowercased())
        let providerID = clean("provider_id")
        let model = clean("model")
        let reasoning = clean("reasoning_effort").lowercased()
        let rawTier = clean("service_tier").lowercased()
        let serviceTier = rawTier.isEmpty ? "default" : rawTier
        guard MODEL_SURFACES.contains(surface), !providerID.isEmpty, !model.isEmpty,
              REASONING_EFFORT_OPTIONS.contains(reasoning),
              SERVICE_TIER_OPTIONS.contains(serviceTier) else {
            return nil
        }
        return SurfaceSelection(
            surface: surface,
            providerID: providerID,
            model: model,
            reasoningEffort: reasoning,
            serviceTier: serviceTier
        )
    }

    nonisolated static func canonicalSurfaceSelectionResponse(
        surface: String,
        providerID: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String
    ) -> [String: String] {
        [
            "status": "ok",
            "ok": "true",
            "surface": surface,
            "surfaces": ProviderSurfaceGroups.members(of: surface).joined(separator: ","),
            "provider_id": providerID,
            "model": model,
            "reasoning_effort": reasoningEffort,
            "service_tier": serviceTier,
        ]
    }

    /// A model-control receipt is only successful after the canonical routing
    /// owner reads back the requested model.  The iPhone must not show a
    /// successful remote mutation merely because the Mac accepted its inbox
    /// message.
    nonisolated static func canonicalSurfaceModelResponse(
        surface: String,
        requestedModel: String,
        recoveredPreference: SurfacePreference?
    ) -> [String: String] {
        guard let recoveredPreference,
              recoveredPreference.model == requestedModel else {
            return [
                "status": "error",
                "ok": "false",
                "applied": "false",
                "message": "Mac could not confirm that the surface model was applied.",
            ]
        }
        return [
            "status": "ok",
            "ok": "true",
            "applied": "true",
            "surface": surface,
            "model": recoveredPreference.model,
            "reasoning_effort": recoveredPreference.reasoningEffort,
            "service_tier": recoveredPreference.serviceTier,
        ]
    }

    nonisolated static func unpinChatSessionID(from payload: [String: String]) -> String? {
        NativeAgentChatSessionID.normalizedPathComponent(
            payload["sessionId"] ?? payload["session_id"]
        )
    }

    /// Publish organism evidence only after the canonical phone-delivery receipt is durable.
    /// Only authenticated iOS receipts default an omitted direction to mac_to_ios; explicit values stay literal.
    static func notificationReceiptResponse(
        payload: [String: String],
        senderIsAuthenticatedIOSPeer: Bool,
        confirm: (String, String, String) async -> Bool,
        receive: (String, String) async -> Void
    ) async -> [String: String] {
        let eventID = (payload["eventId"] ?? payload["event_id"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else {
            return [
                "status": "error",
                "ok": "false",
                "code": "invalid_event_id",
                "message": "Notification receipt requires a canonical eventId.",
            ]
        }
        var direction = (payload["direction"] ?? payload["receiptDirection"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if direction.isEmpty, senderIsAuthenticatedIOSPeer {
            direction = "mac_to_ios"
        }
        guard direction == "mac_to_ios" || direction == "ios_to_mac" else {
            return [
                "status": "error",
                "ok": "false",
                "code": "invalid_direction",
                "message": "Notification receipt requires an explicit direction of mac_to_ios or ios_to_mac.",
            ]
        }
        let channel = String((payload["channel"] ?? "ios").prefix(80))
        guard await confirm(direction, eventID, channel) else {
            return [
                "status": "error",
                "ok": "false",
                "code": "receipt_persistence_failed",
                "message": "Notification receipt could not be filed; delivery was not marked received.",
                "eventId": eventID,
                "direction": direction,
                "channel": channel,
            ]
        }
        if direction == "mac_to_ios" {
            await receive(eventID, channel)
        }
        return [
            "status": "ok",
            "ok": "true",
            "eventId": eventID,
            "direction": direction,
            "channel": channel,
        ]
    }

    unowned let sync: DeviceSync
    var cancelChatTask: (String, [String]) -> MacSyncEngine.MacSyncChatCancelOutcome

    /// The runs a cancelChat action names, if any. An empty result means the
    /// caller did not name one and the session's current turn is the target.
    static func cancelChatRunIDs(from payload: [String: String]) -> [String] {
        let raw = payload["runId"] ?? payload["run_id"] ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func dispatch(_ action: InboxAction) async -> [String: String] {
        if let message = await sync.pairedPhones.authorize(action) {
            sync.engine.syncError = message
            return ["status": "error", "ok": "false", "code": "device_not_verified", "message": message]
        }
        let payload = action.payload
        let actionName = action.action
        var cognitiveResponse: [String: String]?
        let cognition = sync.cognition
        defer {
            Task {
                await cognition.ingestOrganismSignal(
                    kind: .iPhoneReachable,
                    sourceOrgan: "ios",
                    intensity: 0.25,
                    valence: 0.08,
                    metadata: [
                        "action": .string(actionName),
                        "surface": .string("ios_icloud"),
                    ]
                )
            }
            if let response = cognitiveResponse {
                Task {
                    await cognition.observeRemoteAction(
                        surface: "ios",
                        action: actionName,
                        payload: payload,
                        response: response
                    )
                }
            }
        }

        func observed(_ response: [String: String]) -> [String: String] {
            cognitiveResponse = response
            return response
        }

        let api = sync.host

        do {
            switch action.action {
            case "set_trust_policy": return observed(try await applyTrustAction(payload))
            case "create_scheduler_job", "pause_scheduler_job", "resume_scheduler_job", "cancel_scheduler_job": return observed(try await schedulerAction(action.action, payload: payload))
            case "get_helper", "save_helper", "pause_helper", "run_helper", "get_agent_thread", "send_agent_message": return observed(try await helpersAction(action.action, payload: payload))
            case "set_connector_enabled", "disconnect_connector": return observed(try await connectorAction(action))
            case "disconnect_telegram", "set_telegram_settings": return await telegramAction(action)
            case "chat_history_page": return observed(try await chatHistoryPage(action))
            case "set_mac_integration_permission":
                guard let id = payload["id"], MacIntegrationID.all.contains(id),
                      let read = payload["read"], ["true", "false"].contains(read),
                      let write = payload["write"], ["true", "false"].contains(write) else {
                    return observed(["status": "error", "ok": "false",
                                     "message": "A known integration id and exact read/write booleans are required."])
                }
                let axes = (read == "true" && MacIntegrationID.supportsRead(id) ? ["read"] : [])
                    + (write == "true" && MacIntegrationID.supportsWrite(id) ? ["write"] : [])
                let row = try await api.setAppSetting(id: "trust.mac_integration_\(id)",
                    value: axes.isEmpty ? "off" : axes.joined(separator: "_"),
                    actionID: action.msgId, clientID: action.clientId)
                return observed(["status": "ok", "ok": "true", "id": id,
                    "read": String(row.value == "read" || row.value == "read_write"),
                    "write": String(row.value == "write" || row.value == "read_write")])
            case "app_settings":
                let rows = try await api.appSettings()
                return observed(["status": "ok", "ok": "true",
                                 "settings": String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)])
            case "app_setting_set":
                let row = try await api.setAppSetting(id: payload["id"] ?? "", value: payload["value"] ?? "",
                                                      actionID: action.msgId, clientID: action.clientId)
                return observed(["status": "ok", "ok": "true",
                                 "setting": String(decoding: try JSONEncoder().encode(row), as: UTF8.self)])
            case "pairDevice":
                return ["status": "ok", "ok": "true", "message": "This phone is paired."]
            case "createDeskItem":
                let kindRaw = (payload["kind"] ?? "plan").lowercased()
                let project = (payload["project"] ?? "General").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (payload["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = payload["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let kind = DeskKind(rawValue: kindRaw), !project.isEmpty, !title.isEmpty,
                      project.count <= 200, title.count <= 500, (summary?.count ?? 0) <= 2_000 else {
                    return observed(["status": "error", "code": "invalid_desk_item", "message": "Desk kind, project, title, or summary is invalid."])
                }
                let item = try await SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot())
                    .createItem(kind: kind, project: project, title: title, summary: summary)
                return observed(["status": "ok", "handle": item.handle, "alias": item.alias])

            case "setDeskItemStatus":
                let handle = (payload["handle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let statusRaw = (payload["status"] ?? "").lowercased()
                guard handle.hasPrefix("desk_"), handle.count <= 64,
                      let status = DeskStatus(rawValue: statusRaw), status != .blocked else {
                    return observed(["status": "error", "code": "invalid_desk_status", "message": "Desk handle or status is invalid."])
                }
                _ = try await SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot())
                    .setStatus(handle, status: status)
                return observed(["status": "ok", "handle": handle, "deskStatus": status.rawValue])

            case "appendDeskItemNote":
                let handle = (payload["handle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let note = (payload["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard handle.hasPrefix("desk_"), handle.count <= 64, !note.isEmpty, note.count <= 2_000 else {
                    return observed(["status": "error", "code": "invalid_desk_note", "message": "Desk handle or note is invalid."])
                }
                _ = try await SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot())
                    .appendNote(handle, text: note)
                return observed(["status": "ok", "handle": handle])

            case "submitWorkshopTask", "submitMission":
                let title = payload["title"] ?? "iOS Desk Task"
                let objective = payload["objective"] ?? ""
                let result = try await api.submitWorkshopExecution(title: title, objective: objective)
                return [
                    "status": "ok",
                    // Preserve the response key read by existing iOS installations.
                    InboxActionExecutionIdVocabulary.wireKey: result.executionId ?? result.id ?? "",
                    "deskHandle": result.desk_handle ?? "",
                    "deskAlias": result.desk_alias ?? "",
                ]

            case "approveStep", "rejectStep":
                let rejecting = action.action == "rejectStep"
                // Accept both executionId and the phone's missionId wire spelling.
                let executionId = InboxActionExecutionIdVocabulary.executionId(payload) ?? ""
                let stepId = payload["stepId"] ?? ""
                guard !executionId.isEmpty, !stepId.isEmpty, stepId != "pending" else {
                    let response = ["status": "error", "error": "missing_real_step_id"]
                    return rejecting ? observed(response) : response
                }
                try await api.resolveWorkshopStep(
                    executionId: executionId,
                    stepId: stepId,
                    decision: rejecting ? "reject" : "approve",
                    provenance: .signedIOS(clientID: action.clientId, decidedBy: "ios_signed_operator")
                )
                let response = ["status": "ok"]
                return rejecting ? observed(response) : response

            case "approveMemoryProposal":
                let proposalId = payload["proposalId"] ?? ""
                let record = try await api.acceptMemoryProposal(proposalID: proposalId)
                return try await memoryActionResponse(["ok": "true", "status": "ok"],
                    memoryID: record.id, proposalID: proposalId, api: api)

            case "rejectMemoryProposal":
                let proposalId = payload["proposalId"] ?? ""
                try await api.rejectMemoryProposal(proposalID: proposalId, reason: "Rejected via iOS")
                return observed(try await memoryActionResponse(["ok": "true", "status": "rejected"], proposalID: proposalId, api: api))

            case "deleteMemory":
                let memoryId = payload["memoryId"] ?? payload["id"] ?? ""
                guard !memoryId.isEmpty else { return observed(["status": "error", "message": "Missing memoryId"]) }
                try await api.deleteMemory(id: memoryId)
                return observed(try await memoryActionResponse(["status": "ok", "ok": "true"], memoryID: memoryId, api: api))

            case "approveApproval", "rejectApproval", "cancelApproval":
                let approvalId = payload["approvalId"] ?? payload["id"] ?? ""
                let response: [String: String]
                if approvalId.isEmpty {
                    response = ["status": "error", "message": "Missing approvalId"]
                } else {
                    response = try await approvalActionResponse(approvalId: approvalId,
                        decision: String(action.action.dropLast("Approval".count)), action: action)
                }
                return action.action == "approveApproval" ? response : observed(response)

            case "interaction_action":
                guard action.payload.count == 1,
                      let sealed = action.payload[SecretActionEnvelope.field],
                      let encodedSecret = try PairingSecret.existingSecretBase64(),
                      let secret = Data(base64Encoded: encodedSecret) else {
                    return ["status": "error", "message": "Could not decrypt the card answer. Check pairing and try again."]
                }
                let fields = try SecretActionEnvelope.open(sealed, secret: secret,
                    actionID: action.msgId, actionName: action.action)
                return try await api.interactionAction(payload: fields, actionID: action.msgId, clientID: action.clientId)

            case "inboxAction":
                let itemId = payload["itemId"] ?? payload["id"] ?? ""
                let actionId = payload["actionId"] ?? payload["action"] ?? "act"
                guard !itemId.isEmpty else { return ["status": "error", "message": "Missing inbox item id"] }
                guard !actionId.isEmpty else { return ["status": "error", "message": "Missing inbox action"] }
                if itemId.hasPrefix("interaction:"), actionId == "act" {
                    let response = try await api.interactionAction(payload: ["action": "open", "itemID": itemId],
                        actionID: action.msgId, clientID: action.clientId)
                    return try await inboxActionResponse(response, itemID: itemId, api: api)
                }
                let endpointAction = InboxActionVocabulary.routedAction(actionId, itemID: itemId)
                if (endpointAction == "approve" || endpointAction == "reject"), !itemId.hasPrefix("interaction:") {
                    return observed(try await approvalActionResponse(approvalId: itemId,
                        decision: endpointAction, action: action, inboxItemID: itemId))
                }
                try await api.inboxAction(itemId, action: endpointAction)
                return observed(try await inboxActionResponse([
                    "status": "ok",
                    "ok": "true",
                    "itemId": itemId,
                    "actionId": actionId,
                ], itemID: itemId, api: api))

            case "registerWorkActivity":
                guard let deviceID = payload["deviceId"], !deviceID.isEmpty,
                      let enabled = payload["enabled"], ["true", "false"].contains(enabled),
                      let environment = payload["environment"], ["development", "production"].contains(environment),
                      let bundleID = payload["bundleId"], !bundleID.isEmpty else {
                    return ["status": "error", "message": "Invalid Live Activity registration"]
                }
                for key in ["startToken", "activityToken"] {
                    if let token = payload[key], !token.isEmpty,
                       (token.count > 512 || !token.allSatisfy(\.isHexDigit)) {
                        return ["status": "error", "message": "Invalid Live Activity token"]
                    }
                }
                let observedWorkIDs: Set<String>?
                if let inventory = payload["observedWorkIds"] {
                    let ids = try JSONDecoder().decode([String].self, from: Data(inventory.utf8))
                    guard ids.count <= 64, ids.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else {
                        return ["status": "error", "message": "Invalid Live Activity inventory"]
                    }
                    observedWorkIDs = Set(ids)
                } else { observedWorkIDs = nil }
                try await MacSyncMobileNotificationRelay.storeWorkActivityRegistration(
                    deviceID: deviceID, enabled: enabled == "true", environment: environment, bundleID: bundleID,
                    startToken: payload["startToken"], workID: payload["workId"],
                    activityToken: payload["activityToken"].flatMap { $0.isEmpty ? nil : $0 },
                    observedWorkIDs: observedWorkIDs, dataRoot: sync.dataRoot)
                sync.engine.requestWorkActivityPublication()
                return ["status": "ok", "ok": "true"]

            case "registerPushToken":
                let token = (payload["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else {
                    return ["status": "error", "message": "Missing push device token"]
                }
                let deviceId = payload["deviceId"] ?? payload["device_id"] ?? "ios"
                let environment = payload["environment"] ?? payload["sandbox"] ?? "prod"
                let bundleId = payload["bundleId"] ?? payload["bundle_id"] ?? ""
                try await MacSyncMobileNotificationRelay.storePushToken(
                    deviceId: deviceId,
                    pairedDeviceID: action.clientId,
                    token: token,
                    environment: environment,
                    bundleId: bundleId,
                    dataRoot: sync.dataRoot
                )
                return [
                    "status": "ok",
                    "ok": "true",
                    "stored": "true",
                    "deviceId": deviceId,
                    "environment": environment,
                    "bundleId": bundleId,
                    "tokenSuffix": String(token.suffix(8)),
                    "tokenStore": "notifications/push_tokens.json",
                ]

            case "recordNotificationReceipt":
                return observed(await Self.notificationReceiptResponse(
                    payload: payload,
                    // `dispatch` is reached only from MacSyncEngine+Inbox after
                    // the action's HMAC and timestamp validated, on both the
                    // Drive and CloudKit lanes — so the sender IS the paired
                    // iPhone.
                    senderIsAuthenticatedIOSPeer: true,
                    confirm: { direction, eventID, channel in
                        await iCloudBridge.confirmChatDeliveryReceipt(
                            direction: direction,
                            eventID: eventID,
                            channel: channel,
                            dataRoot: PersistenceCore.defaultDataRoot()
                        )
                    },
                    receive: { eventID, channel in
                        await sync.relay.receiveDeliveryPrediction(
                            eventID: eventID,
                            channel: channel
                        )
                        // The phone's receipt is what settles an owed result.
                        await sync.host.retryRequestedResults()
                    }
                ))

            case "steerChat":
                return observed(await steerChat(payload))

            case "cancelChat":
                var sessionId = payload["sessionId"] ?? payload["session_id"] ?? ""
                let sourceKey = payload["sourceKey"] ?? payload["source_key"] ?? ""
                if sessionId.isEmpty, !sourceKey.isEmpty {
                    if let sessions = try? await api.getChatSessions() {
                        sessionId = sessions.first(where: { $0.sourceKey == sourceKey })?.id ?? ""
                    }
                }
                if !sessionId.isEmpty {
                    guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
                        return observed([
                            "status": "error",
                            "ok": "false",
                            "code": "invalid_session_id",
                            "message": "cancelChat rejected an invalid sessionId.",
                        ])
                    }
                    // A Stop that names its runs is the Mac's own Stop when one
                    // of them is in flight here, from whichever door started it:
                    // the shared turn owner keeps those exact requested ids
                    // through the marker write (never a later run). A named
                    // run not yet here is held against its id — registration
                    // cancels it — and that is said as pending, never as a stop that happened.
                    let runIDs = Self.cancelChatRunIDs(from: payload)
                    let cancelOutcome = cancelChatTask(safeSessionId, runIDs)
                    let stopsHere = runIDs.isEmpty
                        ? cancelOutcome == .cancelled || cancelOutcome == .noActiveTask
                        : !ChatCancelFlag.inFlightRunIDs().isDisjoint(with: runIDs)
                    if stopsHere { _ = try await api.cancelChatSession(sessionId: safeSessionId, runIDs: runIDs) }
                    guard stopsHere || cancelOutcome == .cancelled || runIDs.isEmpty else {
                        return observed([
                            "status": "pending",
                            "ok": "false",
                            "sessionId": safeSessionId,
                            "message": "The Mac has not received that request yet; it stops the moment it arrives.",
                        ])
                    }
                    return observed([
                        "status": "ok",
                        "ok": "true",
                        "sessionId": safeSessionId,
                        "taskCancelled": "true",
                    ])
                }
                return observed([
                    "status": "error",
                    "ok": "false",
                    "code": "not_implemented",
                    "message": "source-key cancel not wired natively; provide sessionId.",
                ])

            case "unpinChatSession":
                guard let sessionId = Self.unpinChatSessionID(from: payload) else {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "code": "invalid_session_id",
                        "message": "unpinChatSession requires a valid sessionId.",
                    ])
                }
                let current = sync.host.pinnedChatSessionIDs()
                let next = current.filter { $0 != sessionId }
                if next != current {
                    try sync.host.savePinnedChatSessionIDs(next)
                    await MainActor.run {
                        sync.engine.requestChatSnapshotPublication(
                            includeTranscripts: false
                        )
                    }
                }
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "applied": "true",
                    "changed": next == current ? "false" : "true",
                    "sessionId": sessionId,
                    "pinned": "false",
                ])

            case "configure_provider_secret": return await configureEncryptedProvider(action)
            case "start_provider_sign_in": return await startProviderSignIn(action)
            case "configure_provider":
                let providerId = payload["providerId"] ?? ""
                guard !providerId.isEmpty else { return observed(["status": "error", "message": "Missing providerId"]) }
                if let key = payload["api_key"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return observed([
                        "status": "error",
                        "message": "API keys cannot be sent through iCloud. Open NativeAgent on the Mac to save provider keys locally.",
                    ])
                }
                if payload["auth_mode"] == "oauth",
                   providerId == "openai_oauth_direct" || providerId == "anthropic_oauth_direct" || providerId == "xai_oauth_direct" {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "code": "not_implemented",
                        "message": "Provider OAuth must be started from the Mac app.",
                        "provider_id": providerId,
                    ])
                }
                let authMode = payload["auth_mode"] ?? ""
                _ = try await api.configureProvider(providerId, apiKey: nil, authMode: authMode, defaultModel: nil)
                return observed(["status": "ok", "provider_id": providerId])

            case "test_provider":
                let providerId = payload["providerId"] ?? ""
                guard !providerId.isEmpty else { return observed(["status": "error", "message": "Missing providerId"]) }
                let result = try await api.testProvider(providerId)
                var response = ["status": result.status, "detail": result.detail ?? "", "provider_id": providerId]
                if let error = result.error {
                    response["error"] = error
                    response["message"] = error
                } else if let text = result.response {
                    response["message"] = text
                }
                return observed(response)

            case "clear_provider":
                let providerId = payload["providerId"] ?? ""
                guard !providerId.isEmpty else { return ["status": "error", "message": "Missing providerId"] }
                _ = try await api.clearProvider(providerId)
                return ["status": "ok", "provider_id": providerId]

            case "set_active_provider":
                guard let surface = payload["surface"], let providerId = payload["provider_id"],
                      !surface.isEmpty, !providerId.isEmpty else {
                    return ["status": "error", "message": "A surface and provider are required."]
                }
                _ = try await api.setActiveProvider(surface: surface, providerId: providerId)
                return ["status": "ok", "ok": "true", "surface": surface, "provider_id": providerId]

            case "set_surface_model":
                let surface = payload["surface"] ?? "chat"
                let model = (payload["model"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    return ["status": "error", "message": "Missing model"]
                }
                let reasoning = payload["reasoning_effort"].flatMap { $0.isEmpty ? nil : $0 }
                let recovered = try await api.saveSurfaceSelection(
                    surface: surface, model: model, reasoningEffort: reasoning,
                    serviceTier: reasoning == nil ? nil : payload["service_tier"], providerID: nil
                )
                return observed(Self.canonicalSurfaceModelResponse(
                    surface: surface,
                    requestedModel: model,
                    recoveredPreference: ProviderRoutingSurfaceLookup.value(
                        recovered.preferences,
                        surface
                    )
                ))

            case "configure_surface_selection":
                guard let request = Self.surfaceSelection(from: payload) else {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "message": "A complete valid provider/model/reasoning/tier tuple is required for a canonical surface",
                    ])
                }
                let recovered = try await api.saveSurfaceSelection(
                    surface: request.surface,
                    model: request.model,
                    reasoningEffort: request.reasoningEffort,
                    serviceTier: request.serviceTier,
                    providerID: request.providerID
                )
                guard let preference = ProviderRoutingSurfaceLookup.value(
                          recovered.preferences, request.surface),
                      let providerID = ProviderRoutingSurfaceLookup.value(
                          recovered.activeProviders, request.surface),
                      !providerID.isEmpty else {
                    throw ProviderRoutingError.configurationFailed(
                        "Surface selection did not recover a complete tuple"
                    )
                }
                var response = Self.canonicalSurfaceSelectionResponse(
                    surface: request.surface,
                    providerID: providerID,
                    model: preference.model,
                    reasoningEffort: preference.reasoningEffort,
                    serviceTier: preference.serviceTier
                )
                response["modelReadbackRevision"] = String(recovered.revision)
                return observed(response)

            case "mac_control":
                return try await api.remoteMacControl(payload: payload)

            default:
                return observed(["status": "error", "message": "Unknown action: \(action.action)"])
            }
        } catch ApprovalInboxError.resolutionNotAuthorized(_, let reason) {
            return observed([
                "status": "error",
                "error": "approval_local_only",
                "message": reason,
            ])
        } catch {
            return observed(["status": "error", "message": error.localizedDescription])
        }
    }

    private func inboxActionResponse(_ response: [String: String], itemID: String, api: any DeviceSyncHost) async throws -> [String: String] {
        var response = response
        response["inboxReadbackRevision"] = String(Date().timeIntervalSince1970)
        let read = await api.workOverview()
        response["inboxItemId"] = itemID
        response["inboxItemJSON"] = String(decoding: try JSONEncoder().encode(read.inbox.get().first { $0.id == itemID }), as: UTF8.self)
        return response
    }

    private func memoryActionResponse(_ response: [String: String], memoryID: String? = nil,
                                      proposalID: String? = nil, api: any DeviceSyncHost) async throws -> [String: String] {
        var response = response
        response["memoryReadbackRevision"] = String(Date().timeIntervalSince1970)
        response["resolvedProposalId"] = proposalID
        if let memoryID {
            let row = try await api.activeMemories().first { $0.id == memoryID }.map(MemoryRecord.init(phoneRow:))
            response["memoryId"] = memoryID
            response["memoryJSON"] = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        }
        return response
    }

    private func approvalActionResponse(approvalId: String, decision: String, action: InboxAction,
                                        inboxItemID: String? = nil) async throws -> [String: String] {
        let row = try await sync.host.resolveApproval(id: approvalId, decision: decision,
            provenance: .signedIOS(clientID: action.clientId, decidedBy: "ios_signed_operator"))
        let accepted = row.status == "resolved"
        var out = ["ok": "true", "id": row.id, "status": row.status, "action": row.action,
            "title": row.title, "risk": row.risk, "decisionAccepted": accepted ? "true" : "false",
            "decisionStatus": row.status, "createdAt": row.createdAt, "reason": row.reason]
        out["decision"] = row.decision
        out["resolvedAt"] = row.resolvedAt
        if row.decision == "approved" {
            var status: String?
            var error: String?
            var message: String?
            var ok: Bool?
            let liveWaiter: Bool
            if case .object(let fields)? = row.executedAction {
                func bounded(_ key: String) -> String? {
                    guard case .string(let value)? = fields[key] else { return nil }
                    return String(value.unicodeScalars.prefix(512))
                }
                status = bounded("status") ?? "recorded"
                error = bounded("error")
                message = bounded("message")
                if case .bool(let value)? = fields["ok"] { ok = value }
                liveWaiter = false
            } else if accepted, ["agent.acp.permission", "agent.acp.connect"].contains(row.action),
                      case .object(let payload) = row.payload,
                      case .string("agent_acp_live_approval")? = payload["kind"] {
                liveWaiter = true
            } else {
                status = "outcome_unknown"
                message = "No execution outcome is available."
                liveWaiter = false
            }
            if !liveWaiter {
                message = message ?? row.detail.map { String($0.unicodeScalars.prefix(512)) }
                // Preserve the bounded execution-description wire field.
                var execution: [String: Any] = [:]
                if let status { execution["status"] = status }
                if let error { execution["error"] = error }
                if let message { execution["message"] = message }
                if let ok { execution["ok"] = ok }
                out["executedAction"] = String(describing: execution)
                let verdict = row.executionResultClass
                out["executionStatus"] = (status ?? "").lowercased()
                out["result_class"] = verdict.rawValue
                out["status"] = verdict.receipt.status
                out["ok"] = verdict.receipt.ok.map { String($0) }
                out["message"] = [error, message].compactMap { $0 }.first { !$0.isEmpty }
                if verdict.isFailure, accepted {
                    out["message"] = "Decision accepted. " + (out["message"] ?? "Execution did not succeed (\(verdict.rawValue)).")
                }
            } else { out["status"] = "pending_approval"; out["result_class"] = "unknown" }
        }
        out["approvalReadbackRevision"] = String(Date().timeIntervalSince1970)
        if inboxItemID != nil { out["inboxReadbackRevision"] = String(Date().timeIntervalSince1970) }
        let projection = await sync.host.workOverview()
        let canonical = try projection.approvals.get().first { $0.id == approvalId }
        out["approvalJSON"] = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
        out["approvalId"] = approvalId
        if let inboxItemID {
            out["inboxItemId"] = inboxItemID
            out["inboxItemJSON"] = String(decoding: try JSONEncoder().encode(projection.inbox.get().first { $0.id == inboxItemID }), as: UTF8.self)
        }
        return out
    }

}

extension MacSyncActionRouter {
    /// The phone's Steer, admitted on the control lane so it reaches the turn
    /// already working in that chat while it runs: she reads it at her next
    /// step, as on the Mac and Telegram. The phone hears "steered" once a
    /// round has read it, or "steer_returned" when the turn ended first (with
    /// whether its row is already written), and then sends it as its own
    /// message. No working turn for this door: not taken, said so at once.
    func steerChat(_ payload: [String: String]) async -> [String: String] {
        guard let sessionId = payload["sessionId"].flatMap(NativeAgentChatSessionID.normalizedPathComponent),
              let runId = payload["runId"], UUID(uuidString: runId) != nil,
              let text = payload["text"], !text.isEmpty, text.utf8.count <= 64_000 else {
            return ["status": "error", "ok": "false", "message": "steerChat needs a chat, a run id and its words."]
        }
        let routeKey = payload["routeKey"] ?? ""
        let route = ChatToolSessionContext.ReplyRoute(surface: "ios", sourceKey: routeKey, replyTo: "iphone", correlationId: runId)
        let bridge = sync.bridge
        func tell(_ kind: String, _ words: String, _ extra: [String: String] = [:]) async {
            _ = try? await bridge.sendChatMessage(text: words, sessionID: sessionId, correlationID: runId,
                metadata: ["kind": kind, "transport": "icloud", "source": "mac", "replyTo": "iphone",
                           "targetSourceKey": routeKey].merging(extra) { $1 })
        }
        // 0 offered, 1 reserved (its row written), 2 read.
        let phase = OSAllocatedUnfairLock(initialState: 0)
        let taken = await ChatTurnSteering.shared.offer(ChatTurnSteering.Offer(id: "ios-steer:" + runId, text: text,
            envelope: TurnEnvelope(surface: "ios", deliveryRoute: route), origin: nil, runID: runId),
            sessionId: sessionId, onDelivered: { offer, committed in
                let read = !committed && offer.receivingTurnID != nil
                let next = phase.withLock { phase -> Bool in
                    switch (phase, committed, read) {
                    case (0, false, false): phase = 1; return true
                    case (1, false, true): phase = 2; return true
                    case (2, true, _): return true
                    default: return false
                    }
                }
                if next, read { await tell("steered", "Read in the reply in progress") }
                return next
            }, onReturned: { _ in
                await tell("steer_returned", "Sending it as its own message", ["rowWritten": phase.withLock { $0 } == 1 ? "true" : "false"])
            })
        return ["status": "ok", "ok": "true", "steered": taken ? "true" : "false"]
    }
}
