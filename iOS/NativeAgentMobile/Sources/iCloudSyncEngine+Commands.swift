import Darwin
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `iCloudSyncEngine+Commands.swift` | Signed subject and Table commands, drawn-call page outcomes and read-only reconciliation |

extension iCloudSyncEngine {
    func sendTableEdit(_ edit: TableElementEdit, openingText: String?, observeDispatch: @escaping @MainActor (String?) -> Void) async throws -> String {
        var payload = ["id": edit.id]
        if edit.verb == .put {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload["fields"] = String(decoding: try encoder.encode(edit.fields), as: UTF8.self)
            payload["openingText"] = openingText
        }
        let request = InboxAction.make(action: edit.verb.rawValue, payload: payload)
        return try await sendAction(request, observeDispatch: observeDispatch)
    }

    func tableEditVersion(_ response: [String: String]) throws -> Int? {
        do { _ = try requireSuccessfulActionResponse(response) }
        catch SyncError.macRejected(let message) {
            throw WireFailure(code: response["code"] ?? "table_edit_refused", message: message, cause: nil,
                effects: response["effects"].flatMap(FaceEffects.init(rawValue:)) ?? .none)
        }
        guard let value = response["version"] else { return nil }
        guard let version = Int(value), version >= 0 else {
            throw SyncError.responseUnconfirmed("The Mac returned an unreadable table revision. Read the table before editing again.")
        }
        return version
    }

    func faceOutcome(page: String, submission: FaceActSubmission) async -> FaceActOutcome {
        do {
            var payload = ["page": page, "row": submission.row, "action": submission.action, "answers": "true",
                "operation": submission.id.uuidString, "expectedCall": String(decoding: try JSONEncoder().encode(submission.expectedCall), as: UTF8.self)]
            if let value = submission.value { payload["value"] = value }
            if let values = submission.values {
                payload["values"] = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
            }
            if let revision = submission.formRevision { payload["formRevision"] = revision }
            if let revision = submission.expectedPageRevision { payload["expectedPageRevision"] = revision }
            if let undoOf = submission.undoOf { payload["undoOf"] = undoOf.uuidString }
            if submission.checking { payload["checking"] = "true" }
            let response = try await sendActionAndWait(InboxAction.make(action: "faceAction", payload: payload))
            guard let encoded = response["outcome"] else {
                throw WireFailure(code: "page_reply_unconfirmed", message: "The Mac did not return this page action's outcome.",
                                  cause: response["message"], effects: .unknown)
            }
            return try JSONDecoder().decode(FaceActOutcome.self, from: Data(encoded.utf8))
        } catch { return .interrupted(error) }
    }

    // MARK: - Higher-level mutation helpers

    // A Desk task waits on its original identity; a refusal never submits another task.

    func inboxDecision(id: String, approve: Bool) async throws -> (row: PartFace.Row, submission: FaceActSubmission) {
        guard await refreshFacesSnapshot() else {
            throw SyncError.unsupported("The page's actions have not synced from the Mac yet.")
        }
        let snapshot = faces["inbox"]
        let sections = (snapshot?.levers ?? []) + (snapshot?.keyLevers ?? []) + (snapshot?.drawnFace?.sections ?? [])
        let action = approve ? "approve" : "reject"
        for row in sections.flatMap(\.rows) where row.id == id {
            guard let call = row.actions?.first(where: { $0.id == action })?.call else { continue }
            return (row, .init(id: UUID(), row: id, action: action, value: nil, expectedCall: call,
                               expectedPageRevision: snapshot?.pageRevision))
        }
        throw SyncError.unsupported("Read this page on the phone before acting on its row.")
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
        return try requireSuccessfulActionResponse(await sendActionAndWait(action))
    }

    // MARK: - Mac Control (iOS → Mac remote actions)
    // Mac authority checks own control admission; all actions retain signed retry identity.
    private func macControlResult(_ action: InboxAction) async throws -> String {
        let raw = try await sendActionAndWait(action)
        let result: [String: String]
        do { result = try requireSuccessfulActionResponse(raw) }
        catch {
            if case SyncError.approvalRequired = error { throw error }
            if raw["effects"] == "none" {
                throw WireFailure(code: raw["code"] ?? "mac_control_refused", message: error.localizedDescription,
                    cause: nil, effects: .none)
            }
            throw error
        }
        if result["blocked"] == "true" {
            throw WireFailure(code: result["code"] ?? "mac_control_blocked",
                message: result["message"] ?? result["error"] ?? "Mac control denied.", cause: nil, effects: .none)
        }
        guard let text = result["result"] else {
            throw SyncError.responseUnconfirmed("The Mac's signed control reply omitted its result. Read the Mac outcome before submitting again.")
        }
        return text
    }

    private func sendMacControl(_ action: PhoneMacControlAction, arguments: [String: String]) async throws -> String {
        try await macControlResult(InboxAction.make(action: "mac_control", payload: action.payload(arguments)))
    }

    func macNotify(title: String, message: String) async throws -> String {
        try await sendMacControl(.notification, arguments: ["title": title, "message": message])
    }

    func macSetVolume(percent: Int) async throws -> String {
        guard MacVolumeControlPresentation.isValid(percent: percent) else {
            throw SyncError.unsupported("Volume must be between 0% and 100%.")
        }
        return try await sendMacControl(.volume, arguments: ["value": "\(percent)"])
    }

    func macSpotlight(query: String) async throws -> String {
        try await sendMacControl(.spotlight, arguments: ["query": query])
    }

    // MARK: - Telegram control
    // MARK: - Provider control

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
            .make(action: text == nil ? "get_agent_thread" : "send_agent_message", payload: payload)))
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
}
