import SwiftUI
import NativeAgentShared
import Foundation
// Blueprint: | `ProviderConfigSheet.swift` | Protected provider drafts and committed account readbacks |

struct ProviderConfigSheet: View {
    let providerID: String
    var entryAuthMode: String? = nil
    let onDone: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View { ProtectedFaceEntry { entry } }

    @ViewBuilder
    private var entry: some View {
        // The protected window lives beyond a save; its baseline is the provider owner's current publication.
        if let provider = appModel.face.slot(.settings).select("providers.account.\(providerID)", as: SettingsFace.self, {
            $0?.providers.snapshot?.providers.first { $0.provider_id == providerID }
        }) {
            ProviderConfigEditor(provider: provider, entryAuthMode: entryAuthMode, onDone: onDone).id(provider.provider_id)
        } else {
            VStack(spacing: 12) {
                NativeEmptyState(title: "Account unavailable", detail: appModel.providerSettingsIssue
                    ?? "This account has not been read from Providers. Check again before editing it.")
                Button("Check again") { Task { await appModel.loadProvidersForChat() } }
                Button("Done", action: onDone)
            }
            .padding(20)
        }
    }
}

private struct ProviderConfigEditor: View {
    let provider: ProviderInfo
    let onDone: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var baseline: ProviderInfo
    @State private var session = FacePageSession()
    private let entryAuthMode: String?
    private let key = "provider.connection"

    init(provider: ProviderInfo, entryAuthMode: String?, onDone: @escaping () -> Void) {
        self.provider = provider; self.entryAuthMode = entryAuthMode; self.onDone = onDone
        _baseline = State(initialValue: provider)
    }

    private var modes: ProviderAuthModePicker {
        .init(advertisedModes: baseline.auth_modes, savedMode: baseline.auth_mode)
    }
    private var seedMode: String {
        if baseline.auth_mode == nil, let entryAuthMode, modes.supportedModes.contains(entryAuthMode) { return entryAuthMode }
        return modes.selectedMode
    }
    private var modeField: PartFace.FormField {
        .init(id: "authMode", label: "How to sign in", kind: "choice", value: .string(seedMode), required: true,
            options: modes.supportedModes.map { .init(id: $0, label: $0 == "api_key" ? "A key" : "A sign-in") })
    }
    private var displayedMode: String? {
        let block = PartFace.Block(kind: "form", key: key, fields: [modeField], submit: [])
        return session.formValues(block, section: "face:" + key)["authMode"]?.stringValue
    }
    private var fields: [PartFace.FormField] {
        var fields = [modeField]
        if displayedMode == "api_key" {
            fields.append(.init(id: "key", label: "Key", kind: "secret", placeholder: "Leave empty to keep the saved key"))
        }
        // The rows this slot may hold (`ModelSlot.mayHold`): offered ones, and the saved default itself with its note, so Save and Test keep it.
        let saved = baseline.default_model
        let holdable = baseline.models.filter { row in
            (row.supported_reasoning_efforts != nil || row.id == saved) && ModelSlot.mayHold(row.id, row: row, savedInSlot: saved)
        }
        fields.append(.init(id: "model", label: "Default model", kind: "choice", value: saved.map(PartFace.Value.string),
            options: holdable.map { row in .init(id: row.id, label: row.offer_note.map { note in "\(row.name) (\(note))" } ?? row.name) }))
        return fields
    }
    private var entryIssue: String? {
        if modes.supportedModes.isEmpty { return "This account offers no sign-in method. Read it again before saving." }
        if baseline.connectionRevision == nil { return "Read this account's saved configuration before editing it." }
        return nil
    }
    private var form: PartFace.Block {
        .init(kind: "form", key: key, fields: fields, submit: [
            .init(id: "save", label: "Save", role: .primary, call: .init("provider.save"), unavailable: entryIssue),
            .init(id: "test", label: "Test connection", call: .init("provider.test"), unavailable: entryIssue),
            .init(id: "remove", label: "Remove sign-in", role: .destructive, call: .init("provider.remove")),
            .init(id: "read", label: "Read account again", call: .init("provider.read"))
        ], protected: true, receiver: FaceSecretReceiver.saveProviderConnection.name, doors: ["mac"])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider.display_name).font(ShellType.title)
            ScrollView {
                FaceProtectedForm(face: PartFace(sections: [
                    .init(id: "provider.status", rows: [.init(id: "provider.status", title: "Saved sign-in", detail: provider.auth_status.detail)]),
                    .init(id: key, footer: "Save keeps the key on this Mac. Only Test checks it with the provider.", rows: [], block: form)
                ]), receiver: .saveProviderConnection, session: session, validationFree: ["read", "remove"], close: onDone, perform: perform)
                if ["anthropic", "anthropic_oauth_direct"].contains(provider.provider_id) {
                    AnthropicOAuthDirectPanel(showConnectionTest: true)
                } else if let oauth = oauthProvider { OAuthSignInButton(provider: oauth) }
            }
        }
        .padding(20).frame(minWidth: 480, minHeight: 420)
        .id(provider.provider_id)
    }
    private var oauthProvider: OAuthProvider? {
        switch provider.provider_id {
        case "openai_oauth_direct", "codex": .chatgpt
        case "xai_oauth_direct": .xai
        default: nil
        }
    }
    private func revision() throws -> String {
        guard let revision = baseline.connectionRevision else {
            throw WireFailure(code: "provider_baseline_unavailable", message: "Read the account again before saving or testing it.",
                cause: nil, effects: .none)
        }
        return revision
    }
    private func perform(_ input: FaceProtectedSubmission) async -> FaceActOutcome {
        let submission = input.submission
        do {
            if submission.action == "read" || (submission.checking && submission.action == "test") {
                let reply = try await appModel.protectedFormAct(.readProviderAccount(id: provider.provider_id))
                if case .provider(let saved) = reply,
                   let current = saved.snapshot?.providers.first(where: { $0.provider_id == provider.provider_id }) {
                    if submission.checking {
                        return .init(words: "The account was read. Its saved credential does not confirm this test's verification write.", effects: .unknown)
                    }
                    baseline = current
                    return .init(words: "Account read. Your edits are kept.", effects: .none, accepted: true)
                }
                throw WireFailure(code: "provider_unavailable", message: "This account has not been read.", cause: nil, effects: .none)
            }
            if submission.checking, submission.action == "remove" {
                return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.providerRemoval(provider.provider_id))))
            }
            if submission.action == "remove" {
                let reply = try await appModel.protectedFormAct(.disconnectProvider(id: provider.provider_id))
                guard case .committed(let saved) = reply else { throw unconfirmed() }
                if let issue = saved.publicationFailure { throw issue }
                return .init(words: "Sign-in removed.", effects: .known, accepted: true,
                    committed: [.init(id: "key")])
            }
            guard case .string(let mode)? = submission.values?["authMode"] else {
                throw WireFailure(code: "provider_mode_required", message: "Choose a sign-in method.", cause: nil, effects: .none)
            }
            let model: String
            if case .string(let value)? = submission.values?["model"] { model = value } else { model = "" }
            let secret = mode == "api_key" ? input.secrets["key"] : nil
            if submission.checking {
                let request = ProviderConnectionWrite(id: provider.provider_id, secret: secret, authMode: mode, defaultModel: model, expectedRevision: nil)
                return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.provider(request))))
            }
            if submission.action == "test" {
                let reply = try await appModel.protectedFormAct(.testProvider(.init(id: provider.provider_id,
                    authMode: mode, secret: secret, displayedRevision: try revision())))
                guard case .providerTest(let probe) = reply else { throw unconfirmed() }
                let result = probe.result
                let words: String
                if result.tested {
                    let draft = secret.map { !String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
                    if result.status != "ok" { words = "The connection test failed." }
                    else if draft { words = "The typed key passed its test. It is not saved." }
                    else if probe.credentialReady && probe.credentialMatches { words = "The saved credential passed its test." }
                    else { words = "The check did not verify the current saved credential. Read the account before testing it again." }
                } else { words = "This sign-in method has no connection test. It remains unverified." }
                return .init(words: [words, result.detail, result.error].compactMap { $0 }.joined(separator: " "),
                    effects: .none, accepted: true)
            }
            let reply = try await appModel.protectedFormAct(.saveProviderConnection(.init(id: provider.provider_id,
                secret: secret, authMode: mode, defaultModel: model, expectedRevision: try revision())))
            guard case .provider(let committed) = reply,
                  let saved = committed.snapshot?.providers.first(where: { $0.provider_id == provider.provider_id }) else { throw unconfirmed() }
            baseline = saved
            var fields: [FaceCommittedField] = [.init(id: "authMode", value: saved.auth_mode.map(PartFace.Value.string)),
                .init(id: "model", value: saved.default_model.map(PartFace.Value.string))]
            if mode == "api_key" { fields.append(.init(id: "key")) }
            return .init(words: "Saved to this Mac. Not tested.", effects: .known, accepted: true, committed: fields)
        } catch { return .interrupted(error) }
    }
    private func unconfirmed() -> WireFailure {
        .init(code: "provider_reply_unconfirmed", message: "The account owner did not confirm this operation.", cause: nil, effects: .unknown)
    }
}
