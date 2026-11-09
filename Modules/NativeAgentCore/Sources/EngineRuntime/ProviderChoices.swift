import AppToolRuntime
import NativeAgentShared
import ProviderRouting
// Blueprint: | `ProviderChoices.swift` | Provider catalogs and shared descriptor, auth and reasoning conversion |

extension ModelCatalogItem {
    public init(_ model: FirstPartyModelDescriptor, priority: Int) {
        self.init(
            id: model.id,
            displayName: model.name,
            defaultReasoningEffort: model.defaultReasoningEffort,
            supportedReasoningEfforts: model.supportedReasoningEfforts,
            supportsFast: model.supportsFast,
            priority: priority
        )
    }
}

extension ModelCatalogItem: QuietComposerModel {}
extension ReasoningEffortOption: QuietComposerEffort {}
