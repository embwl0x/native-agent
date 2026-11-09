import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `ConnectorWizardView.swift` | Protected shared Slack setup retains public edits and sends token bytes only to its native owner |

struct ConnectorWizardView: View {
    let provider: String
    let onDismiss: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    @State private var readIssue: String?
    @State private var portalOutcome: String?
    private let key = "connector.slack.setup"
    private var policy: ConnectorSettingsFace.Slack? {
        appModel.face.slot(.settings).select("connectors.slack", as: SettingsFace.self) { $0?.connectors.slack }
    }
    private var policyIssue: String? {
        appModel.face.slot(.settings).select("connectors.slackIssue", as: SettingsFace.self) { $0?.connectors.slackIssue }
    }
    private var face: PartFace {
        PartFace(title: "Connect Slack", sections: [
            .init(id: "slack.apps", rows: [.init(id: "slack.apps", title: "Open Slack apps", open: "url:https://api.slack.com/apps")]),
            .init(id: key, footer: "Use tokens from api.slack.com/apps. Enable Socket Mode and connections:write for the app token. "
                + "Allow at least one channel or user. Direct messages do not need an @mention.", rows: [],
                block: .init(kind: "form", key: key, fields: [
                    .init(id: "token", label: "Bot token", kind: "secret", placeholder: "xoxb-… · empty keeps the saved token"),
                    .init(id: "app_token", label: "App token", kind: "secret", placeholder: "xapp-…"),
                    .init(id: "allowed_channels", label: "Allowed channel IDs",
                        value: policy.map { .string($0.allowedChannelIds.sorted().joined(separator: ", ")) }),
                    .init(id: "allowed_users", label: "Allowed user IDs", value: policy.map { .string($0.allowedUserIds.sorted().joined(separator: ", ")) }),
                    .init(id: "require_mention", label: "Only answer channel messages when @mentioned", kind: "switch",
                        value: policy.map { .bool($0.requireMention) })
                ], submit: [.init(id: "save", label: "Save", role: .primary, call: .init("connector.slack.save"),
                    unavailable: policy == nil ? "Read Slack's saved policy before saving." : policyIssue)],
                    protected: true, receiver: FaceSecretReceiver.saveConnectorCredentials.name, doors: ["mac"]))
        ])
    }
    var body: some View {
        ProtectedFaceEntry {
            VStack(alignment: .leading, spacing: 12) {
                if ConnectorWizardSetupRoute.resolve(provider: provider) == .manualToken {
                    ScrollView { FaceProtectedForm(face: face, receiver: .saveConnectorCredentials, session: session, open: openSlack, perform: save) }
                } else { Text("This connector uses its own setup page.") }
                if let portalOutcome { Text(portalOutcome).foregroundStyle(.secondary) }
                if let readIssue { Text(readIssue).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Read setup again") { Task { await refresh() } }
                    Spacer()
                    Button("Close", action: onDismiss)
                }
            }.padding(20).frame(minWidth: 480, minHeight: 440)
                .task { await refresh() }
        }
    }
    private func openSlack(_ link: String) {
        guard case .url(let url)? = FaceLink(link) else { portalOutcome = "The Slack apps address could not be opened."; return }
        portalOutcome = NSWorkspace.shared.open(url) ? "Asked your browser to open Slack apps."
            : "Couldn't open your browser. Open api.slack.com/apps to continue."
    }
    private func refresh() async {
        do {
            _ = try await appModel.protectedFormAct(.refresh(.panel(SidebarItem.connectors.rawValue)))
            readIssue = nil
        } catch { readIssue = TurnSecretRedactor.redactText(error.localizedDescription) }
    }
    private func save(_ input: FaceProtectedSubmission) async -> FaceActOutcome {
        do {
            guard policy != nil, policyIssue == nil else {
                throw WireFailure(code: "slack_policy_unavailable", message: "Read Slack's saved policy before saving.",
                    cause: policyIssue, effects: input.submission.checking ? .unknown : .none)
            }
            guard case .string(let channels)? = input.submission.values?["allowed_channels"],
                  case .string(let users)? = input.submission.values?["allowed_users"],
                  case .bool(let mention)? = input.submission.values?["require_mention"] else {
                throw WireFailure(code: "slack_fields_missing", message: "Read the Slack access fields before saving.", cause: nil, effects: .none)
            }
            guard !SlackAllowlist.parseIDs(channels).isEmpty || !SlackAllowlist.parseIDs(users).isEmpty else {
                throw WireFailure(code: "slack_allowlist_required", message: "Add an allowed channel or user.", cause: nil,
                    effects: .none, fields: ["allowed_channels": "Add at least one channel or user."])
            }
            let request = ConnectorCredentialWrite(operation: input.submission.id,
                id: "slack", fields: ["token": input.secrets["token"] ?? Data(), "app_token": input.secrets["app_token"] ?? Data(),
                    "allowed_channels": Data(channels.utf8), "allowed_users": Data(users.utf8), "require_mention": Data(String(mention).utf8)])
            if input.submission.checking {
                return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.slack(request))))
            }
            let reply = try await appModel.protectedFormAct(.saveConnectorCredentials(request))
            return try .protectedCommit(reply, words: "Slack setup saved.", fields: [
                .init(id: "token"), .init(id: "app_token"),
                .init(id: "allowed_channels", value: .string(SlackAllowlist.parseIDs(channels).sorted().joined(separator: ", "))),
                .init(id: "allowed_users", value: .string(SlackAllowlist.parseIDs(users).sorted().joined(separator: ", "))),
                .init(id: "require_mention", value: .bool(mention))])
        } catch { return .interrupted(error) }
    }
}
