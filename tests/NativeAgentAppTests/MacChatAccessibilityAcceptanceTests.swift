import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac chat release accessibility acceptance")
struct MacChatAccessibilityAcceptanceTests {
    @Test func campaignMotionHonorsReduceMotionInBothWindows() throws {
        let main = try AppSourceScraping.appSource("ChatView.swift")
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        let composer = try AppSourceScraping.appSource("ChatComposerChrome.swift")
        let banner = try AppSourceScraping.appSource("MacChatOtherSessionsBanner.swift")

        for source in [main, detached, composer, banner] {
            #expect(source.contains("accessibilityReduceMotion"))
            #expect(source.contains("reduceMotion"))
        }
        #expect(main.contains("withAnimation(NativeAgentMotion.respecting("))
        #expect(detached.contains("withAnimation(NativeAgentMotion.respecting("))
        #expect(composer.contains("NativeAgentMotion.respecting(NativeAgentMotion.snappy"))
        #expect(banner.contains("reduceMotion\n                    ? .identity"))

        // Search enters with the same no-motion branch in the main and detached
        // transcript owners. This is the path added by Desk 658.15.
        for source in [main, detached] {
            #expect(source.contains("? .identity\n"))
            #expect(source.contains(": .move(edge: .top).combined(with: .opacity)"))
        }
    }

    @Test func frequentlyChangingSearchAndTurnValuesAreMarkedForVoiceOver() throws {
        let search = try AppSourceScraping.appSource("MacChatTranscriptSearch.swift")
        let card = try AppSourceScraping.appSource("MacChatTurnCard.swift")

        #expect(search.contains(".accessibilityLabel(\"Search status: \\(controller.statusText)\")"))
        #expect(search.contains(".accessibilityAddTraits(.updatesFrequently)"))
        #expect(card.contains(".accessibilityLabel(model.spokenMeta)"))
        #expect(card.contains(".accessibilityAddTraits(.updatesFrequently)"))

        let icon = try #require(search.range(of: "Image(systemName: \"magnifyingglass\")"))
        let field = try #require(search.range(of: "TextField(", range: icon.upperBound..<search.endIndex))
        let iconBlock = search[icon.lowerBound..<field.lowerBound]
        #expect(iconBlock.contains(".accessibilityHidden(true)"),
                "The decorative search icon must not become an extra VoiceOver stop.")
    }

    @Test func messageActionsNeverAdvertiseNoOpsOrInvisibleHoverButtons() throws {
        let source = try AppSourceScraping.appSource("ChatMessageListView.swift")
        let modifierStart = try #require(source.range(of: "private struct MessageBubbleAccessibilityActions"))
        let hoverStart = try #require(source.range(of: "private struct BubbleHoverBar"))
        let modifier = String(source[modifierStart.lowerBound..<hoverStart.lowerBound])

        #expect(modifier.contains("if isUser"))
        #expect(modifier.contains(".accessibilityAction(named: \"Copy message\", onCopy)"))
        #expect(modifier.contains(".accessibilityAction(named: \"Read message aloud\", onReadAloud)"))
        #expect(modifier.contains(".accessibilityAction(named: \"Regenerate response\", onRegenerate)"))
        #expect(modifier.contains("Mark response helpful"))
        #expect(modifier.contains("Mark response not helpful"))
        #expect(!source.contains("if !isUser { toggleReadAloud() }"),
                "A user message must not expose an assistant-only action that does nothing.")

        let hoverCall = try #require(source.range(of: "BubbleHoverBar("))
        let timestamp = try #require(source.range(of: "Text(displayTimestamp)", range: hoverCall.upperBound..<source.endIndex))
        let hoverOverlay = source[hoverCall.lowerBound..<timestamp.lowerBound]
        #expect(hoverOverlay.contains(".accessibilityHidden(true)"),
                "Opacity-zero pointer controls must not remain phantom VoiceOver focus stops.")
    }

    @Test func composerAndSearchKeepAStableKeyboardFocusOrder() throws {
        let composer = try AppSourceScraping.appSource("ChatComposerChrome.swift")
        let options = try #require(composer.range(of: "Menu {"))
        let input = try #require(composer.range(of: "inputContent", range: options.upperBound..<composer.endIndex))
        let stop = try #require(composer.range(of: "if isRunning", range: input.upperBound..<composer.endIndex))
        let send = try #require(composer.range(of: "Button(action: onSend)", range: stop.upperBound..<composer.endIndex))
        #expect(options.lowerBound < input.lowerBound)
        #expect(input.lowerBound < stop.lowerBound)
        #expect(stop.lowerBound < send.lowerBound)

        let search = try AppSourceScraping.appSource("MacChatTranscriptSearch.swift")
        let field = try #require(search.range(of: "TextField("))
        let status = try #require(search.range(of: "Text(controller.statusText)", range: field.upperBound..<search.endIndex))
        let previous = try #require(search.range(of: "controller.selectPrevious()", range: status.upperBound..<search.endIndex))
        let next = try #require(search.range(of: "controller.selectNext()", range: previous.upperBound..<search.endIndex))
        let close = try #require(search.range(of: "Button(action: onDismiss)", range: next.upperBound..<search.endIndex))
        #expect(field.lowerBound < status.lowerBound)
        #expect(status.lowerBound < previous.lowerBound)
        #expect(previous.lowerBound < next.lowerBound)
        #expect(next.lowerBound < close.lowerBound)
    }

    @Test func campaignGlassSurfacesUseTheCanonicalReducedTransparencyOwner() throws {
        let design = try AppSourceScraping.appSource("NativeAgentDesign.swift")
        let composer = try AppSourceScraping.appSource("ChatComposerChrome.swift")
        let card = try AppSourceScraping.appSource("MacChatTurnCard.swift")

        #expect(design.contains("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency"))
        #expect(design.contains("if reduceTransparency || scrollRow"))
        #expect(composer.contains("GlassCard(tint:"))
        #expect(card.contains("GlassCard(tint:"))
    }
}
