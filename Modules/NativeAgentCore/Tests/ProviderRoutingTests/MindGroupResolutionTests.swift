import Foundation
import Testing
@testable import ProviderRouting
import NativeAgentCore

/// User, 2026-09-13: "Dream, REM, everything should go to the memory model; I
/// already specified that when we compressed provider picks."
///
/// The cases he asked to see, proved for EVERY member of the Providers page's
/// **Memory and mind** group — Memory, Dreams, REM, Reflection, Conversation
/// summaries, Learning and Creative exploration:
///   1. Chat on `openai_oauth_direct` / `gpt-6-astra`, no group override →
///      every member resolves to that route and model.
///   2. The group overridden to Anthropic `claude-opus-4-8` → every member
///      resolves to that.
///   3. A stale saved pick of a model the catalog no longer carries (the
///      `gpt-5.4-mini` a 0.4.11 install could be left holding) is NOT a pick:
///      the surface goes back to the group's choice, with no literal
///      substitution anywhere.
///
/// This is the regression fence for the 0.4.11 dream-failure report: no lane carries a
/// model of its own, so none can run on a model its account cannot serve.
@Suite struct MindGroupResolutionTests {

    private func router(
        surfaces: String,
        active: String
    ) throws -> SwiftNativeProviderRouting {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mind-group-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let surfacesPath = providers.appendingPathComponent("surfaces.json")
        let activePath = providers.appendingPathComponent("active.json")
        try Data(surfaces.utf8).write(to: surfacesPath)
        try Data(active.utf8).write(to: activePath)
        // A signed-in ChatGPT account, the only route on a ChatGPT-only install.
        let auth: [String: Any] = ["tokens": [
            "access_token": "chatgpt-access",
            "refresh_token": "chatgpt-refresh",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        ]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["api_key": "sk-ant-test"])
            .write(to: providers.appendingPathComponent("anthropic.json"))
        return SwiftNativeProviderRouting(
            dataRoot: root,
            surfacesPathOverride: surfacesPath,
            activeProviderPathOverride: activePath
        )
    }

    @Test func case1_noOverride_everyMindSurfaceTakesChatsRouteAndModel() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-6-astra","reasoningEffort":"medium"}}"#,
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            let entry = try #require(prefs[surface], "missing \(surface)")
            #expect(entry.model == "gpt-6-astra", "model mismatch @\(surface): \(entry.model)")
            #expect(entry.reasoningEffort == "medium", "effort mismatch @\(surface)")
        }
        // Nothing is pinned, so the page's origin caption reads "Same as Chat".
        for surface in ProviderSurfaceGroups.mind.surfaces {
            #expect(await sn.pinnedModelStringForSurface(surface) == nil)
        }
    }

    @Test func case2_groupOverride_everyMindSurfaceTakesTheOverride() async throws {
        var picks = ["\"chat\":{\"model\":\"gpt-6-astra\"}"]
        var assignments = ["\"chat\":\"openai_oauth_direct\""]
        for surface in ProviderSurfaceGroups.mind.surfaces {
            picks.append("\"\(surface)\":{\"model\":\"claude-opus-4-8\"}")
            assignments.append("\"\(surface)\":\"anthropic\"")
        }
        let sn = try router(
            surfaces: "{" + picks.joined(separator: ",") + "}",
            active: "{" + assignments.joined(separator: ",") + "}"
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            let entry = try #require(prefs[surface], "missing \(surface)")
            #expect(entry.model == "claude-opus-4-8", "model mismatch @\(surface): \(entry.model)")
            #expect(await sn.pinnedModelStringForSurface(surface) == "claude-opus-4-8")
        }
        #expect(prefs["chat"]?.model == "gpt-6-astra")
    }

    @Test func case3_staleRetiredPickOnDream_returnsToTheGroupsChoice() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-6-astra"},"dream":{"model":"gpt-5.4-mini"}}"#,
            active: #"{"chat":"openai_oauth_direct","dream":"openai_oauth_direct"}"#
        )
        let prefs = try await sn.computeModelPreferences()
        // No literal substitution: the pick simply stops being a pick, and dream
        // answers with the group's choice — here Chat's, since the group has no
        // override of its own.
        #expect(prefs["dream"]?.model == "gpt-6-astra")
        #expect(prefs["dream"]?.model == prefs["chat"]?.model)
        // And the page agrees: no pin, so the caption reads "Same as Chat"
        // rather than claiming an override that no longer exists.
        #expect(await sn.pinnedModelStringForSurface("dream") == nil)
        // A pick the catalog still carries is untouched.
        #expect(FirstPartyModelCatalog.descriptor(for: "gpt-5.4-mini") == nil)
        #expect(FirstPartyModelCatalog.descriptor(for: "gpt-6-astra") != nil)
    }

    /// The resolver keeps no model, effort, or provider exception of its own for
    /// any surface: with one Chat pick on disk, every routed surface in every
    /// group answers identically.
    @Test func noSurfaceCarriesASeedOfItsOwn() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-6-astra","reasoningEffort":"low"}}"#,
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in MODEL_SURFACES {
            let entry = try #require(prefs[surface], "missing \(surface)")
            #expect(entry.model == "gpt-6-astra", "model mismatch @\(surface): \(entry.model)")
            #expect(entry.reasoningEffort == "low", "effort mismatch @\(surface)")
        }
    }

    /// The page and the router read one membership table, and it covers the
    /// routed surface list exactly — a new surface cannot be added without
    /// deciding which of the three groups shows it.
    @Test func groupsAndRoutedSurfacesCoverEachOtherExactly() {
        let mismatch = ProviderSurfaceGroups.membershipMismatch()
        #expect(mismatch == nil, "\(mismatch ?? "")")
        #expect(ProviderSurfaceGroups.all.count == 3)
    }

    /// User, 2026-09-13: "Don't gear this thing towards one thing. Anybody could
    /// use Moonshot, OpenRouter, anything." The same three cases on routes that
    /// are not OpenAI — including OpenRouter, whose catalog is fetched rather
    /// than shipped, so an id this build has never seen stays a pick.
    @Test(arguments: [
        (provider: "openrouter", model: "deepseek/deepseek-r1", override: "moonshot", overrideModel: "kimi-k3"),
        (provider: "moonshot", model: "kimi-k3", override: "anthropic", overrideModel: "claude-opus-4-8"),
    ])
    func everyRouteResolvesTheSameWay(
        _ route: (provider: String, model: String, override: String, overrideModel: String)
    ) async throws {
        // 1. No override: the whole group follows Chat's route and model.
        let plain = try router(
            surfaces: "{\"chat\":{\"model\":\"\(route.model)\"}}",
            active: "{\"chat\":\"\(route.provider)\"}"
        )
        let plainPrefs = try await plain.computeModelPreferences()
        for surface in MODEL_SURFACES {
            #expect(plainPrefs[surface]?.model == route.model,
                    "model mismatch @\(surface) on \(route.provider): \(plainPrefs[surface]?.model ?? "nil")")
        }

        // 2. The group overridden to another provider entirely.
        var picks = ["\"chat\":{\"model\":\"\(route.model)\"}"]
        var assignments = ["\"chat\":\"\(route.provider)\""]
        for surface in ProviderSurfaceGroups.mind.surfaces {
            picks.append("\"\(surface)\":{\"model\":\"\(route.overrideModel)\"}")
            assignments.append("\"\(surface)\":\"\(route.override)\"")
        }
        let overridden = try router(
            surfaces: "{" + picks.joined(separator: ",") + "}",
            active: "{" + assignments.joined(separator: ",") + "}"
        )
        let overriddenPrefs = try await overridden.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            #expect(overriddenPrefs[surface]?.model == route.overrideModel,
                    "override mismatch @\(surface): \(overriddenPrefs[surface]?.model ?? "nil")")
        }
        #expect(overriddenPrefs["chat"]?.model == route.model)

        // 3. A stale pick of a retired id on dream never survives as itself. On a
        //    route this build ships a catalog for, the pick is judged against
        //    THAT route and unpins, so dream returns to the group's choice. On a
        //    route whose catalog is fetched (OpenRouter), this build cannot say
        //    the id is retired — but the id belongs to another family, so the
        //    route's own default answers instead. Either way: never gpt-5.4-mini,
        //    and never a literal chosen in code.
        let stale = try router(
            surfaces: "{\"chat\":{\"model\":\"\(route.model)\"},\"dream\":{\"model\":\"gpt-5.4-mini\"}}",
            active: "{\"chat\":\"\(route.provider)\"}"
        )
        let stalePrefs = try await stale.computeModelPreferences()
        let dreamModel = try #require(stalePrefs["dream"]?.model)
        #expect(dreamModel != "gpt-5.4-mini")
        if FirstPartyModelCatalog.hasStaticCatalog(providerID: route.provider) {
            #expect(dreamModel == route.model)
            #expect(await stale.pinnedModelStringForSurface("dream") == nil)
        }
    }

    /// An id this build has never seen on a route whose catalog is FETCHED is not
    /// convicted as retired — the unpinning rule must not delete an OpenRouter or
    /// self-hosted model just because we ship no row for it. It is kept as a
    /// saved pick the page can show; it simply does not ROUTE on its own, because
    /// per-surface keys never do (second review).
    @Test func unknownIdOnAFetchedCatalogRouteIsNotConvicted() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"anthropic/claude-sonnet-5"},"dream":{"model":"meta-llama/llama-3.3-70b-instruct"}}"#,
            active: #"{"chat":"openrouter","dream":"openrouter"}"#
        )
        let snapshot = try await sn.checkedRoutingSnapshot()
        // Not reported as unusable, and still visible as a saved pick.
        #expect(snapshot.unusablePickNotice(for: "dream") == nil)
        #expect(snapshot.pinnedModels["dream"] == "meta-llama/llama-3.3-70b-instruct")
        // Routing follows the group, which here is Chat's choice.
        #expect(snapshot.preferences["dream"]?.model == "anthropic/claude-sonnet-5")
    }

    /// User, 2026-09-13: "Whatever their first provider is, they put it in there
    /// and connect to it, it should just auto-populate with their first pick. If
    /// I sign in with ChatGPT and pick Astra, everything goes to Astra. If they
    /// pick a DeepSeek model off OpenRouter with their key, it's all that until
    /// they switch it."
    ///
    /// A fresh root after the first connect: ONE assignment (`chat`) and ONE pick
    /// (Chat's model) — which is what `adoptProviderForBlankSurfaces` writes now,
    /// instead of an assignment per surface. Every routed surface answers with
    /// that route and model, and nothing is pinned, so the page reads
    /// "All activities match Chat".
    @Test(arguments: [
        (provider: "openrouter", model: "deepseek/deepseek-r1"),
        (provider: "openai_oauth_direct", model: "gpt-6-astra"),
        (provider: "moonshot", model: "kimi-k3"),
        (provider: "anthropic", model: "claude-opus-4-8"),
    ])
    func freshInstall_firstConnectedAccountBecomesEverySurface(
        _ first: (provider: String, model: String)
    ) async throws {
        let sn = try router(
            surfaces: "{\"chat\":{\"model\":\"\(first.model)\"}}",
            active: "{\"chat\":\"\(first.provider)\"}"
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in MODEL_SURFACES {
            #expect(prefs[surface]?.model == first.model,
                    "@\(surface) on \(first.provider): \(prefs[surface]?.model ?? "nil")")
        }
        for surface in MODEL_SURFACES where surface != "chat" {
            #expect(await sn.pinnedModelStringForSurface(surface) == nil,
                    "\(surface) must not be pinned on a fresh install")
        }
    }

    /// 2026-09-13 review: a group override is what the page writes — the same
    /// choice on every member — and a member with nothing of its own follows it,
    /// not just Chat. One stray key is a pin on its own surface, never the
    /// group's answer.
    @Test func aGroupOverrideAppliesToMembersWithNoPickOfTheirOwn() async throws {
        var picks = ["\"chat\":{\"model\":\"gpt-6-astra\"}"]
        for surface in ProviderSurfaceGroups.mind.surfaces where surface != "dream" {
            picks.append("\"\(surface)\":{\"model\":\"claude-opus-4-8\"}")
        }
        // dream carries nothing; the rest of Memory and mind agree.
        let sn = try router(
            surfaces: "{" + picks.joined(separator: ",") + "}",
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let prefs = try await sn.computeModelPreferences()
        // Not unanimous (dream has no pick), so the group has no override and
        // every member without one follows Chat — including dream.
        #expect(prefs["dream"]?.model == "gpt-6-astra")

        // Now the page's actual write: every member, same choice — model AND
        // route, because a group override moves both.
        var all = ["\"chat\":{\"model\":\"gpt-6-astra\"}"]
        var assignments = ["\"chat\":\"openai_oauth_direct\""]
        for surface in ProviderSurfaceGroups.mind.surfaces {
            all.append("\"\(surface)\":{\"model\":\"claude-opus-4-8\"}")
            assignments.append("\"\(surface)\":\"anthropic\"")
        }
        let overridden = try router(
            surfaces: "{" + all.joined(separator: ",") + "}",
            active: "{" + assignments.joined(separator: ",") + "}"
        )
        let overriddenPrefs = try await overridden.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            #expect(overriddenPrefs[surface]?.model == "claude-opus-4-8")
        }
    }

    /// User, 2026-09-13 (second review): a per-surface key does not route AT ALL.
    /// The page offers three choices and says "Choosing here sets all four", so a
    /// key written for one activity is something a person cannot see — it must
    /// not split its group, not even for itself. The next group write clears it.
    @Test func aStrayPerSurfacePickDoesNotRouteAnywhere() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-6-astra"},"dream":{"model":"gpt-5.6-luna"}}"#,
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            #expect(prefs[surface]?.model == "gpt-6-astra", "@\(surface) took a stray key")
        }
        // The page still SHOWS it as a saved pick, which is how a person finds
        // and clears it.
        #expect(await sn.pinnedModelStringForSurface("dream") == "gpt-5.6-luna")
    }

    /// The route travels WITH the model: an inherited surface reports Chat's
    /// exact route, so nothing downstream has to guess it from the model id.
    @Test func inheritedSurfacesReportChatsExactRoute() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-6-astra"}}"#,
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let snapshot = try await sn.checkedRoutingSnapshot()
        for surface in MODEL_SURFACES {
            #expect(snapshot.activeProviders[surface] == "openai_oauth_direct",
                    "@\(surface): \(snapshot.activeProviders[surface] ?? "nil")")
        }
    }

    /// A retired Chat pick is NOT replaced by the route's default: Chat reads as
    /// not set up, and the snapshot says which model went so the page and the
    /// turn refusal can name it.
    @Test func aRetiredChatPickLeavesChatUnsetWithADiagnostic() async throws {
        let sn = try router(
            surfaces: #"{"chat":{"model":"gpt-5.4"}}"#,
            active: #"{"chat":"openai_oauth_direct"}"#
        )
        let snapshot = try await sn.checkedRoutingSnapshot()
        #expect(snapshot.preferences["chat"]?.model == "")
        #expect(snapshot.unusablePickNotice(for: "chat")
            == "Your model, gpt-5.4, is no longer offered. Choose one.")
        // And every other surface inherits that same "not set up" answer rather
        // than a model nobody chose.
        #expect(snapshot.preferences["dream"]?.model == "")
    }

    /// User, 2026-09-13 (third review): the sole-connected fallback carries the
    /// EXACT route id. The family answer collapses `codex` and
    /// `openai_oauth_direct` into "openai" — a name no adapter is registered
    /// under — so a ChatGPT-account-only install must not resolve against it.
    @Test func theSoleConnectedFallbackIsARouteNotAFamily() async throws {
        let sn = try router(surfaces: "{}", active: "{}")
        #expect(await sn.soleConnectedProviderID() == nil, "the fixture connects two accounts")

        // One account only: the ChatGPT sign-in the fixture writes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sole-route-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: providers.appendingPathComponent("surfaces.json"))
        try Data("{}".utf8).write(to: providers.appendingPathComponent("active.json"))
        let auth: [String: Any] = ["tokens": [
            "access_token": "chatgpt-access",
            "refresh_token": "chatgpt-refresh",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        ]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        let only = SwiftNativeProviderRouting(
            dataRoot: root,
            surfacesPathOverride: providers.appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: providers.appendingPathComponent("active.json")
        )
        // The family answer is still "openai"; the ROUTE is the record's own id,
        // and that is what routing uses.
        #expect(await only.soleConnectedProviderFamily() == "openai")
        let route = await only.soleConnectedProviderID()
        #expect(route == "openai_oauth_direct" || route == "codex", "got \(route ?? "nil")")
        let snapshot = try await only.checkedRoutingSnapshot()
        #expect(snapshot.activeProviders["chat"] != "openai")
    }

    /// A group override is the WHOLE tuple. Two members on the same model but
    /// different accounts are two answers, not one (third review).
    @Test func sameModelOnDifferentAccountsIsNotAGroupOverride() async throws {
        var picks = ["\"chat\":{\"model\":\"gpt-6-astra\"}"]
        var assignments = ["\"chat\":\"openai_oauth_direct\""]
        for (index, surface) in ProviderSurfaceGroups.mind.surfaces.enumerated() {
            picks.append("\"\(surface)\":{\"model\":\"claude-opus-4-8\"}")
            // Same model, two different accounts: an API key and an OAuth
            // sign-in. That is Mixed, not an override.
            assignments.append("\"\(surface)\":\"\(index == 0 ? "anthropic_oauth_direct" : "anthropic")\"")
        }
        let sn = try router(
            surfaces: "{" + picks.joined(separator: ",") + "}",
            active: "{" + assignments.joined(separator: ",") + "}"
        )
        let prefs = try await sn.computeModelPreferences()
        for surface in ProviderSurfaceGroups.mind.surfaces {
            #expect(prefs[surface]?.model == "gpt-6-astra",
                    "@\(surface) took a half-agreed override: \(prefs[surface]?.model ?? "nil")")
        }
    }

    /// The 0.4.11 case, reached from the other side (2026-09-13, fourth review):
    /// an OAuth-only install with NOTHING pinned, read through the diagnostic
    /// read-only snapshot. That entry point omitted the connected route, so it
    /// answered with an empty route and an empty model — the same dead end the
    /// whole round started from. Every snapshot entry point carries it.
    @Test func everySnapshotEntryPointResolvesTheOnlyConnectedRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readonly-route-\(UUID().uuidString)", isDirectory: true)
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex_home", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let surfaces = providers.appendingPathComponent("surfaces.json")
        let active = providers.appendingPathComponent("active.json")
        try Data("{}".utf8).write(to: surfaces)
        try Data("{}".utf8).write(to: active)
        let auth: [String: Any] = ["tokens": [
            "access_token": "chatgpt-access",
            "refresh_token": "chatgpt-refresh",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        ]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: codexHome.appendingPathComponent("auth.json"))
        let sn = SwiftNativeProviderRouting(
            dataRoot: root,
            surfacesPathOverride: surfaces,
            activeProviderPathOverride: active
        )

        for snapshot in [
            try await sn.checkedRoutingSnapshot(),
            try await sn.checkedRoutingSnapshotReadOnly(),
        ] {
            let route = try #require(snapshot.activeProviders["chat"])
            #expect(route == "openai_oauth_direct", "got \(route)")
            #expect(snapshot.preferences["chat"]?.model.isEmpty == false,
                    "an install with one connected account has a model to run on")
            // And every lane inherits that same answer — dreams included.
            for surface in MODEL_SURFACES {
                #expect(snapshot.preferences[surface]?.model == snapshot.preferences["chat"]?.model,
                        "@\(surface)")
                #expect(snapshot.activeProviders[surface] == route, "@\(surface)")
            }
        }
    }

    /// The captions a person actually reads under each row.
    @Test func groupCaptionsNameEveryActivityTheyGovern() {
        #expect(ProviderSurfaceGroups.chat.caption == "Chat, iPhone, Telegram and Slack")
        #expect(ProviderSurfaceGroups.work.caption
            == "Desk, Task execution, Independent tasks, Coordinated tasks, Skill practice, Background check-ins and Diagnostics")
        #expect(ProviderSurfaceGroups.mind.caption
            == "Memory, Dreams, REM, Reflection, Conversation summaries, Learning and Creative exploration")
    }
}
