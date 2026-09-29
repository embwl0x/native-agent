import Foundation
import PersistenceCore
import ProviderRouting

/// The root-scoped operation behind Provider Settings' Refresh button. It
/// completes every authority read before producing a visible success state, so
/// the panel cannot mix fresh providers with stale routing selections.
@MainActor
enum ProviderSettingsRefreshAction {
    struct Snapshot {
        let providers: [ProviderInfo]
        let catalog: ModelCatalogResponse?
        let rowSet: ProviderSurfaceRowSet
        let activeProviders: [String: String]
        let preferences: [String: SurfacePreference]
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
            let catalog: ModelCatalogResponse?
            if refreshCatalog {
                catalog = try await facade.modelCatalog(refresh: true)
            } else {
                catalog = try? await facade.modelCatalog(refresh: false)
            }
            let providers = try await facade.list()
            let routing = facade.routing
            let rowSet = try await routing.providerSurfaceRowSet()
            let activeProviders = try await facade.activeProviders()
            let preferences = try await routing.computeModelPreferences()
            return .loaded(Snapshot(
                providers: providers,
                catalog: catalog,
                rowSet: rowSet,
                activeProviders: activeProviders,
                preferences: preferences
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
