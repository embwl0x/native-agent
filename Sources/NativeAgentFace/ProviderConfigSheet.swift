import SwiftUI
import NativeAgentShared
import Foundation
// Blueprint: | `ProviderConfigSheet.swift` | Protected provider drafts and committed account readbacks |

struct ProviderConfigSheet: View {
    let providerID: String
    let onDone: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View { ProtectedFaceEntry { entry } }

    @ViewBuilder
    private var entry: some View {
        if let provider = appModel.face.slot(.settings).select("providers.account.\(providerID)", as: SettingsFace.self, {
            $0?.providers.snapshot?.providers.first { $0.provider_id == providerID }
        }) {
            ProviderConfigEditor(provider: provider, onDone: onDone).id(provider.provider_id)
        } else {
            VStack(spacing: 12) {
                NativeEmptyState(title: "Account unavailable", detail: appModel.providerSettingsIssue
                    ?? "This account has not been read from Providers. Check again before editing it.")
                Button("Check again") { Task { await appModel.loadProvidersForChat() } }
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
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
    @State private var testingClaude = false
    @State private var claudeTestResult: String?
    private let key = "provider.connection"

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider; self.onDone = onDone
        _baseline = State(initialValue: provider)
    }

    private var modes: ProviderAuthModePicker {
        .init(advertisedModes: baseline.auth_modes, savedMode: baseline.auth_mode)
    }
    private var seedMode: String {
        modes.selectedMode
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
        return fields
    }
    private var modelRow: PartFace.Row {
        let routing = appModel.face.slot(.settings).select("providers.chatRouting", as: SettingsFace.self) { $0?.providers.snapshot?.routing }
        let current = currentModel(for: provider, in: routing)
        let options = provider.models.compactMap { row -> PartFace.Control.Option? in
            guard row.id == current || (ModelSlot.mayHold(row.id, row: row, savedInSlot: current)
                && chatChoice(for: row, providerID: provider.provider_id) != nil) else { return nil }
            return .init(id: row.id, label: row.offer_note.map { "\(row.name) (\($0))" } ?? row.name)
        }
        let detail: String?
        if !provider.auth_status.eligible {
            detail = "Connect this account before choosing a model for Chat."
        } else if options.isEmpty {
            detail = provider.offeredModels.isEmpty ? ModelSlot.refusal(note: provider.models_note, accountName: provider.display_name)
                : "This account has no models with a usable thinking default. Refresh its models in Providers."
        } else {
            detail = nil
        }
        return .init(id: "provider.chat_model", title: "Default model for Chat", detail: detail,
            control: detail == nil ? .choice(options, selected: current, call: .init("provider.chat_model")) : nil)
    }
    private func currentModel(for account: ProviderInfo, in routing: ProviderRoutingSnapshot?) -> String? {
        guard let routing, routing.activeProviders["chat"] == account.provider_id else { return nil }
        if let model = routing.preferences["chat"]?.model, !model.isEmpty { return model }
        return routing.pinnedModels["chat"]
    }
    private func chatChoice(for row: ProviderModelInfo, providerID: String) -> ProviderTurnChoice? {
        guard let efforts = row.supported_reasoning_efforts, let effort = row.default_reasoning_effort, !effort.isEmpty,
              efforts.isEmpty || efforts.contains(effort) else { return nil }
        return .init(provider: providerID, model: row.id, reasoningEffort: effort, fast: false)
    }
    private var entryIssue: String? {
        if modes.supportedModes.isEmpty { return "This account offers no sign-in method. Read it again before saving." }
        if baseline.connectionRevision == nil { return "Read this account's saved configuration before editing it." }
        return nil
    }
    private var form: PartFace.Block {
        .init(kind: "form", key: key, fields: fields, submit: [
            .init(id: "save", label: "Save", role: .primary, call: .init("provider.save"), unavailable: entryIssue),
            .init(id: "test", label: provider.provider_id == "anthropic" ? "Test API key" : "Test connection",
                  call: .init("provider.test"), unavailable: entryIssue),
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
                    VStack(alignment: .leading, spacing: 8) {
                        OAuthSignInButton(provider: .anthropic)
                        AnthropicSetupTokenInput()
                        if provider.provider_id == "anthropic" {
                            Button(testingClaude ? "Testing Claude sign-in…" : "Test Claude sign-in", action: testClaudeSignIn)
                                .disabled(testingClaude)
                            if let claudeTestResult { Text(claudeTestResult).textSelection(.enabled) }
                        }
                    }
                } else if let oauth = oauthProvider { OAuthSignInButton(provider: oauth) }
                FaceView(face: .init(sections: [.init(id: "provider.chat_model", rows: [modelRow])]),
                    door: ClosureFaceDoor(open: { _ in }, waitingOn: "the Chat model", perform: chooseModel), session: session)
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
    private func readAccount() async throws -> (account: ProviderInfo, snapshot: ProviderSettingsSnapshot, chatChoice: ProviderTurnChoice?) {
        let reply = try await appModel.protectedFormAct(.readProviderAccount(id: provider.provider_id))
        guard case .provider(let saved) = reply, let snapshot = saved.snapshot,
              let current = snapshot.providers.first(where: { $0.provider_id == provider.provider_id }) else {
            throw WireFailure(code: "provider_unavailable", message: "This account has not been read.", cause: nil, effects: .none)
        }
        return (current, snapshot, saved.chatChoice)
    }
    private func chooseModel(_ input: FaceActSubmission) async -> FaceActOutcome {
        guard let model = input.value, !model.isEmpty else {
            return .interrupted(WireFailure(code: "model_required", message: "Choose a model for Chat.", cause: nil, effects: .none))
        }
        let id = provider.provider_id
        var writeBaseline: ProviderRoutingSnapshot?
        do {
            let read = try await readAccount()
            let row = read.account.models.first { $0.id == model }
            let requested = row.flatMap { chatChoice(for: $0, providerID: id) }
            var routing = read.snapshot.routing
            if !input.checking {
                let current = currentModel(for: read.account, in: routing)
                guard ModelSlot.mayHold(model, row: row, savedInSlot: current) else {
                    throw WireFailure(code: "provider_model_unavailable",
                        message: ModelSlot.refusal(note: read.account.models_note, accountName: read.account.display_name),
                        cause: nil, effects: .none)
                }
                guard read.account.auth_status.eligible else {
                    throw WireFailure(code: "provider_not_connected", message: "Connect this account before choosing a model for Chat.",
                        cause: nil, effects: .none)
                }
                guard let requested else {
                    throw WireFailure(code: "provider_thinking_unavailable", message: "This model has no usable thinking default. Refresh its models in Providers.",
                        cause: nil, effects: .none)
                }
                try Task.checkCancellation()
                writeBaseline = routing
                let reply = try await appModel.chatAct(.saveChatChoice(.init(choice: requested, expectedBaseline: read.chatChoice,
                    expectedRevision: routing.revision)))
                guard case .provider(let readback) = reply, let snapshot = readback.snapshot else { throw unconfirmed() }
                routing = snapshot.routing
            }
            guard let requested, let saved = routing.preferences["chat"],
                  routing.activeProviders["chat"] == id, routing.pinnedModels["chat"] == model,
                  saved.reasoningEffort == requested.reasoningEffort, saved.serviceTier == "default" else {
                return .init(words: "Could not confirm this model and its settings as the saved Chat default.", effects: .unknown)
            }
            return .init(words: "Chat model saved.", effects: .known, accepted: true, committed: [.init(id: "value", value: .string(model))])
        } catch {
            let outcome = FaceActOutcome.interrupted(error)
            guard var failure = outcome.failure else { return outcome }
            if failure.code == "body_act_failed" { failure.message = failure.cause ?? failure.message }
            if let writeBaseline {
                if failure.code == "body_act_failed", let current = try? await readAccount(),
                   current.snapshot.routing == writeBaseline {
                    failure.effects = .none
                }
            } else if !input.checking {
                if error is CancellationError { failure.message = "Cancelled before saving the Chat model." }
                else if failure.code == "page_reply_unconfirmed" { failure.message = "Could not read the account before saving the Chat model." }
                failure.effects = .none
            }
            return .interrupted(failure)
        }
    }
    private func perform(_ input: FaceProtectedSubmission) async -> FaceActOutcome {
        let submission = input.submission
        do {
            if submission.action == "read" || (submission.checking && submission.action == "test") {
                let current = try await readAccount().account
                if submission.checking {
                    return .init(words: "Couldn't confirm the test result. Test again.", effects: .unknown)
                }
                baseline = current
                return .init(words: "Account read. Your edits are kept.", effects: .none, accepted: true)
            }
            if submission.action == "remove" {
                var outcome: FaceActOutcome
                if submission.checking {
                    outcome = try .reply(await appModel.protectedFormAct(.readCredential(.providerRemoval(provider.provider_id))))
                } else {
                    let reply = try await appModel.protectedFormAct(.disconnectProvider(id: provider.provider_id))
                    guard case .committed(let saved) = reply else { throw unconfirmed() }
                    outcome = .init(words: "Sign-in removed.", failure: saved.publicationFailure, effects: saved.effects,
                        accepted: true, committed: [.init(id: "key")])
                }
                guard outcome.accepted, !outcome.unresolved else { return outcome }
                baseline.connectionRevision = nil
                if outcome.failure == nil {
                    do { baseline = try await readAccount().account }
                    catch {
                        outcome.failure = WireFailure(code: "provider_readback_failed",
                            message: "Sign-in was removed, but the updated account could not be read. Read the account again before saving or testing.",
                            cause: error.localizedDescription, effects: .known)
                    }
                }
                return outcome
            }
            guard case .string(let mode)? = submission.values?["authMode"] else {
                throw WireFailure(code: "provider_mode_required", message: "Choose a sign-in method.", cause: nil, effects: .none)
            }
            let secret = mode == "api_key" ? input.secrets["key"] : nil
            if submission.checking {
                let request = ProviderConnectionWrite(id: provider.provider_id, secret: secret, authMode: mode, defaultModel: "", expectedRevision: nil)
                return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.provider(request))))
            }
            if submission.action == "test" {
                let words = try await testConnection(.init(id: provider.provider_id, authMode: mode,
                    secret: secret, displayedRevision: try revision()))
                return .init(words: words, effects: .none, accepted: true)
            }
            let reply = try await appModel.protectedFormAct(.saveProviderConnection(.init(id: provider.provider_id,
                secret: secret, authMode: mode, defaultModel: "", expectedRevision: try revision())))
            guard case .provider(let committed) = reply,
                  let saved = committed.snapshot?.providers.first(where: { $0.provider_id == provider.provider_id }) else { throw unconfirmed() }
            baseline = saved
            var fields: [FaceCommittedField] = [.init(id: "authMode", value: saved.auth_mode.map(PartFace.Value.string))]
            if mode == "api_key" { fields.append(.init(id: "key")) }
            return .init(words: "Saved to this Mac. Not tested.", effects: .known, accepted: true, committed: fields)
        } catch { return .interrupted(error) }
    }
    private func testClaudeSignIn() {
        guard !testingClaude else { return }
        testingClaude = true
        claudeTestResult = nil
        Task {
            defer { testingClaude = false }
            do {
                claudeTestResult = try await testConnection(.init(id: OAuthProvider.anthropic.id,
                    authMode: "oauth", secret: nil, displayedRevision: nil))
            } catch { claudeTestResult = error.localizedDescription }
        }
    }
    private func testConnection(_ request: ProviderTestRequest) async throws -> String {
        let reply = try await appModel.protectedFormAct(.testProvider(request))
        guard case .providerTest(let probe) = reply else {
            throw PartCallError(code: "provider_test_unconfirmed", message: "The provider did not return a connection test result.")
        }
        let result = probe.result
        let words: String
        if result.tested {
            let draft = request.secret.map { !String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
            if result.status != "ok" { words = "The connection test failed." }
            else if draft { words = "The typed key passed its test. It is not saved." }
            else if probe.credentialReady && probe.credentialMatches { words = "The saved credential passed its test." }
            else { words = "The check did not verify the current saved credential. Read the account before testing it again." }
        } else { words = "This sign-in method has no connection test. It remains unverified." }
        return [words, result.detail, result.error].compactMap { $0 }.joined(separator: " ")
    }
    private func unconfirmed() -> WireFailure {
        .init(code: "provider_reply_unconfirmed", message: "Not sure that saved. Check the account again.", cause: nil, effects: .unknown)
    }
}
