import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolParsing
import Experiences
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
// Blueprint: | `MacSyncActionRouter.swift` | `MacSyncActionRouter`, `surfaceSelection`; Canonical mutation receipts and bounded readbacks. |

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
        let surface = clean("surface").lowercased()
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

    nonisolated static func unpinChatSessionID(from payload: [String: String]) -> String? {
        NativeAgentChatSessionID.normalizedPathComponent(
            payload["sessionId"]
        )
    }

    /// Publish organism evidence only after the canonical phone-delivery receipt is durable. Receipt direction is explicit in the current phone schema.
    static func notificationReceiptResponse(
        payload: [String: String],
        confirm: (String, String, String) async -> Bool,
        receive: (String, String) async -> Void
    ) async -> [String: String] {
        let eventID = (payload["eventId"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeAgentDeviceEventIdentity.isCanonical(eventID) else {
            return [
                "status": "error",
                "ok": "false",
                "code": "invalid_event_id",
                "message": "Notification receipt requires a canonical eventId.",
            ]
        }
        let direction = (payload["direction"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// No named run means the session's current turn; named runs must never silently retarget it.
    static func cancelChatRunIDs(from payload: [String: String]) -> [String] {
        let raw = payload["runId"] ?? ""
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
            case "get_agent_thread", "send_agent_message": return observed(try await helpersAction(action))
            case "chat_history_page": return observed(try await chatHistoryPage(action))
            case "faceRead":
                guard let raw = payload["request"], let rawCursor = payload["cursor"], let cursor = Int(rawCursor) else {
                    throw PartCallError(code: "invalid_face_read", message: "faceRead requires a document request and cursor.")
                }
                let request = try JSONDecoder().decode(DocumentRequest.self, from: Data(raw.utf8))
                let page = try await api.faceRead(request, cursor: cursor, revision: payload["revision"], device: action.clientId)
                let response = ["status": "ok", "ok": "true", "page": String(decoding: try JSONEncoder().encode(page), as: UTF8.self)]
                let body = try sync.engine.actionResponse(response, for: action)
                let message = try sync.bridge.cloudKitActionResponseMessage(body, correlationID: action.msgId)
                let bytes = try NAChatMessageCodec.recordValueBytes(NAChatMessageCodec.encode(message))
                guard bytes <= Self.historyPageByteBudget else {
                    throw DeviceSyncError.payloadTooLarge(actualBytes: bytes, maximumBytes: Self.historyPageByteBudget)
                }
                return response
            case "pairDevice":
                return ["status": "ok", "ok": "true", "message": "This phone is paired."]

            case "approveApproval", "rejectApproval", "cancelApproval":
                guard let id = payload["approvalId"], !id.isEmpty else {
                    return observed(["status": "error", "ok": "false", "message": "Missing approvalId"])
                }
                return observed(try await phoneApprovalResponse(id: id,
                    decision: String(action.action.dropLast("Approval".count)), device: action.clientId))
            case "interaction_action":
                guard payload.count == 1, let sealed = payload[SecretActionEnvelope.field] else {
                    return ["status": "error", "ok": "false", "message": "The card answer must be sealed by the paired phone."]
                }
                let fields = try await sync.storage.perform {
                    guard let encoded = try PairingSecret.existingSecretBase64(), let secret = Data(base64Encoded: encoded) else {
                        throw PartCallError(code: "pairing_unavailable", message: "The pairing secret is unavailable; the card was not answered.")
                    }
                    return try SecretActionEnvelope.open(sealed, secret: secret, actionID: action.msgId, actionName: action.action)
                }
                return try await api.answerPhoneInteraction(fields, device: action.clientId)
            case "inboxAction":
                return observed(try await phoneInboxResponse(action))

            // The paired phone's tap answers the row's own action through the person's door.
            case "faceAction":
                guard let page = payload["page"], !page.isEmpty,
                      let row = payload["row"], !row.isEmpty,
                      let faceAction = payload["action"], !faceAction.isEmpty else {
                    return observed(["status": "error", "ok": "false", "code": "invalid_face_action",
                                     "message": "faceAction requires page, row and action."])
                }
                do {
                    if payload["answers"] == "true" {
                        guard let encoded = payload["expectedCall"] else {
                            throw PartCallError(code: "drawn_call_missing", message: "Read the page before acting.")
                        }
                        let call = try JSONDecoder().decode(PartFace.Call.self, from: Data(encoded.utf8))
                        guard let operation = payload["operation"].flatMap(UUID.init(uuidString:)) else {
                            throw PartCallError(code: "operation_missing", message: "The page act needs its operation identity.")
                        }
                        let undoOf = try payload["undoOf"].map { text in
                            guard let id = UUID(uuidString: text) else {
                                throw PartCallError(code: "undo_invalid", message: "The inverse needs its original operation identity.")
                            }
                            return id
                        }
                        let values = try payload["values"].map { encoded in
                            do { return try JSONDecoder().decode([String: PartFace.Value].self, from: Data(encoded.utf8)) }
                            catch { throw PartCallError(code: "invalid_form_values", message: "Form values must be a JSON object of named fields.") }
                        }
                        let outcome = try await api.faceOutcome(page: page, row: row, action: faceAction,
                            value: payload["value"], values: values, formRevision: payload["formRevision"],
                            device: action.clientId, expecting: call, operation: operation,
                            undoOf: undoOf, checking: payload["checking"] == "true")
                        var response = ["status": outcome.unresolved ? "outcome_unknown" : (outcome.accepted ? "ok" : "error"),
                            "effects": outcome.effects.rawValue,
                            "outcome": String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)]
                        if !outcome.unresolved { response["ok"] = outcome.failure == nil && outcome.accepted ? "true" : "false" }
                        if let words = outcome.failure?.localizedDescription ?? outcome.words { response["message"] = words }
                        return observed(response)
                    }
                    guard payload["values"] == nil, payload["formRevision"] == nil else {
                        throw PartCallError(code: "drawn_call_missing", message: "Submit forms through their drawn call and retained operation.")
                    }
                    let words = try await api.faceAction(page: page, row: row, action: faceAction, value: payload["value"], device: action.clientId)
                    var response = ["status": "ok", "ok": "true"]
                    if let words { response["message"] = words }
                    return observed(response)
                } catch let error as PartCallError {
                    return observed(["status": "error", "ok": "false", "code": error.code, "message": error.message])
                }

            case "workActivityState":
                guard let encoded = payload["workIds"] else {
                    return ["status": "error", "ok": "false", "message": "Work state needs its exact work identities."]
                }
                let root = sync.dataRoot
                return try await Task.detached {
                    let ids = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
                    guard !ids.isEmpty, ids.count <= 64, ids.allSatisfy({ $0.hasPrefix("turn:") && $0.count > 5 && $0.count <= 512 }) else {
                        return ["status": "error", "ok": "false", "message": "Invalid work identities."]
                    }
                    var rows: [MobileWorkActivity] = []
                    for id in Set(ids).sorted() {
                        rows.append(try await MacSyncEngine.workActivity(id, dataRoot: root))
                    }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return ["status": "ok", "ok": "true", "activities": String(decoding: try encoder.encode(rows), as: UTF8.self)]
                }.value

            case "registerWorkActivity":
                guard let deviceID = payload["deviceId"], !deviceID.isEmpty,
                      let enabled = payload["enabled"], ["true", "false"].contains(enabled),
                      let environment = payload["environment"],
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
                guard let deviceId = payload["deviceId"], !deviceId.isEmpty,
                      let environment = payload["environment"],
                      let bundleId = payload["bundleId"], !bundleId.isEmpty else {
                    return ["status": "error", "message": "Push registration requires deviceId, environment and bundleId"]
                }
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
                // A discarded target spelling cannot turn a missing run/session into Stop-current.
                guard Set(payload.keys).isSubset(of: ["sessionId", "source", "sourceKey", "runId"]) else {
                    return observed(["status": "error", "ok": "false", "code": "invalid_payload",
                        "message": "cancelChat requires current sessionId, source, sourceKey and runId fields."])
                }
                var sessionId = payload["sessionId"] ?? ""
                let sourceKey = payload["sourceKey"] ?? ""
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
                    // Stop retains exact requested ids across the marker write; absent runs remain pending admission refusals, never claimed stops.
                    let runIDs = Self.cancelChatRunIDs(from: payload)
                    for runID in runIDs {
                        try await iCloudBridge.recordChatStop(session: safeSessionId, runID: runID, dataRoot: sync.dataRoot)
                    }
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
                let changed = try await sync.host.closePinnedChatSession(sessionId)
                if changed {
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
                    "changed": changed ? "true" : "false",
                    "sessionId": sessionId,
                    "pinned": "false",
                ])

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
                // A signed phone action starts its own act on the phone's verified door.
                let request = TurnRequest(message: "", sessionID: nil, surface: "ios",
                    envelope: TurnEnvelope(surface: "ios", commandSignatureVerified: true), pinnedRunID: action.msgId)
                return try await api.remoteMacControl(payload: payload, turn: request.turn())

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
            if action.action == "faceRead" { return ["status": "error", "ok": "false", "message": error.localizedDescription] }
            return observed(["status": "error", "message": error.localizedDescription])
        }
    }

}

extension MacSyncActionRouter {
    /// Signed phone card actions retain the canonical approval and Inbox owners' authority and receipts.
    func phoneApprovalResponse(id: String, decision: String, device: String, inboxItem: String? = nil) async throws -> [String: String] {
        let row = try await sync.host.decidePhoneApproval(id: id, decision: decision, device: device)
        let accepted = row.decision != nil
        var response: [String: String] = ["status": "ok", "ok": "true", "id": row.id, "approvalId": row.id,
            "action": row.action, "title": row.title, "risk": row.risk, "createdAt": row.createdAt,
            "decisionAccepted": accepted ? "true" : "false", "decisionStatus": row.status]
        response["decision"] = row.decision
        response["resolvedAt"] = row.resolvedAt
        response["message"] = row.decisionExperience.face?.words
        if row.decision == "approved" {
            let verdict = row.executionResultClass
            response["result_class"] = verdict.rawValue
            response["status"] = verdict.receipt.status
            response["ok"] = verdict.receipt.ok.map { String($0) }
            response["executionStatus"] = verdict.receipt.status
            if row.executedAction == nil, ["agent.acp.permission", "agent.acp.connect"].contains(row.action),
               row.payload.objectValue?["kind"] == .string("agent_acp_live_approval") {
                response["status"] = "pending_approval"
            }
        }
        // A failed readback cannot undo the completed decision or be serialized as an absent row.
        let projection = await sync.host.workOverview()
        do {
            let canonical = try projection.approvals.get().first { $0.id == id }
            response["approvalJSON"] = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
            response["approvalReadbackRevision"] = String(Date().timeIntervalSince1970)
        } catch { response["approvalReadbackError"] = error.localizedDescription }
        if let inboxItem {
            do {
                let canonical = try projection.inbox.get().first { $0.id == inboxItem }
                response["inboxItemId"] = inboxItem
                response["inboxItemJSON"] = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
                response["inboxReadbackRevision"] = String(Date().timeIntervalSince1970)
            } catch { response["inboxReadbackError"] = error.localizedDescription }
        }
        return response
    }

    func phoneInboxResponse(_ action: InboxAction) async throws -> [String: String] {
        guard let id = action.payload["itemId"], !id.isEmpty,
              let raw = action.payload["actionId"], let answer = InboxActionVocabulary.routedAction(raw, itemID: id) else {
            throw PartCallError(code: "invalid_action", message: "inboxAction requires an itemId and one of its shown actionId values.")
        }
        if !id.hasPrefix("interaction:"), ["approve", "reject"].contains(answer) {
            return try await phoneApprovalResponse(id: id, decision: answer, device: action.clientId, inboxItem: id)
        }
        var response = ["status": "ok", "ok": "true", "itemId": id, "actionId": raw]
        if id.hasPrefix("interaction:"), answer == "act" {
            response.merge(try await sync.host.answerPhoneInteraction(["action": "open", "itemID": id], device: action.clientId)) { _, new in new }
        } else {
            response["message"] = try await sync.host.faceAction(page: "inbox", row: id, action: answer, value: nil, device: action.clientId)
        }
        do {
            let projection = await sync.host.workOverview()
            let canonical = try projection.inbox.get().first { $0.id == id }
            response["inboxItemId"] = id
            response["inboxItemJSON"] = String(decoding: try JSONEncoder().encode(canonical), as: UTF8.self)
            response["inboxReadbackRevision"] = String(Date().timeIntervalSince1970)
        } catch { response["inboxReadbackError"] = error.localizedDescription }
        return response
    }

    /// The current turn reads the arrival, or the phone retains ownership of its separate message.
    func steerChat(_ payload: [String: String]) async -> [String: String] {
        guard let sessionId = payload["sessionId"].flatMap(NativeAgentChatSessionID.normalizedPathComponent),
              let runId = payload["runId"], UUID(uuidString: runId) != nil,
              let text = payload["text"], !text.isEmpty, text.utf8.count <= 64_000 else {
            return ["status": "error", "ok": "false", "message": "steerChat needs a chat, a run id and its words."]
        }
        // The phone names its device on every steer; outcome notices go to that device alone, never to every phone.
        guard let routeKey = payload["routeKey"], AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(routeKey) else {
            return ["status": "error", "ok": "false",
                    "message": "steerChat needs routeKey naming this iPhone (accepted: iphone, iphone:<device name>); nothing was steered."]
        }
        let route = ChatToolSessionContext.ReplyRoute(surface: "ios", sourceKey: routeKey, replyTo: "iphone", correlationId: runId)
        let bridge = sync.bridge
        let attempt = UUID().uuidString
        func tell(_ kind: String, _ words: String) async -> Bool {
            let id = "steer-" + MacSyncSnapshotIntegrity.digest(Data("\(runId)\n\(attempt)\n\(kind)".utf8))
            do {
                _ = try await bridge.sendChatMessage(text: words, sessionID: sessionId, correlationID: runId,
                    metadata: ["kind": kind, "transport": "icloud", "source": "mac", "replyTo": "iphone",
                               "targetSourceKey": routeKey, "steering": "true"], messageID: id)
                return true
            } catch {
                bridge.syncStatus = "Phone steering outcome delivery remains owed: \(error.localizedDescription)"
                nativeLog("[MacSyncEngine] steering outcome %@ remains owed: %@", id, error.localizedDescription)
                return false
            }
        }
        guard await ChatTurnSteering.shared.isTurnOpen(sessionId: sessionId) else {
            return ["status": "ok", "ok": "true", "steered": "false"]
        }
        let turn = TurnRequest(message: text, sessionID: sessionId, surface: "ios",
            envelope: TurnEnvelope(surface: "ios", commandSignatureVerified: true, deliveryRoute: route),
            verifiedSessionID: sessionId, replyRoute: route, pinnedRunID: runId).turn()
        let wait = Task {
            try await TurnAdmission.shared.run(dataRoot: PersistenceCore.defaultDataRoot(), sessionID: sessionId,
                arrival: TurnArrival(words: text, surface: "ios", row: .shown), turn: turn) { _ in }
        }
        let engine = sync.engine
        engine.waitingSteers[sessionId, default: [:]][runId] = { wait.cancel() }
        Task {
            let result = await wait.result
            engine.waitingSteers[sessionId]?[runId] = nil
            switch result {
            case .success(.steered): _ = await tell("steered", "Read in the reply in progress")
            case .failure(let error) where error is CancellationError: _ = await tell("steered", "Stopped before it was read")
            case .success(.ran): _ = await tell("steer_returned", "Sending it as its own message")
            case .failure(let error):
                _ = await tell("notice", "Steering admission failed: \(error.localizedDescription). "
                    + "Your message remains queued. Review the cause, then choose Steer or Send from its queue control.")
            }
        }
        return ["status": "ok", "ok": "true", "steered": "true"]
    }
}
