import AppKit
import ActivityWatch
import AppToolRuntime
import ChatToolParsing
import ChatTurnContracts
import ChatTurnRuntime
import EngineRuntime
import MacIntegration
import NativeAgentShared
import PersistenceCore
import SwiftUI
import TrustCenter
import TrustPersistence
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
            case "trust_ask_grant":
                guard case .array(let listed)? = input["targets"] else { return (false, "Name the grants to ask for in targets; nothing was asked.", [:]) }
                let targets = listed.compactMap(\.stringValue)
                guard !targets.isEmpty, targets.count == listed.count else {
                    return (false, "targets is a list of grant names like privacy:calendars; nothing was asked.", [:])
                }
                return try await askGrants(targets)
            case "trust_grant_settings":
                guard let target = input["target"]?.stringValue, let gate = SystemPermissionPreflight.cardSettingsCapability(target) else {
                    return (false, "This names no macOS grant; nothing was opened.", [:])
                }
                if let failure = await SystemPermissionPreflight.openSettings(gate) { return (false, failure, [:]) }
                return (true, "System Settings is open at \(gate.displayName). Opening it granted nothing.", [:])
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

    /// Asks macOS in the foreground through the permission card's own request, then reads the grants again.
    private func askGrants(_ targets: [String]) async throws -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        if let unknown = targets.first(where: { SystemPermissionPreflight.cardSettingsCapability($0) == nil }) {
            return (false, "Unknown macOS grant \(unknown); nothing was asked.", ["execution": .string("not_run"), "effects": .string("none")])
        }
        let problems = try await SystemPermissionPreflight.requestMacOSAccess(targets)
        await appModel.engine.macIntegration.refresh()
        return (problems.isEmpty, problems.isEmpty
            ? "Trust shows each grant as macOS reads it now."
            : problems.joined(separator: " "), [:])
    }

    /// The person chooses the app and confirms the deletion of its recorded history.
    private func excludeApp() async throws -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to exclude"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return (true, "No app was selected; nothing changed.", ["changed": .bool(false)]) }
        guard let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
            return (false, "The chosen app has no readable bundle identity; nothing changed.", [:])
        }
        let alert = NSAlert()
        alert.messageText = "Exclude this app and delete what was recorded?"
        alert.informativeText = "Everything already recorded for \(id) is deleted for good, including the recovery log. Future recording skips it entirely."
        alert.addButton(withTitle: "Exclude and delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return (true, "Exclusion cancelled; nothing changed.", ["changed": .bool(false)]) }
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
        return panel.runModal() == .OK ? panel.url : nil
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

/// Typed outcomes keep a missing session or preserved draft from being called a successful build.
enum SkillBuildRequestPresentation {
    enum DraftOutcome: Equatable {
        case draftPrepared
        case existingDraftPreserved
        case awaitingChatSession
    }

    static func build(activeSessionID: String, existingDraft: String) -> DraftOutcome {
        guard !activeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .awaitingChatSession
        }
        return existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .draftPrepared
            : .existingDraftPreserved
    }
}

extension Notification.Name {
    static let skillBuildRequest = Notification.Name("NativeAgent.skillBuildRequest")
}
