import Foundation
import Testing
@testable import TelegramBot

// MARK: - Coverage ledger: telegram.preference.spoken
//                         telegram.card.plainSpeech
//
// The Telegram control panel was deleted down to six commands (2026-09-01,
// sweep item 48). Everything model/effort/fast/persona now arrives as words.
// Two things have to stay true or the deletion becomes a loss:
//   1. a spoken preference reaches the SAME writer the slash spelling wrote
//      through — one writer per preference, no second path to drift;
//   2. ordinary conversation is never mistaken for a preference change.
// The card assertions pin the other half: User never reads a state-machine
// phase label, while the phases themselves stay intact for receipts.

private final class RecordingRouting: ProviderRoutingRef, @unchecked Sendable {
    var current: (model: String, provider: String)? = ("claude-opus-4-8", "anthropic_oauth_direct")
    var menu: TelegramModelMenu?
    var savedConfigs: [(surface: String, key: String, value: String)] = []
    var savedSelections: [(surface: String, provider: String?, model: String)] = []

    func modelForSurface(_ surface: String) async -> (model: String, provider: String)? { current }
    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? { menu }

    func saveModelConfig(surface: String, key: String, value: String) async throws {
        savedConfigs.append((surface: surface, key: key, value: value))
    }

    func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        savedSelections.append((surface: surface, provider: provider, model: model))
    }
}

private func spokenTestMenu() -> TelegramModelMenu {
    TelegramModelMenu(
        surface: "telegram",
        currentModel: "claude-opus-4-8",
        currentProvider: "anthropic_oauth_direct",
        providers: [
            TelegramModelProviderChoice(
                id: "anthropic_oauth_direct",
                displayName: "Anthropic",
                isCurrent: true,
                models: [
                    TelegramModelChoice(
                        id: "claude-opus-4-8",
                        name: "Claude Opus 4.8",
                        isCurrent: true,
                        supportedReasoningEfforts: ["low", "medium", "high"],
                        supportsFast: true
                    ),
                    TelegramModelChoice(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6"),
                ]
            ),
            TelegramModelProviderChoice(
                id: "codex",
                displayName: "Codex CLI",
                models: [TelegramModelChoice(id: "gpt-5.5", name: "GPT-5.5")]
            ),
        ]
    )
}

private func makeSpokenLoop(
    routing: RecordingRouting,
    root: URL
) async -> TelegramPollLoop {
    let bot = SwiftNativeTelegramBot(dataRoot: root)
    await bot.registerCompletenessDeps(TelegramBotCompletenessDeps(routing: routing))
    return TelegramPollLoop(
        interval: 60,
        token: "111:test-token",
        allowedChatIds: [77],
        bot: bot,
        dataRoot: root,
        offsetURL: root.appendingPathComponent("offset.json")
    )
}

@Suite struct TelegramSpokenPreferenceTests {

    // MARK: parsing

    @Test func parsesTheRetiredControlsAsPlainRequests() {
        #expect(TelegramSpokenPreference.parse(text: "use opus") == .model(query: "opus"))
        #expect(TelegramSpokenPreference.parse(text: "Switch to GPT-5.5.") == .model(query: "gpt-5.5"))
        #expect(TelegramSpokenPreference.parse(text: "think harder") == .effort(.highest))
        #expect(TelegramSpokenPreference.parse(text: "think less") == .effort(.lowest))
        #expect(TelegramSpokenPreference.parse(text: "think high") == .effort(.level("high")))
        #expect(TelegramSpokenPreference.parse(text: "go fast") == .fast(true))
        #expect(TelegramSpokenPreference.parse(text: "turn off fast mode") == .fast(false))
        #expect(TelegramSpokenPreference.parse(text: "use the Agent persona") == .persona("agent"))
        #expect(TelegramSpokenPreference.parse(text: "what model are you on?") == .whichModel)
    }

    /// The expensive failure mode is a sentence that LOOKS like a setting.
    @Test func leavesOrdinaryConversationAlone() {
        for ordinary in [
            "can you look at the repo",
            "switch to the branch I pushed this morning and check the tests",
            "use whatever you think is best here, I trust you",
            "think about what that means for the sync loop",
            "I need to be fast today",
            "what model railway did you mean",
        ] {
            #expect(
                TelegramSpokenPreference.parse(text: ordinary) == nil,
                "\(ordinary) was mistaken for a preference change"
            )
        }
    }

    @Test func aSpokenModelOnlyCountsWhenItResolvesAgainstTheLiveMenu() {
        let menu = spokenTestMenu()
        let opus = TelegramSpokenPreference.resolveModel(query: "opus", in: menu)
        #expect(opus?.modelId == "claude-opus-4-8")
        #expect(opus?.providerId == "anthropic_oauth_direct")

        #expect(TelegramSpokenPreference.resolveModel(query: "gpt 5.5", in: menu)?.modelId == "gpt-5.5")
        #expect(TelegramSpokenPreference.resolveModel(query: "sonnet", in: menu)?.modelId == "claude-sonnet-4-6")
        #expect(TelegramSpokenPreference.resolveModel(query: "the repo", in: menu) == nil)
    }

    /// REGRESSION (reviewer finding, 2026-09-01). An AMBIGUOUS partial used to
    /// resolve to the first hit on the current provider — "switch to claude"
    /// silently picked Opus over Sonnet and reported it as a done deal. A
    /// partial only counts when it names exactly one model; otherwise this
    /// returns nil, the message stays ordinary conversation, and the ordinary
    /// reply path asks User which one he meant.
    @Test func anAmbiguousSpokenModelNameResolvesToNothing() {
        let menu = spokenTestMenu()
        // Two models on the CURRENT provider match "claude".
        #expect(TelegramSpokenPreference.resolveModel(query: "claude", in: menu) == nil)
        // Ambiguous across providers with no current-provider hit at all.
        let crossProvider = TelegramModelMenu(
            surface: "telegram",
            currentModel: "claude-opus-4-8",
            currentProvider: "anthropic_oauth_direct",
            providers: [
                TelegramModelProviderChoice(
                    id: "codex",
                    displayName: "Codex CLI",
                    models: [
                        TelegramModelChoice(id: "gpt-5.5", name: "GPT-5.5"),
                        TelegramModelChoice(id: "gpt-5.5-mini", name: "GPT-5.5 Mini"),
                    ]
                ),
            ]
        )
        #expect(TelegramSpokenPreference.resolveModel(query: "gpt", in: crossProvider) == nil)
        // An EXACT name still wins outright, ambiguous prefix or not.
        #expect(
            TelegramSpokenPreference.resolveModel(query: "gpt 5.5", in: crossProvider)?.modelId
                == "gpt-5.5"
        )
        // A partial that is unique only ON THE CURRENT PROVIDER still resolves:
        // "opus" hits Anthropic's Opus and nothing else there.
        #expect(
            TelegramSpokenPreference.resolveModel(query: "opus", in: menu)?.providerId
                == "anthropic_oauth_direct"
        )
    }

    // MARK: same writer as the retired slash spellings

    @Test func spokenModelSwitchReachesTheSameWriterAsSlashModel() async throws {
        let slashRouting = RecordingRouting()
        slashRouting.menu = spokenTestMenu()
        let slashRoot = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: slashRoot) }
        let slashBot = SwiftNativeTelegramBot(dataRoot: slashRoot)
        await slashBot.registerCompletenessDeps(
            TelegramBotCompletenessDeps(routing: slashRouting)
        )
        _ = try await slashBot.dispatchSwiftSlashCommand(
            "/model", args: ["anthropic_oauth_direct", "claude-sonnet-4-6"], chatId: 77
        )

        let spokenRouting = RecordingRouting()
        spokenRouting.menu = spokenTestMenu()
        let spokenRoot = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: spokenRoot) }
        let loop = await makeSpokenLoop(routing: spokenRouting, root: spokenRoot)
        let reply = await loop.spokenPreferenceReply(destination: .chat(77), text: "use sonnet")

        #expect(slashRouting.savedSelections.count == 1)
        #expect(spokenRouting.savedSelections.count == 1)
        let viaSlash = try #require(slashRouting.savedSelections.first)
        let viaWords = try #require(spokenRouting.savedSelections.first)
        #expect(viaWords.surface == viaSlash.surface)
        #expect(viaWords.provider == viaSlash.provider)
        #expect(viaWords.model == viaSlash.model)
        #expect(reply == "Switched to Claude Sonnet 4.6 on Anthropic.")
    }

    @Test func spokenEffortAndFastReachTheSameConfigWriter() async throws {
        let routing = RecordingRouting()
        routing.menu = spokenTestMenu()
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = await makeSpokenLoop(routing: routing, root: root)

        _ = await loop.spokenPreferenceReply(destination: .chat(77), text: "think harder")
        _ = await loop.spokenPreferenceReply(destination: .chat(77), text: "go fast")

        #expect(routing.savedConfigs.count == 2)
        #expect(routing.savedConfigs[0].key == "reasoning_effort")
        #expect(routing.savedConfigs[0].value == "high")
        #expect(routing.savedConfigs[1].key == "service_tier")
        #expect(routing.savedConfigs[1].value == "priority")
    }

    @Test func spokenPreferenceIgnoresOrdinaryChat() async throws {
        let routing = RecordingRouting()
        routing.menu = spokenTestMenu()
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = await makeSpokenLoop(routing: routing, root: root)

        let reply = await loop.spokenPreferenceReply(
            destination: .chat(77), text: "can you check whether the sync loop is still wedged"
        )
        #expect(reply == nil)
        #expect(routing.savedSelections.isEmpty)
        #expect(routing.savedConfigs.isEmpty)
    }

    /// A spoken preference has to work the same said out loud as typed.
    @Test func aVoiceNoteCarriesTheSameSpokenPreference() {
        let envelope = """
        [Telegram voice message]
        Transcript: use opus
        """
        #expect(
            TelegramSpokenPreference.parse(
                text: TelegramPollLoop.spokenPreferenceSource(envelope)
            ) == .model(query: "opus")
        )
    }

    // MARK: the card speaks, it does not label

    @Test func theWorkCardNeverRendersAPhaseLabel() {
        let start = Date(timeIntervalSince1970: 0)
        let events: [TelegramTurnPresentationLifecycleEvent] = [
            .acknowledged,
            .working(action: "Reading the repo"),
            .tool(name: "read_file", action: "Reading the repo"),
            .delegation(delegate: "Codex", action: "Reviewing tests"),
            .retrying(action: nil),
            .waiting(action: nil),
            .blocked(reason: nil),
            .stalled(reason: nil),
            .completed(summary: "Reply delivered"),
            .failed(reason: nil),
            .canceled(reason: "Stopped by user"),
            .outcomeUnknown(reason: nil),
        ]
        // Every title the card used to print, plus the mechanics line.
        let banned = [
            "Acknowledged", "Working", "Using tool", "Delegated work", "Retrying",
            "Waiting ·", "Blocked", "Stalled", "Completed", "Failed", "Canceled",
            "Outcome unknown", "Phase:", "elapsed", "moved", "Action:", "Delegate:",
        ]
        for event in events {
            let state = TelegramTurnPresentationReducer.reduce(
                TelegramTurnPresentationReducer.initialState(at: start),
                lifecycle: event,
                at: start.addingTimeInterval(1)
            )
            for rendered in [
                TelegramTurnPresentationRenderer.render(state, at: start.addingTimeInterval(2)),
                TelegramTurnPresentationRenderer.renderDetails(state, at: start.addingTimeInterval(2)),
            ] {
                for token in banned {
                    #expect(
                        !rendered.contains(token),
                        "card printed the phase-machine token \(token): \(rendered)"
                    )
                }
            }
        }
    }

    /// The phases themselves are untouched — receipts and telemetry read them.
    @Test func thePhasesSurviveBehindThePlainSpeech() {
        let start = Date(timeIntervalSince1970: 0)
        let blocked = TelegramTurnPresentationReducer.reduce(
            TelegramTurnPresentationReducer.initialState(at: start),
            lifecycle: .blocked(reason: "needs your approval"),
            at: start
        )
        #expect(blocked.phase == .blocked)
        #expect(blocked.phase.rawValue == "blocked")
        #expect(
            TelegramTurnPresentationRenderer.render(blocked, at: start)
                .hasPrefix("Waiting on an approval from you")
        )
    }
}
