import Foundation
import ProviderRouting
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.mac · Spotlight overlay", .serialized)
struct SpotlightOverlayBehaviorEvalTests {
    @Test("a new query takes precedence over a retained reply, while an idle overlay keeps that reply")
    func queryPriorityOverRetainedReply() {
        #expect(!SpotlightOverlayPresentation.showsCommandPalette(input: "", hasReply: true))
        #expect(SpotlightOverlayPresentation.showsCommandPalette(input: "find tools", hasReply: true))
        #expect(SpotlightOverlayPresentation.showsCommandPalette(input: "", hasReply: false))
    }

    @Test("the overlay state exposes command results and unavailability above an old reply, and selection routes before dismissal")
    func overlayShowsCurrentCommandStateAndRoutesSelection() {
        let entry = CoordinationCommandEntry(
            id: "open-capabilities",
            title: "Open Capabilities",
            subtitle: "Manage catalogs and tools",
            category: "navigation",
            systemImage: "shippingbox",
            route: "capabilities",
            endpoint: nil,
            keywords: [],
            status: nil,
            count: nil
        )
        let searchState = SpotlightCommandPalettePresentation.state(
            input: "capabilities",
            isPending: false,
            entries: [entry],
            error: nil
        )
        #expect(SpotlightOverlayPresentation.showsCommandPalette(
            input: "capabilities", hasReply: true))
        #expect(searchState == .entries([entry]))

        let unavailable = SpotlightCommandPalettePresentation.state(
            input: "capabilities",
            isPending: false,
            entries: [],
            error: "Command shortcuts unavailable: local index is unreadable"
        )
        #expect(unavailable == .unavailable(
            "Command shortcuts unavailable: local index is unreadable"))

        var routed: NativeAgentNavigationDestination?
        var didDismiss = false
        #expect(SpotlightCommandPaletteAction.select(
            entry,
            route: { routed = $0 },
            dismiss: { didDismiss = true }
        ))
        #expect(routed == .sidebar(.capabilities))
        #expect(didDismiss)

        let invalidEntry = CoordinationCommandEntry(id: "broken", route: "not-a-route")
        routed = nil
        didDismiss = false
        #expect(!SpotlightCommandPaletteAction.select(
            invalidEntry,
            route: { routed = $0 },
            dismiss: { didDismiss = true }
        ))
        #expect(routed == nil)
        #expect(!didDismiss)
    }

    @Test("a spotlight turn keeps its stable session while using the canonical chat surface pin")
    func spotlightTurnUsesChatRoutingIngredient() async {
        let ingredient = SpotlightTurnIngredient.resolved(
            routing: SurfacePreference(
                surface: "chat",
                model: "pinned-chat-model",
                reasoningEffort: "xhigh",
                serviceTier: "priority"
            ),
            fileAccess: "read_only"
        )
        var submitted: (text: String, ingredient: SpotlightTurnIngredient)?
        let viewModel = SpotlightViewModel(
            ingredientResolver: { ingredient },
            turnSender: { text, resolved in
                submitted = (text, resolved)
                return "Pinned route reply"
            }
        )

        viewModel.input = "Use the selected chat route"
        viewModel.submit()
        for _ in 0..<20 where submitted == nil {
            await Task.yield()
        }

        #expect(submitted?.text == "Use the selected chat route")
        #expect(submitted?.ingredient.sessionId == "spotlight")
        #expect(submitted?.ingredient.model == "pinned-chat-model")
        #expect(submitted?.ingredient.reasoningEffort == "xhigh")
        #expect(submitted?.ingredient.fileAccess == "read_only")
        #expect(viewModel.lastReply == "Pinned route reply")
        #expect(viewModel.error == nil)
    }

    @Test("an unavailable chat route stops the spotlight turn before any cached setting can be sent")
    func spotlightTurnDoesNotFallbackWhenRoutingIsUnavailable() async {
        var sent = false
        let viewModel = SpotlightViewModel(
            ingredientResolver: {
                throw NSError(
                    domain: "SpotlightOverlayBehaviorEval",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "chat routing is unavailable"]
                )
            },
            turnSender: { _, _ in
                sent = true
                return "must not be sent"
            }
        )

        viewModel.input = "Do not use stale settings"
        viewModel.submit()
        for _ in 0..<20 where viewModel.isThinking {
            await Task.yield()
        }

        #expect(!sent)
        #expect(viewModel.lastReply.isEmpty)
        #expect(viewModel.error == "chat routing is unavailable")
    }

}
