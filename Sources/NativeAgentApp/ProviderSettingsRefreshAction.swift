import Foundation
import PersistenceCore
import ProviderRouting

/// The root-scoped operation behind Provider Settings' Refresh button. It
/// completes every authority read before producing a visible success state, so
/// the panel cannot mix fresh providers with stale routing selections.
@MainActor
enum ProviderSettingsRefreshAction {
    struct Snapshot {
        let routing: ProviderRoutingSnapshot
        let providers: [ProviderInfo]
        let catalog: ModelCatalogResponse?
        let catalogError: String?
        let rowSet: ProviderSurfaceRowSet
        let activeProviders: [String: String]
        let preferences: [String: SurfacePreference]
        /// Accounts whose own last test failed, by id (`LLMProviderStatusFeed.failedTest`).
        var failedTests: [String: String] = [:]
    }

    enum Outcome {
        case loaded(Snapshot)
        case failed(String)
    }

    static func perform(
        appModel: AppModel,
        refreshCatalog: Bool
    ) async -> Outcome {
        do {
            let facade = appModel.engine.providers
            defer {
                if !refreshCatalog { facade.refreshAccountModelsInBackground() }
            }
            var catalog: ModelCatalogResponse?
            var catalogError: String?
            if refreshCatalog {
                do { catalog = try await facade.modelCatalog(refresh: true) }
                catch { catalogError = UserFacingError.cause(error, action: "refresh the model list") }
            }
            let snapshot = try await facade.routing.checkedProviderSnapshot()
            // Off the main actor: the conversion, and one status-file read whose
            // failed rows each check the account's key in Keychain.
            let dataRoot = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let (providers, failedTests) = try await Task.detached(priority: .userInitiated) {
                let providers = try ProvidersFacade.connections(from: snapshot)
                return (providers, LLMProviderStatusFeed.failedTests(
                    providerIDs: providers.map(\.provider_id), dataRoot: dataRoot))
            }.value
            if catalog == nil {
                do {
                    catalog = try await facade.modelCatalog(refresh: false, routingSnapshot: snapshot.routing)
                } catch { catalogError = UserFacingError.cause(error, action: "load the model list") }
            }
            let config = try ProvidersFacade.modelRoutingConfig(from: snapshot.routing)
            catalog?.current = config.current
            catalog?.defaultModel = config.current.chat.model
            return .loaded(Snapshot(
                routing: snapshot.routing,
                providers: providers,
                catalog: catalog,
                catalogError: catalogError,
                rowSet: snapshot.rowSet,
                activeProviders: snapshot.routing.activeProviders,
                preferences: snapshot.routing.preferences,
                failedTests: failedTests
            ))
        } catch {
            return .failed(UserFacingError.cause(error, action: "read the accounts"))
        }
    }
}
