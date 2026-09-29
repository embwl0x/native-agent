import Foundation
import ProviderRouting
/// The Telegram config used to carry its own model tuple.  The routing store is
/// now the single runtime authority, so a stale legacy tuple can never win a
/// status read simply because it happened to be written more recently.
public struct TelegramBrainResolution: Equatable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let ignoresLegacyTuple: Bool
    public init(model: String? = nil, reasoningEffort: String? = nil, ignoresLegacyTuple: Bool) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.ignoresLegacyTuple = ignoresLegacyTuple
    }

}

public func resolveTelegramBrain(
    routing: SurfacePreference?,
    legacyModel: String?,
    legacyReasoningEffort: String?
) -> TelegramBrainResolution {
    TelegramBrainResolution(
        model: routing?.model,
        reasoningEffort: routing?.reasoningEffort,
        ignoresLegacyTuple: legacyModel != nil || legacyReasoningEffort != nil
    )
}
