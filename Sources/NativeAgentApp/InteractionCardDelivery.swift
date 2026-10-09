import Foundation
import SwiftUI
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import NotificationInbox
import ApprovalTransactions
import AttentionRouting
import Privacy
import AppToolRuntime
import MacIntegration
import ChatOrchestration
import ProviderRouting

/// Inbox rows are pointers. The originating transcript still owns the card,
/// its revision, verification and continuation, on every surface.
enum InteractionCardDelivery {
    static let source = "interaction"

    /// Only DeviceSync's authenticated paired-phone action calls this entry.
    /// Secrets arrive encrypted; the transcript still owns revision and settlement.
    @MainActor
    static func answer(payload: [String: String], actionID: String, clientID: String, dataRoot: URL) async throws -> [String: String] {
        if payload["action"] == "open", let itemID = payload["itemID"], payload.count == 2 {
            let pointer = try await pointer(id: itemID, dataRoot: dataRoot)
            return ["status": "ok", "ok": "true", "sessionID": pointer.sessionID]
        }
        guard let session = payload["sessionID"], NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              let id = payload["interactionID"], let revision = Int(payload["revision"] ?? ""),
              let action = payload["action"], ["primary", "decline", "verify"].contains(action),
              payload.count <= 12, payload.values.allSatisfy({ $0.utf8.count <= 16_384 }),
              let card = await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot),
              card.revision == revision else {
            throw NSError(domain: "InteractionCard", code: 4, userInfo: [NSLocalizedDescriptionKey: "This card changed. Refresh the conversation and try again."])
        }
        if action == "decline" {
            let settled = try await InlineInteractionResolver.decline(id: id, sessionID: session,
                expectedRevision: revision, dataRoot: dataRoot)
            return ["status": "ok", "ok": "true", "state": settled.state.name]
        }
        if action == "verify" {
            var selection: String? = card.target
            if card.kind == .modelChoice {
                let snapshot = try await SwiftNativeProviderRouting(dataRoot: dataRoot).checkedRoutingSnapshotReadOnly()
                let surfaces = ProviderSurfaceGroups.all.first { $0.id == card.target }?.surfaces ?? [card.target]
                selection = surfaces.compactMap { ProviderRoutingSurfaceLookup.value(snapshot.preferences, $0)?.model }
                    .first { !$0.isEmpty }
            }
            let checked = card.state.failureReason == nil ? card : try await InlineInteractionResolver.begin(
                id: id, sessionID: session, expectedRevision: revision, dataRoot: dataRoot)
            let settled = try await InlineInteractionResolver.complete(id: id, sessionID: session,
                selection: selection, scope: card.kind == .modelChoice ? .persistent : nil,
                expectedRevision: checked.revision, dataRoot: dataRoot)
            return ["status": settled.state.failureReason == nil ? "ok" : "error",
                    "ok": settled.state.failureReason == nil ? "true" : "false", "state": settled.state.name,
                    "message": settled.state.failureReason ?? settled.state.outcome?.summary ?? ""]
        }
        let descriptor = InlineInteractionResolver.descriptor(for: card, dataRoot: dataRoot)
        guard let model = QuietSelfAdmin.shared.appModel else {
            throw NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Mac's controls are unavailable."])
        }
        switch descriptor.control {
        case .internetAccounts, .chromeSetup, .pairDevice, .trustPostureRequired, .connectorOAuth:
            return ["status": "error", "message": "This request needs its Mac setup control. Complete it on the Mac, then tap Check again here."]
        case .unknown, .unavailable:
            return ["status": "error", "message": descriptor.unavailableReason ?? "This build has no control for this card."]
        default: break
        }
        if card.kind == .choose || card.kind == .modelChoice {
            guard let choice = payload["choice"], card.options.contains(where: { $0.id == choice }),
                  choice != InlineInteractionRegistry.persistentChoiceOptionID else {
                return ["status": "error", "message": "Choose one of this card's options."]
            }
        }
        if card.kind == .modelChoice, let scope = payload["scope"], InlineInteraction.Scope(rawValue: scope) == nil {
            return ["status": "error", "message": "Choose this request or the provider group for this model."]
        }
        if descriptor.control == .connectorManualToken, (payload["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["status": "error", "message": "Enter the connector token to continue."]
        }
        if descriptor.control == .providerAPIKey, (payload["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["status": "error", "message": "Enter the provider key or setup token to continue. Browser sign-in needs the Mac."]
        }
        let running = try await InlineInteractionResolver.begin(id: id, sessionID: session,
            expectedRevision: revision, dataRoot: dataRoot)
        let scope = payload["scope"].flatMap(InlineInteraction.Scope.init(rawValue:)) ?? card.primaryScope
        var setupError: String?
        var note: String?
        switch descriptor.control {
        case .connectorManualToken:
            let outcome = await InlineConnectorSetup.save(connector: descriptor.target, values: payload,
                appModel: model, dataRoot: dataRoot)
            setupError = outcome.error
            note = outcome.note
        case .providerAPIKey:
            if descriptor.target == "anthropic_oauth_direct" {
                setupError = AnthropicSetupTokenInput.save(payload["value"] ?? "")
                if let raw = setupError {
                    setupError = InlineConnectorSetup.failureReason(raw, service: "Claude", secret: "setup token",
                        typed: [payload["value"] ?? ""])
                } else {
                    await model.loadProvidersForChat()
                    await model.adoptProviderForBlankSurfaces(descriptor.target)
                }
            } else {
                let outcome = await InlineConnectorSetup.saveProviderKey(payload["value"] ?? "",
                    provider: descriptor.target, appModel: model)
                setupError = outcome.error
                note = outcome.note
            }
        case .macPermissionGrant:
            let mode = card.mode
            let categories = card.allTargets.filter(InlineInteractionRegistry.isMacControlCategory)
            for target in card.allTargets where MacIntegrationID.all.contains(target) {
                do {
                    _ = try await MacIntegrationPermissionStore.shared.setWithReceipt(integrationId: target,
                        read: MacIntegrationID.supportsRead(target) && (mode?.wantsRead ?? true),
                        write: MacIntegrationID.supportsWrite(target) && (mode?.wantsWrite ?? true),
                        actionID: "\(actionID)-\(target)", surface: "ios", provenance: .signedIOS(clientID: clientID),
                        onlyAddingAxes: true)
                } catch { setupError = "The Mac could not save the requested access. Check Trust on the Mac." }
            }
            if !categories.isEmpty {
                await AppToolExecutor.applyMacControlCategoryGrant(categories, appModel: AppQuietSettingsHost(model),
                    dataRoot: dataRoot, logTag: "signed-phone-card")
            }
        case .capabilityFlag:
            if let flag = InlineInteractionRegistry.capabilityFlags[card.target] {
                await AppToolExecutor.applyCapabilityFlagGrant(policyKey: flag.policyKey,
                    appModel: AppQuietSettingsHost(model), dataRoot: dataRoot, logTag: "signed-phone-card", requireFullMac: false)
            }
        case .providerGroupModel where (scope ?? .persistent) == .persistent:
            do {
                guard let group = ProviderSurfaceGroups.all.first(where: { $0.id == card.target }),
                      let picked = payload["choice"] else { throw ProviderRoutingError.invalidRequest }
                let option = InlineInteractionRegistry.splitModelOptionID(picked)
                _ = try await model.saveProviderGroupSelection(group: group, providerID: option?.providerID,
                    model: option?.modelID ?? picked)
            } catch { setupError = error.localizedDescription }
        default: break
        }
        let settled = try await InlineInteractionResolver.complete(id: id, sessionID: session,
            selection: payload["choice"] ?? card.target, scope: card.kind == .modelChoice ? scope : nil,
            expectedRevision: running.revision, setupError: setupError, note: note, dataRoot: dataRoot)
        return ["status": settled.state.failureReason == nil ? "ok" : "error",
                "ok": settled.state.failureReason == nil ? "true" : "false", "state": settled.state.name,
                "message": settled.state.failureReason ?? settled.state.outcome?.summary ?? ""]
    }

    struct Pointer: Sendable {
        let sessionID: String
        let interactionID: String
    }

    static func pointer(id: String, dataRoot: URL) async throws -> Pointer {
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        guard let value = try await inbox.rows().first(where: {
            guard case .object(let row) = $0 else { return false }
            return row["id"] == .string(id)
        }), case .object(let row) = value,
              row["source"] == .string(source),
              case .string(let session)? = row["interaction_session_id"],
              NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              case .string(let interaction)? = row["interaction_id"] else {
            throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
            ])
        }
        return Pointer(sessionID: session, interactionID: interaction)
    }

    @MainActor
    static func observe() async {
        // Register before recovery so an arrival racing the initial read is
        // buffered. Notifications carry IDs only, never authority or secrets.
        let changes = NotificationCenter.default.notifications(named: InlineInteractionWire.changedNotification)
            .compactMap { $0.object as? String }
        let root = PersistenceCore.defaultDataRoot()
        // Recover delivery pointers from durable cards after a relaunch. This
        // is one pass, not a polling scan; subsequent reads target one session.
        // Only transcripts whose bytes hold an interaction row are parsed: the
        // rest have no card to recover, and parsing every one held the launch.
        let sessions = await Task.detached(priority: .utility) {
            let directory = root.appendingPathComponent("chat/messages", isDirectory: true)
            let marker = Data(InlineInteractionWire.transcriptKind.utf8)
            do {
                return try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
                    .filter { url in
                        // An unreadable one is still handed on, so its read failure is logged.
                        autoreleasepool {
                            (try? Data(contentsOf: url, options: .alwaysMapped)).map { $0.range(of: marker) != nil } ?? true
                        }
                    }
                    .map { $0.deletingPathExtension().lastPathComponent }
            } catch {
                nativeLog("[interaction-notification] recovery read failed: %@", error.localizedDescription)
                return []
            }
        }.value
        for session in sessions {
            guard !Task.isCancelled else { return }
            await refresh(sessionID: session, dataRoot: root, notify: false)
        }
        await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
        for await session in changes {
            guard !Task.isCancelled else { return }
            await refresh(sessionID: session, dataRoot: root, notify: true)
        }
    }

    @MainActor
    private static func refresh(sessionID: String, dataRoot: URL, notify: Bool) async {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID else { return }
        let result = await InlineInteractionResolver.checkedInteractionsByRow(sessionID: sessionID, dataRoot: dataRoot)
        guard case .success(let pairs) = result, !pairs.isEmpty else { return }
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let activeIDs: Set<String>
        do {
            activeIDs = Set(try await inbox.rows().compactMap { value in
                guard case .object(let row) = value,
                      row["source"] == .string(source),
                      row["status"] != .string("archived"),
                      case .string(let id)? = row["id"] else { return nil }
                return id
            })
        } catch {
            nativeLog("[interaction-notification] inbox read failed: %@", error.localizedDescription)
            return
        }
        var changed = false
        for pair in pairs {
            let card = pair.interaction
            let id = "interaction:\(card.id)"
            do {
                guard card.state.isOpen || card.state.failureReason != nil else {
                    guard activeIDs.contains(id) else { continue }
                    changed = try await inbox.updateStatus(id: id, status: "archived",
                        readAt: ISO8601DateFormatter().string(from: Date())) || changed
                    continue
                }
                let title = NativeAppSecretRedactor.redactText(card.title)
                let body = NativeAppSecretRedactor.redactText(card.why)
                let choices: [JSONValue] = card.kind == .choose ? card.options.enumerated().map { index, option in
                    .object(["id": .string("interaction_choice_\(index)"), "label": .string(option.label)])
                } : []
                // Her resident wake's card files now; its push and banner wait
                // for the person's quiet hours to end (AttentionRouter.releaseHeld).
                let held = AttentionRouter.holdsResidentWake(session: sessionID, dataRoot: dataRoot)
                var row: [String: JSONValue] = [
                    "id": .string(id), "source": .string(source),
                    "created_at": .string(ISO8601DateFormatter().string(from: card.createdAt)),
                    "severity": .string("actionable"), "status": .string("unread"),
                    "title": .string(title), "summary": .string(body),
                    "interaction_session_id": .string(sessionID), "interaction_id": .string(card.id),
                    "actions": .array(choices + [
                        .object(["id": .string("act"), "label": .string("Open request")]),
                        .object(["id": .string("reject"), "label": .string("Not now")]),
                    ]),
                ]
                if held, notify { row["held_delivery"] = .array([.string("phone"), .string("mac")]) }
                let inserted = try await inbox.appendUnique(.object(row), id: id)
                changed = inserted || changed
                // User, 10-03: raised outside his conversation, it is mirrored
                // there once; the claim on this note makes every refresh a safe retry.
                if case .posted = await ApprovalChatCards.postInteraction(
                    card, sessionID: sessionID, dataRoot: dataRoot,
                    telegram: TelegramApprovalFilerRef.shared.current(), quiet: held || !notify) {
                    changed = true
                }
                guard inserted, notify, !held else { continue }
                do {
                    try await AttentionRouter.shared.route(
                        eventId: id, importance: .ownerWaiting, title: title, body: body,
                        userInfo: ["screen": "inbox", "source": source, "itemId": id], pinnedTo: .phone
                    )
                } catch {
                    nativeLog("[interaction-notification] push failed: %@", error.localizedDescription)
                }
                let posted = await NativeAgentNotifications.postAndReport(title: title, body: body,
                    userInfo: [NativeAgentNotificationActions.sessionKey: sessionID])
                if !posted.posted {
                    nativeLog("[interaction-notification] banner failed: %@", posted.error ?? posted.delivery)
                }
            } catch {
                nativeLog("[interaction-notification] delivery failed: %@", error.localizedDescription)
            }
        }
        guard changed else { return }
        // An open Activity view watches engine.inbox.items, not the file.
        do {
            let latest = try await NativeAgentEngine.live.inbox.list()
            if NativeAgentEngine.live.inbox.items != latest { NativeAgentEngine.live.inbox.items = latest }
        } catch {
            nativeLog("[interaction-notification] inbox refresh failed: %@", error.localizedDescription)
        }
        if notify { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }
    }

    /// The same signed inbox-action transport the phone already uses. Opening
    /// a Mac-owned permission/OAuth control never pretends to grant access.
    @MainActor
    static func act(id: String, action: String, dataRoot: URL, quiet: Bool = false) async throws {
        let pointer = try await pointer(id: id, dataRoot: dataRoot)
        if action.hasPrefix("interaction_choice_"),
           let index = Int(action.dropFirst("interaction_choice_".count)),
           let card = await InlineInteractionResolver.interaction(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot),
           card.kind == .choose, card.options.indices.contains(index) {
            // `quiet` is the agent's inbox.act; the phone's signed tap is User's.
            _ = try await InlineInteractionResolver.complete(id: card.id, sessionID: pointer.sessionID,
                selection: card.options[index].id, expectedRevision: card.revision, byAgent: quiet, dataRoot: dataRoot)
        } else if action == "reject" || action == "deny" {
            _ = try await InlineInteractionResolver.decline(id: pointer.interactionID,
                sessionID: pointer.sessionID, resume: !quiet, dataRoot: dataRoot)
        } else if action == "act" {
            guard let appModel = QuietSelfAdmin.shared.appModel else {
                throw NSError(domain: "InteractionCard", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Open NativeAgent on your Mac to finish this request."
                ])
            }
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == pointer.sessionID }),
                  await InlineInteractionResolver.interaction(id: pointer.interactionID,
                    sessionID: pointer.sessionID, dataRoot: dataRoot) != nil else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            await appModel.selectChatSession(session)
            guard appModel.activeChatSessionId == pointer.sessionID else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            _ = NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        } else {
            throw NSError(domain: "InteractionCard", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Use Open on Mac or Not now for this request."
            ])
        }
    }
}

/// Reuse the chat card and its existing controls without copying its state to
/// User's conversation or changing the session that a tap resumes.
struct InteractionInboxCard: View {
    /// The card's inbox note id, or the original card itself (a chat mirror).
    let noteID: String
    var pinned: InteractionCardDelivery.Pointer? = nil
    /// Above the chat only what still needs an answer shows; a receipt
    /// belongs in its conversation, never pinned over this one.
    var hidesAnswered = false
    private var observesOrigin = true
    init(item: InboxItemRecord) { noteID = item.id; hidesAnswered = true }
    init(mirrorOf pointer: InteractionCardDelivery.Pointer, hidesAnswered: Bool = false,
         binding: InlineInteractionChatBinding? = nil) {
        noteID = "interaction:\(pointer.interactionID)"
        pinned = pointer
        self.hidesAnswered = hidesAnswered
        observesOrigin = binding == nil
        if let binding { _binding = State(initialValue: binding) }
    }
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @State private var binding = InlineInteractionChatBinding()
    @State private var pointer: InteractionCardDelivery.Pointer?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading) {
            if let pointer, let card = binding.cardsByRow.values.flatMap({ $0 })
                .first(where: { $0.id == pointer.interactionID }),
               !hidesAnswered || card.needsAttention {
                InlineCardView(model: card) { action in
                    binding.handle(card: card, action: action, appModel: appModel)
                }
                .padding(.bottom, hidesAnswered ? 8 : 0)
            } else if !loaded {
                ProgressView()
            }
            // Loaded with no card: answered or gone, so nothing is left to show.
        }
        .sheet(item: Binding(get: { binding.connectorSheet }, set: { request in
            if request == nil { Task { await binding.connectorSheetClosed() } }
        })) { request in
            ConnectorWizardView(provider: request.provider, startsSignIn: true) {
                Task { await binding.connectorSheetClosed() }
            }
            .environment(appModel)
        }
        .sheet(isPresented: Binding(get: { binding.panelPage != nil }, set: { shown in
            if !shown { Task { await binding.panelClosed() } }
        })) {
            if let page = binding.panelPage {
                SimpleSetupPanel(showsClose: true, close: {
                    Task { await binding.panelClosed() }
                }) {
                    InlineCardSetupPresentation.page(page)
                }
                .frame(minWidth: 700, minHeight: 540)
                .environment(appModel)
            }
        }
        .task(id: noteID) {
            do {
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let origin: InteractionCardDelivery.Pointer
                if let pinned { origin = pinned } else {
                    origin = try await InteractionCardDelivery.pointer(id: noteID, dataRoot: root)
                }
                pointer = origin
                if observesOrigin { await binding.refresh(sessionID: origin.sessionID) }
            } catch {}
            loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { event in
            guard observesOrigin, let pointer, event.object as? String == pointer.sessionID else { return }
            Task { await binding.refresh(sessionID: pointer.sessionID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await binding.verifyOnReturn() } }
        }
        .onChange(of: chatPageIsVisible) { _, visible in
            if visible { Task { await binding.verifyOnReturn() } }
        }
    }
}
