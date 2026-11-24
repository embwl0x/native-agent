import AppKit
import MacNerves
import BodyRuntime
import MindCore
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SwiftUI
import DeskCore
import UniformTypeIdentifiers
// Blueprint: | `AppTrustFaceActions.swift` | Mac hosts for Trust, Settings, contact and capability face actions |

extension AppQuietToolHost {
    /// Run Trust and Settings Mac verbs after the door judges authority; nil names another owner's verb.
    func runTrustSettingsUpkeep(verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue])? {
        if let face, let result = await face.upkeep(verb: verb) { return result }
        if let settings = AppQuietSettingsHost.settingsMacVerb(verb) { return settings }
        do {
            switch verb {
            case "trust_refresh_privacy":
                await appModel.engine.macIntegration.refresh(refreshWatches: false)
                await appModel.engine.trust.refreshPrivacyMap()
                return (true, "Read macOS grants and the privacy inventory again; Trust shows them now.", [:])
            case "trust_authorize_safe":
                appModel.engine.trust.publishPolicy(try await SwiftNativeTrustCenter(dataRoot: appModel.engine.dataRoot).reauthorizeSafePolicy())
                return (true, "The damaged policy was preserved beside trust/policy.json. Safe is now authorized.", [:])
            case "trust_check_mail":
                await appModel.engine.macIntegration.checkMail()
                return (true, "Mail check finished; its current result is on Trust.", [:])
            case "trust_test_notification":
                guard try await appModel.macControlNotify(title: "NativeAgent", message: "Mac Control test") else {
                    return (false, "The notification was not confirmed sent.", [:])
                }
                return (true, "Sent.", [:])
            case "trust_workbench":
                let policy = try await appModel.engine.trust.load()
                guard policy.macControlPolicy != nil else { return (false, "Mac control policy is unavailable.", [:]) }
                try await BodyFacePresentation.current(model: appModel).present(.showMacControlWorkbench)
                return (true, "The Mac control workbench is open. Nothing has run.", [:])
            case "trust_exclude_app":
                return try await excludeApp()
            default:
                return nil
            }
        } catch { return (false, error.localizedDescription, ["effects": .string("unknown")]) }
    }

    /// The grants `trust.ask_grant` names: a list of grant names the permission card takes. Its run and the gate's check before any card
    /// read it alike, so a call naming anything else is refused at once, with every target the card takes, and nothing is asked.
    static func grantTargets(_ input: [String: JSONValue]) -> Result<[String], QuietArgumentRefusal> {
        let accepted = SystemPermissionCapability.allCases.filter { $0 != .automation }.map { "privacy:" + $0.rawValue }
            .joined(separator: ", ") + ", or applescript:<bundle id> for one app's Automation"
        func refused(_ words: String) -> Result<[String], QuietArgumentRefusal> {
            .failure(QuietArgumentRefusal(AppToolExecutor.failure("bad_grant", words + " Nothing was asked. targets takes \(accepted).",
                extra: ["effects": .string("none"), "argument_path": .string("args.targets"), "accepted": .string(accepted)])))
        }
        guard case .array(let listed)? = input["targets"] else { return refused("Name the grants to ask for in targets.") }
        let targets = listed.compactMap(\.stringValue)
        guard !targets.isEmpty, targets.count == listed.count else { return refused("targets is a list of grant names.") }
        if let unknown = targets.first(where: { SystemPermissionPreflight.cardSettingsCapability($0) == nil }) {
            return refused("Unknown macOS grant \(unknown).")
        }
        return .success(targets)
    }

    /// The grant `trust.grant_settings` opens System Settings at, read alike by its run and the gate's check before any card.
    static func grantSettingsTarget(_ input: [String: JSONValue]) -> Result<SystemPermissionCapability, QuietArgumentRefusal> {
        let target = input["target"]?.stringValue ?? ""
        guard let gate = SystemPermissionPreflight.cardSettingsCapability(target) else {
            return .failure(QuietArgumentRefusal(AppToolExecutor.failure("bad_grant",
                "\(target.isEmpty ? "No target was named" : target + " names no macOS grant"); nothing was opened. target takes a grant name like "
                    + "privacy:calendars, or applescript:<bundle id> for one app's Automation.",
                extra: ["effects": .string("none"), "argument_path": .string("args.target")])))
        }
        return .success(gate)
    }

    /// Trust's ask, and the agent's ask on the person's word, walk the grants on the permission card: an open card already holding them goes
    /// on (Continue), else one card is filed in the open conversation and answered as the person's Allow. The card carries the walk, so
    /// coming back to the window goes on and the card says what is on now.
    func askGrants(_ targets: [String]) async throws -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let dataRoot = appModel.engine.dataRoot
        var card: (id: String, sessionID: String)?
        for open in try await appModel.engine.interactions.platform.openInteractionCards() {
            guard let found = try await appModel.engine.interactions.interaction(id: open.id, sessionID: open.sessionID),
                  found.kind == .permission, found.state.isOpen, Set(targets).isSubset(of: found.allTargets) else { continue }
            card = open
            break
        }
        if card == nil {
            let session = appModel.activeChatSessionId
            guard !session.isEmpty, let ask = InlineInteractionRegistry.permission(targets,
                    why: "You asked for these macOS grants; macOS asks you for each one.") else {
                return (false, "No conversation is open to hold the permission card; nothing was asked.", ["effects": .string("none")])
            }
            let turn = Turn(dataRoot: dataRoot, session: session).with(\.envelope, .native("trust:ask-grant")).with(\.verifiedSessionID, session)
            guard let raised = await appModel.engine.interactions.raise(ask, sessionID: session, resumable: false,
                origin: .native("trust:ask-grant"), turn: turn) else {
                return (false, "The permission card could not be filed; nothing was asked.", ["effects": .string("none")])
            }
            card = (raised.id, session)
        }
        guard let card else { return (false, "No permission card holds these grants; nothing was asked.", ["effects": .string("none")]) }
        try await runCardControl(id: card.id, sessionID: card.sessionID, choice: nil)
        await appModel.engine.macIntegration.refresh()
        guard let after = try await appModel.engine.interactions.interaction(id: card.id, sessionID: card.sessionID) else {
            return (false, "The permission card is absent from readback; check it before asking again.", ["effects": .string("unknown")])
        }
        let descriptor = await InlineInteractionCoordinator.descriptor(for: after, dataRoot: dataRoot)
        let words = [await appModel.engine.interactions.grantsNow(after, control: descriptor),
                     InlineCards.model(after, descriptor: descriptor).busyNote, after.state.failureReason, after.state.outcome?.summary]
            .compactMap { $0 }.joined(separator: " ")
        return (after.state.failureReason == nil, words.isEmpty ? "The permission card is \(after.state.name)." : words,
            ["interaction_id": .string(card.id), "state": .string(after.state.name)])
    }

    /// The person chooses the app and confirms the deletion of its recorded history.
    private func excludeApp() async throws -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to exclude"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard try await FaceNativePanel.choose(panel) == .OK else {
            return (true, "No app was selected; nothing changed.", ["changed": .bool(false)])
        }
        guard let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
            return (false, "The chosen app has no readable bundle identity; nothing changed.", [:])
        }
        let alert = NSAlert()
        alert.messageText = "Exclude this app and delete what was recorded?"
        alert.informativeText = "Everything already recorded for \(id) is deleted for good, including the recovery log. Future recording skips it entirely."
        alert.addButton(withTitle: "Exclude and delete")
        alert.addButton(withTitle: "Cancel")
        guard try await FaceNativePanel.confirm(alert, activate: true) == .alertFirstButtonReturn else {
            return (true, "Exclusion cancelled; nothing changed.", ["changed": .bool(false)])
        }
        let controller = appModel.engine.activityWatch
        await controller.addExclusion(bundleID: id)
        guard try await controller.checkedPolicy().excludedBundleIDs.contains(id), let rows = controller.lastPurgedRowCount else {
            return (false, controller.lastError ?? "Exclusion and deletion could not both be confirmed.", ["effects": .string("unknown")])
        }
        return (true, "Excluded \(id); deleted \(rows) recorded spans.", ["changed": .bool(true)])
    }
}

extension AppQuietToolHost: AgentContactsFaceHost {
    /// Start a contact's prompt in a new conversation; a refused send retains its cause.
    func askInNewChat(_ words: String) async throws -> String {
        if let face {
            guard case .accepted(let session, _, _) = try await face.act(.createConversation) else {
                throw PartCallError(code: "chat_unavailable", message: "A new chat was not created. Nothing was asked.")
            }
            try await face.present(.openConversation(session: session, message: nil))
            let reply = try await face.act(.send(.init(session: session, text: words, attachments: [], composerRevision: 0,
                expectedSelection: nil, options: .init(hideUserBubble: false, choice: nil, continuationReference: nil))))
            switch reply {
            case .accepted: return "Asked in a new chat: " + words
            case .failed(let failure), .refused(let failure): throw failure
            default: throw FaceWireError.invalidFeedOrder
            }
        }
        ApplicationLifetime.shared.request(.sidebar(.chat))
        let previous = appModel.activeChatSessionId
        await appModel.newChatSession()
        let session = appModel.activeChatSessionId
        guard !session.isEmpty, session != previous else {
            throw PartCallError(code: "chat_unavailable", message: "A new chat could not be opened; nothing was asked.")
        }
        switch await appModel.startActiveChatTurn(words, expectedSessionId: session) {
        case .accepted: return "Asked in a new chat: " + words
        case .rejected(let message): throw PartCallError(code: "chat_refused", message: message)
        }
    }
}

extension AppQuietToolHost: CapabilitiesFaceHost {
    func chooseSenseDestination(name: String) async throws -> URL? {
        if let face {
            let reply = try await face.call(.chooseSenseDestination(operation: UUID(), suggestedName: name))
            switch reply {
            case .destination(let grant):
                guard let grant else { return nil }
                return try await Task.detached { try BodyFaceResources.resolve(grant) }.value
            case .cancelled: return nil
            case .failed(let failure), .refused(let failure): throw failure
            default: throw FaceWireError.invalidFeedOrder
            }
        }
        let panel = NSSavePanel()
        panel.title = "Share sense"
        panel.nameFieldStringValue = name
        return try await FaceNativePanel.choose(panel) == .OK ? panel.url : nil
    }

    func buildSkillInChat() async throws -> String {
        if let face {
            try BodyInboxCardActionEffects.requireDraft(try await face.call(.prepareChatDraft(text: "Build me a skill that ")))
            return "Chat is open with the request started in the message box; finish it and send."
        }
        return switch appModel.requestSkillBuild(starter: "Build me a skill that ") {
        case .draftPrepared: "Chat is open with the request started in the message box; finish it and send."
        case .existingDraftPreserved: "Chat is open; the unsent words already in the message box were kept, so add the request to them."
        case .awaitingChatSession: "Opening a new chat for the request."
        }
    }
}
