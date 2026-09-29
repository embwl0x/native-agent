import Foundation
import SwiftUI
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import NotificationInbox
import AttentionRouting
import Privacy

/// Inbox rows are pointers. The originating transcript still owns the card,
/// its revision, verification and continuation, on every surface.
enum InteractionCardDelivery {
    static let source = "interaction"

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
        let sessions = await Task.detached(priority: .utility) {
            let directory = root.appendingPathComponent("chat/messages", isDirectory: true)
            do {
                return try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
                    .map { $0.deletingPathExtension().lastPathComponent }
            } catch {
                NSLog("[interaction-notification] recovery read failed: %@", error.localizedDescription)
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
        guard case .success(let pairs) = result else { return }
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
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
            NSLog("[interaction-notification] inbox read failed: %@", error.localizedDescription)
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
                let inserted = try await inbox.appendUnique(.object([
                    "id": .string(id), "source": .string(source),
                    "created_at": .string(ISO8601DateFormatter().string(from: card.createdAt)),
                    "severity": .string("actionable"), "status": .string("unread"),
                    "title": .string(title), "summary": .string(body),
                    "interaction_session_id": .string(sessionID), "interaction_id": .string(card.id),
                    "actions": .array(choices + [
                        .object(["id": .string("act"), "label": .string("Open on Mac")]),
                        .object(["id": .string("reject"), "label": .string("Not now")]),
                    ]),
                ]), id: id)
                changed = inserted || changed
                guard inserted, notify else { continue }
                do {
                    try await AttentionRouter.shared.route(
                        eventId: id, importance: .ownerWaiting, title: title, body: body,
                        userInfo: ["screen": "inbox", "source": source, "itemId": id], pinnedTo: .phone
                    )
                } catch {
                    NSLog("[interaction-notification] push failed: %@", error.localizedDescription)
                }
                let posted = await NativeAgentNotifications.postAndReport(title: title, body: body,
                    userInfo: [NativeAgentNotificationActions.sessionKey: sessionID])
                if !posted.posted {
                    NSLog("[interaction-notification] banner failed: %@", posted.error ?? posted.delivery)
                }
            } catch {
                NSLog("[interaction-notification] delivery failed: %@", error.localizedDescription)
            }
        }
        guard changed else { return }
        // An open Activity view watches engine.inbox.items, not the file.
        do {
            let latest = try await NativeAgentEngine.live.inbox.list()
            if NativeAgentEngine.live.inbox.items != latest { NativeAgentEngine.live.inbox.items = latest }
        } catch {
            NSLog("[interaction-notification] inbox refresh failed: %@", error.localizedDescription)
        }
        if notify { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }
    }

    /// The same signed inbox-action transport the phone already uses. Opening
    /// a Mac-owned permission/OAuth control never pretends to grant access.
    @MainActor
    static func act(id: String, action: String, dataRoot: URL) async throws {
        let pointer = try await pointer(id: id, dataRoot: dataRoot)
        if action.hasPrefix("interaction_choice_"),
           let index = Int(action.dropFirst("interaction_choice_".count)),
           let card = await InlineInteractionResolver.interaction(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot),
           card.kind == .choose, card.options.indices.contains(index) {
            _ = try await InlineInteractionResolver.complete(id: card.id, sessionID: pointer.sessionID,
                selection: card.options[index].id, expectedRevision: card.revision, dataRoot: dataRoot)
        } else if action == "reject" || action == "deny" {
            _ = try await InlineInteractionResolver.decline(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot)
        } else if action == "act" {
            guard QuietSelfAdmin.shared.appModel != nil else {
                throw NSError(domain: "InteractionCard", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Open NativeAgent on your Mac to finish this request."
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
    let item: InboxItemRecord
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @State private var binding = InlineInteractionChatBinding()
    @State private var pointer: InteractionCardDelivery.Pointer?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading) {
            if let pointer, let card = binding.cardsByRow.values.flatMap({ $0 })
                .first(where: { $0.id == pointer.interactionID }) {
                InlineCardView(model: card) { action in
                    binding.handle(card: card, action: action, appModel: appModel)
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.orange)
            } else if pointer != nil {
                Text("This request is unavailable. Refresh Activity and try again.").foregroundStyle(.orange)
            } else {
                ProgressView()
            }
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
        .task(id: item.id) {
            do {
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let origin = try await InteractionCardDelivery.pointer(id: item.id, dataRoot: root)
                pointer = origin
                await binding.refresh(sessionID: origin.sessionID)
            } catch { loadError = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { event in
            guard let pointer, event.object as? String == pointer.sessionID else { return }
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
