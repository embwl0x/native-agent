import Foundation
import CognitiveSubstrate
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import ProviderRouting

@MainActor
struct MacSyncActionRouter {
    struct MacIntegrationPermissionRequest: Equatable, Sendable {
        let id: String
        let read: Bool
        let write: Bool
    }

    nonisolated static func macIntegrationPermissionRequest(
        from payload: [String: String]
    ) -> MacIntegrationPermissionRequest? {
        let id = (payload["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func exactBool(_ key: String) -> Bool? {
            switch (payload[key] ?? "").lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        guard MacIntegrationID.all.contains(id),
              let read = exactBool("read"),
              let write = exactBool("write") else {
            return nil
        }
        return MacIntegrationPermissionRequest(id: id, read: read, write: write)
    }

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
            "provider_id": providerID,
            "model": model,
            "reasoning_effort": reasoningEffort,
            "service_tier": serviceTier,
        ]
    }

    nonisolated static func unpinChatSessionID(from payload: [String: String]) -> String? {
        NativeAgentChatSessionID.normalizedPathComponent(
            payload["sessionId"] ?? payload["session_id"]
        )
    }

    var cancelChatTask: (String) -> Bool

    func dispatch(_ action: InboxAction) async -> [String: String] {
        let payload = action.payload
        let actionName = action.action
        var cognitiveResponse: [String: String]?
        defer {
            Task {
                await NativeCognitionRuntime.shared.ingestOrganismSignal(
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
                    await NativeCognitionRuntime.shared.observeRemoteAction(
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

        if let denial = iCloudActionDenial(action) {
            return observed(["status": "error", "message": denial])
        }

        let api = NativeClient(baseURL: "")

        func approvalAllowsRemoteResolve(_ approvalId: String) async throws -> Bool {
            guard let row = try await api.getApprovals().first(where: { $0.id == approvalId }) else {
                return true
            }
            return row.localOnly != true && row.remoteResolvable != false
        }

        do {
            switch action.action {
            case "submitWorkshopTask", "submitMission":
                let title = payload["title"] ?? "iOS Workshop Task"
                let objective = payload["objective"] ?? ""
                let result = try await api.submitWorkshopExecution(title: title, objective: objective)
                return [
                    "status": "ok",
                    "missionId": result.executionId ?? result.id ?? "",
                    "deskHandle": result.desk_handle ?? "",
                    "deskAlias": result.desk_alias ?? "",
                ]

            case "approveStep":
                let executionId = payload["missionId"] ?? ""
                let stepId = payload["stepId"] ?? ""
                guard !executionId.isEmpty, !stepId.isEmpty, stepId != "pending" else {
                    return ["status": "error", "error": "missing_real_step_id"]
                }
                _ = try await api.approveStep(executionId: executionId, stepId: stepId)
                return ["status": "ok"]

            case "rejectStep":
                let executionId = payload["missionId"] ?? ""
                let stepId = payload["stepId"] ?? ""
                guard !executionId.isEmpty, !stepId.isEmpty, stepId != "pending" else {
                    return observed(["status": "error", "error": "missing_real_step_id"])
                }
                _ = try await api.rejectStep(executionId: executionId, stepId: stepId, reason: "Rejected from iCloud")
                return observed(["status": "ok"])

            case "approveMemoryProposal":
                let proposalId = payload["proposalId"] ?? ""
                let result = try await api.approveMemoryProposal(id: proposalId)
                return stringifyResponse(result, fallbackStatus: "ok")

            case "rejectMemoryProposal":
                let proposalId = payload["proposalId"] ?? ""
                let result = try await api.rejectMemoryProposal(id: proposalId, reason: "Rejected via iOS")
                return observed(stringifyResponse(result, fallbackStatus: "ok"))

            case "deleteMemory":
                let memoryId = payload["memoryId"] ?? payload["id"] ?? ""
                guard !memoryId.isEmpty else { return observed(["status": "error", "message": "Missing memoryId"]) }
                let result = try await api.deleteMemory(id: memoryId)
                return observed(stringifyResponse(result, fallbackStatus: "ok"))

            case "approvePromotion":
                let candidateId = payload["candidateId"] ?? ""
                _ = try await api.approvePromotionPending(id: candidateId)
                return ["status": "ok"]

            case "rejectPromotion":
                let candidateId = payload["candidateId"] ?? ""
                _ = try await api.rejectPromotionPending(id: candidateId, reason: "Rejected via iOS")
                return observed(["status": "ok"])

            case "approveOrganismReflex":
                let candidateId = payload["candidateId"] ?? payload["candidate_id"] ?? ""
                guard !candidateId.isEmpty else {
                    return observed(["status": "error", "message": "Missing candidateId"])
                }
                _ = await NativeCognitionRuntime.shared.reviewOrganismReflexCandidate(
                    id: candidateId,
                    decision: .approve,
                    note: "Approved from iOS",
                    reviewedBy: "operator",
                    source: "ios_signed_action"
                )
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "candidateId": candidateId,
                    "decision": OrganismReflexReviewDecision.approve.rawValue,
                ])

            case "retireOrganismReflex":
                let candidateId = payload["candidateId"] ?? payload["candidate_id"] ?? ""
                guard !candidateId.isEmpty else {
                    return observed(["status": "error", "message": "Missing candidateId"])
                }
                _ = await NativeCognitionRuntime.shared.reviewOrganismReflexCandidate(
                    id: candidateId,
                    decision: .retire,
                    note: "Retired from iOS",
                    reviewedBy: "operator",
                    source: "ios_signed_action"
                )
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "candidateId": candidateId,
                    "decision": OrganismReflexReviewDecision.retire.rawValue,
                ])

            case "approveApproval":
                let approvalId = payload["approvalId"] ?? payload["id"] ?? ""
                guard !approvalId.isEmpty else { return ["status": "error", "message": "Missing approvalId"] }
                guard try await approvalAllowsRemoteResolve(approvalId) else {
                    return ["status": "error", "error": "approval_local_only", "message": "Approval must be reviewed on the Mac app."]
                }
                let row = try await api.resolveApproval(id: approvalId, decision: "approve")
                return approvalActionResponse(approvalRequestToDict(row), approvalId: approvalId, fallbackStatus: "approved")

            case "rejectApproval":
                let approvalId = payload["approvalId"] ?? payload["id"] ?? ""
                guard !approvalId.isEmpty else { return observed(["status": "error", "message": "Missing approvalId"]) }
                guard try await approvalAllowsRemoteResolve(approvalId) else {
                    return observed(["status": "error", "error": "approval_local_only", "message": "Approval must be reviewed on the Mac app."])
                }
                let row = try await api.resolveApproval(id: approvalId, decision: "reject")
                return observed(approvalActionResponse(approvalRequestToDict(row), approvalId: approvalId, fallbackStatus: "rejected"))

            case "cancelApproval":
                let approvalId = payload["approvalId"] ?? payload["id"] ?? ""
                guard !approvalId.isEmpty else { return observed(["status": "error", "message": "Missing approvalId"]) }
                guard try await approvalAllowsRemoteResolve(approvalId) else {
                    return observed(["status": "error", "error": "approval_local_only", "message": "Approval must be reviewed on the Mac app."])
                }
                let row = try await api.resolveApproval(id: approvalId, decision: "cancel")
                return observed(approvalActionResponse(approvalRequestToDict(row), approvalId: approvalId, fallbackStatus: "canceled"))

            case "inboxAction":
                let itemId = payload["itemId"] ?? payload["id"] ?? ""
                let actionId = payload["actionId"] ?? payload["action"] ?? "act"
                guard !itemId.isEmpty else { return ["status": "error", "message": "Missing inbox item id"] }
                guard !actionId.isEmpty else { return ["status": "error", "message": "Missing inbox action"] }
                let nativeActions: Set<String> = ["read", "archive", "dismiss", "act", "reply", "approve", "reject", "repair", "open_approvals"]
                let normalizedAction = actionId == "deny" ? "reject" : actionId
                let endpointAction = nativeActions.contains(normalizedAction) ? normalizedAction : "act"
                if endpointAction == "approve" || endpointAction == "reject" {
                    guard try await approvalAllowsRemoteResolve(itemId) else {
                        return observed([
                            "status": "error",
                            "error": "approval_local_only",
                            "message": "Approval must be reviewed on the Mac app.",
                        ])
                    }
                }
                try await api.inboxAction(itemId, action: endpointAction)
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "itemId": itemId,
                    "actionId": actionId,
                ])

            case "inboxReply":
                // Compatibility boundary for older iOS builds/cards only.
                // Current iOS does not present this action: proactive inbox
                // items have no typed reply destination, transcript owner, or
                // user-visible result contract. Do not improvise those semantics
                // by silently turning a card reply into an arbitrary chat turn.
                let itemId = payload["itemId"] ?? payload["id"] ?? ""
                let replyText = payload["replyText"] ?? payload["reply_text"] ?? payload["message"] ?? ""
                guard !itemId.isEmpty else { return ["status": "error", "message": "Missing inbox item id"] }
                guard !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ["status": "error", "message": "Missing reply text"]
                }
                return [
                    "status": "error",
                    "ok": "false",
                    "code": "not_implemented",
                    "message": "Inbox reply is not yet supported from iOS.",
                    "itemId": itemId,
                ]

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
                    token: token,
                    environment: environment,
                    bundleId: bundleId
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
                let eventID = (payload["eventId"] ?? payload["event_id"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "code": "invalid_event_id",
                        "message": "Notification receipt requires a canonical eventId.",
                    ])
                }
                let channel = String((payload["channel"] ?? "ios").prefix(80))
                await MacSyncMobileNotificationRelay.receiveDeliveryPrediction(
                    eventID: eventID,
                    channel: channel
                )
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "eventId": eventID,
                    "channel": channel,
                ])

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
                    let taskCancelled = cancelChatTask(safeSessionId)
                    _ = try await api.cancelChatSession(sessionId: safeSessionId)
                    return observed([
                        "status": "ok",
                        "ok": "true",
                        "sessionId": safeSessionId,
                        "taskCancelled": taskCancelled ? "true" : "false",
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
                let current = MacPinnedChatSessionStore.load()
                let next = current.filter { $0 != sessionId }
                if next != current {
                    try MacPinnedChatSessionStore.save(next)
                    await MacSyncEngine.shared.writeSnapshots()
                }
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "applied": "true",
                    "changed": next == current ? "false" : "true",
                    "sessionId": sessionId,
                    "pinned": "false",
                ])

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
                let detail = result.detail ?? result.error ?? result.response ?? ""
                return observed(["status": result.status, "detail": detail, "provider_id": providerId])

            case "clear_provider":
                let providerId = payload["providerId"] ?? ""
                guard !providerId.isEmpty else { return ["status": "error", "message": "Missing providerId"] }
                _ = try await api.clearProvider(providerId)
                return ["status": "ok", "provider_id": providerId]

            case "set_active_provider":
                let surface = payload["surface"] ?? "chat"
                let providerId = payload["provider_id"] ?? "codex"
                _ = try await api.setActiveProvider(surface: surface, providerId: providerId)
                return ["status": "ok", "ok": "true", "surface": surface, "provider_id": providerId]

            case "set_surface_model":
                let surface = payload["surface"] ?? "chat"
                let model = payload["model"] ?? ""
                guard !model.isEmpty else {
                    return ["status": "error", "message": "Missing model"]
                }
                let reasoning = payload["reasoning_effort"]
                let serviceTier = payload["service_tier"]
                if let reasoning, !reasoning.isEmpty {
                    _ = try await api.configureModel(
                        surface: surface,
                        model: model,
                        reasoningEffort: reasoning,
                        serviceTier: serviceTier,
                        inferProvider: false
                    )
                } else {
                    _ = try await api.setSurfaceModel(
                        surface: surface,
                        model: model,
                        inferProvider: false
                    )
                }
                return ["status": "ok", "ok": "true", "surface": surface, "model": model]

            case "configure_surface_selection":
                guard let request = Self.surfaceSelection(from: payload) else {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "message": "A complete valid provider/model/reasoning/tier tuple is required for a canonical surface",
                    ])
                }
                _ = try await api.configureSurfaceSelection(
                    surface: request.surface,
                    providerID: request.providerID,
                    model: request.model,
                    reasoningEffort: request.reasoningEffort,
                    serviceTier: request.serviceTier
                )
                // Return the recovered owner state, not the optimistic request.
                // ProviderRouting may normalize effort/tier or reconcile a model
                // that the selected provider cannot actually serve.
                let recovered = try await SwiftNativeProviderRouting()
                    .checkedRoutingSnapshot()
                guard let preference = ProviderRoutingSurfaceLookup.value(
                          recovered.preferences, request.surface),
                      let providerID = ProviderRoutingSurfaceLookup.value(
                          recovered.activeProviders, request.surface),
                      !providerID.isEmpty else {
                    throw ProviderRoutingError.configurationFailed(
                        "Surface selection did not recover a complete tuple"
                    )
                }
                return observed(Self.canonicalSurfaceSelectionResponse(
                    surface: request.surface,
                    providerID: providerID,
                    model: preference.model,
                    reasoningEffort: preference.reasoningEffort,
                    serviceTier: preference.serviceTier
                ))

            case "set_mac_integration_permission":
                guard let request = Self.macIntegrationPermissionRequest(from: payload) else {
                    return observed([
                        "status": "error",
                        "ok": "false",
                        "code": "invalid_mac_integration_permission",
                        "message": "A known integration id and exact read/write booleans are required.",
                    ])
                }
                try await MacIntegrationPermissionStore.shared.set(
                    integrationId: request.id,
                    read: request.read,
                    write: request.write
                )
                guard let recovered = try await MacIntegrationPermissionStore.shared
                    .currentChecked()[request.id] else {
                    throw NSError(
                        domain: "MacSyncActionRouter",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Mac integration permission read-back failed"]
                    )
                }
                MacIntegrationICloudBridge.shared.push(
                    id: request.id,
                    read: recovered.read,
                    write: recovered.write
                )
                return observed([
                    "status": "ok",
                    "ok": "true",
                    "id": request.id,
                    "read": String(recovered.read),
                    "write": String(recovered.write),
                ])

            case "mac_control":
                return try await MacSyncRemoteMacControl(api: api).dispatch(payload: payload)

            default:
                return observed(["status": "error", "message": "Unknown action: \(action.action)"])
            }
        } catch {
            return observed(["status": "error", "message": error.localizedDescription])
        }
    }

    private func iCloudActionDenial(_ action: InboxAction) -> String? {
        switch action.action {
        case "permissionPolicy":
            return "Permission policy changes must be run locally on the Mac."
        default:
            return nil
        }
    }

    private func stringifyResponse(_ result: [String: Any], fallbackStatus: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in result {
            if let string = value as? String {
                out[key] = string
            } else if let bool = value as? Bool {
                out[key] = bool ? "true" : "false"
            } else {
                out[key] = "\(value)"
            }
        }
        let error = out["error"] ?? out["code"]
        if out["ok"] == "false" || !(error?.isEmpty ?? true) {
            out["status"] = "error"
            out["ok"] = "false"
            out["message"] = out["message"] ?? error
        } else {
            out["status"] = out["status"] ?? fallbackStatus
        }
        return out
    }

    private func approvalRequestToDict(_ row: ApprovalRequest) -> [String: Any] {
        var dict: [String: Any] = [
            "ok": true,
            "id": row.id,
            "status": row.status,
            "action": row.action,
            "title": row.title,
            "risk": row.risk,
        ]
        if let decision = row.decision { dict["decision"] = decision }
        if let resolvedAt = row.resolvedAt { dict["resolvedAt"] = resolvedAt }
        if let createdAt = row.createdAt { dict["createdAt"] = createdAt }
        if let reason = row.reason { dict["reason"] = reason }
        return dict
    }

    private func approvalActionResponse(_ result: [String: Any], approvalId: String, fallbackStatus: String) -> [String: String] {
        var out = stringifyResponse(result, fallbackStatus: fallbackStatus)
        out["approvalId"] = approvalId
        if let error = result["error"] as? String, !error.isEmpty {
            out["message"] = error
            out["status"] = "error"
            out["ok"] = "false"
        }
        if (result["ok"] as? Bool) == false {
            out["status"] = "error"
            out["ok"] = "false"
        }
        if let executed = result["executedAction"] as? [String: Any] {
            let executedOk = executed["ok"] as? Bool
            let executedStatus = (executed["status"] as? String ?? "").lowercased()
            if let status = executed["status"] as? String, !status.isEmpty {
                out["status"] = status
            }
            if let error = executed["error"] as? String, !error.isEmpty {
                out["message"] = error
                out["status"] = "error"
                out["ok"] = "false"
            } else if let message = executed["message"] as? String, !message.isEmpty {
                out["message"] = message
            }
            if executedOk == false || ["error", "failed", "blocked"].contains(executedStatus) {
                out["status"] = "error"
                out["ok"] = "false"
            }
        }
        if let decision = result["decision"] as? String, out["decision"] == nil {
            out["decision"] = decision
        }
        return out
    }

}
