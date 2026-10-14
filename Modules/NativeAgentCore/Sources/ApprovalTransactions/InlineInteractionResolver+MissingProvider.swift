import Foundation
import NativeAgentShared
import ProviderRouting

public extension InlineInteractionResolver {
    static func raiseMissingChatProvider(
        sessionID: String, userContent: String, hasAttachments: Bool, dataRoot: URL
    ) async {
        // No provider call could raise this card. Attachment bytes are not
        // retained, so only a text-only question may resume after setup.
        _ = await raise(
            InlineInteraction(
                kind: .modelChoice,
                target: ProviderSurfaceGroups.chat.id,
                title: "Connect a provider",
                why: "No AI provider is connected yet, so I can't answer anything.",
                primaryActionLabel: "Open Providers",
                declineConsequence: "I can't reply to anything until a provider is connected.",
                cardProse: "Connect an account in Providers and pick what Chat runs on "
                    + "\u{2014} I'll check when you come back.",
                primaryScope: .persistent
            ),
            sessionID: sessionID,
            resumeText: hasAttachments ? nil : userContent,
            resumable: !hasAttachments,
            dataRoot: dataRoot
        )
    }
}
