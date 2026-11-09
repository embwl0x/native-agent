import Foundation
import NativeAgentShared
import ApprovalTransactions
import Privacy
// Blueprint: | `ProviderFaceProjection.swift` | Ordered off-main provider settings and conversation control projection |

enum ProviderFaceChange: Sendable {
    case snapshot(ProviderSettingsSnapshot)
    case failure(String)
    case session(String, ProviderSessionPresentation)
    case retireSessions
    case status(probes: [String: Date], catalogStarted: Date?, codexAuth: CodexAuthStatus?, saving: Bool)
    case delivery(FaceDeliveryReceipt)
}

actor ProviderFaceProjection {
    private let feed: SettingsFeedProjection
    private let dataRoot: URL
    private var value = ProviderSettingsFace()

    init(feed: SettingsFeedProjection, dataRoot: URL) {
        self.feed = feed
        self.dataRoot = dataRoot
    }

    func consume(_ changes: AsyncStream<ProviderFaceChange>) async {
        for await change in changes {
            let previous = value
            var accountsChanged = false
            switch change {
            case .snapshot(let reading):
                let snapshot = reading.disclosedForFace()
                accountsChanged = value.snapshot?.providers != snapshot.providers
                value.apply(snapshot: snapshot)
            case .failure(let detail):
                let disclosed = NativeAppSecretRedactor.redactText(detail)
                value.error = disclosed
                value.readiness = .unavailable(disclosed)
            case .session(let id, let session):
                value.sessions[id] = session.prepared(settings: value.snapshot)
            case .retireSessions:
                value.sessions = [:]
            case .status(let probes, let catalogStarted, let codexAuth, let saving):
                value.providerProbeStarts = probes
                value.catalogRefreshStarted = catalogStarted
                value.codexAuth = codexAuth
                value.isSavingChatBrain = saving
            case .delivery(let receipt):
                await receipt.complete()
            }
            if previous != value { feed.updateProviders(value) }
            if accountsChanged { await InlineInteractionResolver.settleProviderRequests(dataRoot: dataRoot) }
        }
    }
}

extension ProviderSettingsFace {
    mutating func apply(snapshot: ProviderSettingsSnapshot) {
        self.snapshot = snapshot
        self.error = nil
        self.sessions = sessions.mapValues { $0.prepared(settings: snapshot) }
        let ready = snapshot.providers.filter { $0.auth_status.eligible }
        self.readiness = ready.isEmpty ? .needsConnection : .ready
        self.chatChoice = snapshot.selection(for: "chat")
        self.chatModelReady = chatChoice.map {
            ProvidersFacade.chatModelIsReady(providers: snapshot.providers, providerID: $0.provider, model: $0.model)
        } == true
        self.connectedProviderLabel = (ready.first { $0.provider_id == chatChoice?.provider } ?? ready.first)?.display_name
        self.apiKeyAccountIDs = snapshot.providers.map(\.provider_id).filter {
            !["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains($0)
        }
    }
}

extension ProviderSessionPresentation {
    func prepared(settings: ProviderSettingsSnapshot?) -> Self {
        let groups = ChatComposerModelGroup.groups(connections: settings?.providers ?? [], catalog: settings?.catalog,
                                                   providerID: choice?.provider ?? "")
        let models = Dictionary(groups.map { group in
            (group.id, Dictionary(group.models.map { model in
                (model.id, ProviderModelPresentation(model: model,
                    efforts: ProvidersFacade.reasoningOptions(from: settings?.catalog, selectedModel: model)))
            }, uniquingKeysWith: { first, _ in first }))
        }, uniquingKeysWith: { first, _ in first })
        return Self(controls: .init(contract: contract, choice: choice, providerGroups: groups, models: models),
                    context: context, error: error.map(NativeAppSecretRedactor.redactText))
    }
}

extension ProviderSettingsSnapshot {
    func disclosedForFace() -> Self {
        Self(routing: routing, providers: providers, catalog: catalog,
             catalogError: catalogError.map(NativeAppSecretRedactor.redactText), rowSet: rowSet,
             unavailableModels: unavailableModels, oauthStatuses: oauthStatuses, codexCLISessionOffer: codexCLISessionOffer)
    }
}
