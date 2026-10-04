import Foundation
import NativeAgentShared
import ProviderRouting

public typealias CodexSelectableModelCatalog = CodexAccountModelCatalog

extension CodexAccountModelCatalog {
    public static func modelCatalogItems(
        providerID: String = "codex",
        cacheURL: URL? = nil,
        useDefaultCacheWhenNil: Bool = true
    ) -> [ModelCatalogItem] {
        load(providerID: providerID, cacheURL: cacheURL,
             useDefaultCacheWhenNil: useDefaultCacheWhenNil).map {
            ModelCatalogItem(
                id: $0.id,
                displayName: $0.displayName,
                description: $0.description,
                defaultReasoningEffort: $0.defaultReasoningEffort,
                supportedReasoningEfforts: $0.supportedReasoningEfforts,
                supportsFast: $0.supportsFast,
                priority: $0.priority
            )
        }
    }


}
