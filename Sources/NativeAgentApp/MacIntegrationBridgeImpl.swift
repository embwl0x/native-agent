import Foundation
import ChatOrchestration
import MacControl
import MacIntegration
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// App-side implementation of the `MacIntegrationToolBridge` protocol declared
/// in ChatOrchestration. The chat tool dispatcher calls this whenever Agent
/// invokes one of the 5 Phase-1 macOS integration tools
/// (`mac_calendar_list_upcoming`, `mac_reminders_list_due_today`, `mac_notify`,
/// `mobile_notify`, `mac_spotlight_search`). Permission gating happens INSIDE
/// the dispatcher via `MacIntegrationPermissionStore.shared.allows(...)` —
/// this bridge assumes the gate already approved the call and just runs the
/// real backend.
///
/// The actual backends live in app code (`MacPIMConnectorActions` for EventKit,
/// `NativeAgentNotifications` for Mac local notifications, `MacSyncEngine` for
/// iOS push, the MacControl-spotlight dispatch path). ChatOrchestration (Core)
/// can't import them directly, so this bridge struct stitches them together
/// app-side and gets injected via the factory in `AppChatToolDispatcher`.
struct MacIntegrationBridgeImpl: MacIntegrationToolBridge {
    func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarListUpcoming(input: input)
    }

    func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersListDueToday(input: input)
    }

    func macNotify(input: [String: JSONValue]) async throws -> JSONValue {
        // Mirror the shape NativeClient.runMacNotify uses so the chat-tool
        // path returns the same envelope the connector-action path does.
        let title = NativeAgentNotificationDefaults.title(
            (input["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        )
        let message = (input["message"]?.stringValue ?? input["body"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw NSError(domain: "NativeAgentMacIntegrationBridge", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mac_notify requires message",
            ])
        }
        let result = await NativeAgentNotifications.postAndReport(title: title, body: message)
        var obj = result.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    func mobileNotify(input: [String: JSONValue]) async throws -> JSONValue {
        let title = NativeAgentNotificationDefaults.title(
            (input["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        )
        let message = (input["message"]?.stringValue ?? input["body"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw NSError(domain: "NativeAgentMacIntegrationBridge", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mobile_notify requires message",
            ])
        }
        let source = input["source"]?.stringValue ?? "chat_tool"
        // B5 review round 2 (MED): pass through the same routing params the
        // AppChatToolDispatcher shim preserves (screen/urgency, + surface when
        // the caller provides one) — the two paths reach the same backend and
        // must hand it the same envelope, or unwrapped workshop/tool-step
        // notifies render differently from wrapped-chat ones.
        let screen = input["screen"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urgency = input["urgency"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var userInfo: [String: String] = [
            "screen": (screen?.isEmpty == false ? screen! : "inbox"),
            "source": source,
            "urgency": (urgency?.isEmpty == false ? urgency! : "normal"),
        ]
        if let surface = input["surface"]?.stringValue, !surface.isEmpty {
            userInfo["surface"] = surface
        }
        let receipt = try await MacSyncEngine.shared.sendNotificationToPairedDevices(
            title: title,
            body: message,
            userInfo: userInfo
        )
        var obj = receipt.deliveryFields()
        obj.merge([
            "title": .string(NativeAppSecretRedactor.redactText(title)),
            "messagePreview": .string(NativeAppSecretRedactor.redactText(String(message.prefix(200)))),
        ]) { _, new in new }
        return .object(obj)
    }

    // MARK: - Phase 2 (2026-06-07): Contacts + AppleScript bridges
    //
    // Permission gating is enforced in the Core dispatcher
    // (`dispatchMacIntegrationTool`) before any of these run — so each
    // delegate-only impl just forwards to the W1/W2 backends. The toggle
    // for each pair lives in the new Mac Integration tab; default
    // read=ON / write=OFF for the sensitive ids (the user's matrix).

    func contactsSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.search(input: input)
    }

    func contactsCreateOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.createOrUpdate(input: input)
    }

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    func mailSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSearch(input: input)
    }

    func mailSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailSend(input: input)
    }

    func messagesRecentThreads(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesRecentThreads(input: input)
    }

    func messagesSend(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.messagesSend(input: input)
    }

    func notesSearch(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesSearch(input: input)
    }

    func notesCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesCreate(input: input)
    }

    func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicNowPlaying(input: input)
    }

    func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicControl(input: input)
    }

    // MARK: - Phase 3 (2026-06-07): complete read+write coverage on every toggle
    //
    // the user asked for "complete complete" — every toggle in the Mac Integration
    // tab now has tools behind it. EventKit writes for calendar + reminders;
    // mail manage (mark/archive/delete/reply); notes update; music library
    // search; contacts delete; scheduler list+create. Sensitive writes stay
    // default-OFF; toggling Write ON in the tab unlocks the matching tools.

    // EventKit writes (W1)

    func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarCreateEvent(input: input)
    }

    func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.calendarModifyEvent(input: input)
    }

    func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersCreate(input: input)
    }

    func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacPIMConnectorActions.remindersComplete(input: input)
    }

    // Mail manage (W2)

    func mailMarkRead(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailMarkRead(input: input)
    }

    func mailArchive(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailArchive(input: input)
    }

    func mailDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailDelete(input: input)
    }

    func mailReply(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailReply(input: input)
    }

    // Notes update (W2)

    func notesUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.notesUpdate(input: input)
    }

    // Music library (W2)

    func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicSearchLibrary(input: input)
    }

    func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListLibrary(input: input)
    }

    func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.musicListPlaylists(input: input)
    }

    // Contacts delete (inline)

    func contactsDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacContactsAdapter.delete(input: input)
    }

    // Scheduler (delegates to the existing NativeClient SwiftNative path —
    // promoted from private to internal for this).

    func schedulerListJobs(input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeClient.runSchedulerListJobs()
    }

    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await NativeClient.runSchedulerCreateJob(input: input)
    }

    // MARK: - Phase 1

    func spotlightSearch(input: [String: JSONValue]) async throws -> JSONValue {
        let query = (input["query"]?.stringValue ?? input["q"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NSError(domain: "NativeAgentMacIntegrationBridge", code: -400, userInfo: [
                NSLocalizedDescriptionKey: "mac_spotlight_search requires query",
            ])
        }
        // Dispatch through MacControl's spotlight action (same path the
        // connector-action route uses). gpt-5.5 review BLOCKING fix: thread
        // the TrustCenter policy provider + audit path so the in-process
        // preflight runs and refusals get logged to the shared audit file —
        // matches NativeClient.runMacSpotlightSearch (~L8644). Bare
        // makeMacControl() disabled the policy preflight and was a security
        // regression vs the connector-action route.
        let auditPath = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("mac_control_audit.jsonl")
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(),
            auditAppendPath: auditPath
        )
        let result = try await impl.dispatch(action: "spotlight", body: input)
        var obj: [String: JSONValue] = [
            "status": .string(result.ok ? "completed" : "failed"),
            "action": .string(result.action),
            "ok": .bool(result.ok),
            "durationMs": .int(Int64(result.durationMs)),
            "viaSwift": .bool(result.viaSwift),
            "output": result.output,
        ]
        if let error = result.error { obj["error"] = .string(error) }
        if let httpStatus = result.httpStatus { obj["httpStatus"] = .int(Int64(httpStatus)) }
        return NativeAppSecretRedactor.redactValue(.object(obj))
    }
}

// MARK: - JSONValue convenience

private extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
