import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Fluid Context surface wiring")
struct FluidContextSurfaceWiringTests {
    @Test func productionChatSurfaceProfilesCentralizeToolBoundaries() {
        #expect(NativeAgentAppChatSurfaceProfile.allCases == [
            .mac, .slack, .telegram, .ios, .bridge,
        ])
        #expect(NativeAgentAppChatSurfaceProfile.mac.includesEvolutionBridge)
        #expect(NativeAgentAppChatSurfaceProfile.bridge.includesEvolutionBridge)
        #expect(!NativeAgentAppChatSurfaceProfile.slack.includesEvolutionBridge)
        #expect(!NativeAgentAppChatSurfaceProfile.telegram.includesEvolutionBridge)
        #expect(!NativeAgentAppChatSurfaceProfile.ios.includesEvolutionBridge)
        #expect(NativeAgentAppChatSurfaceProfile.bridge.deniesExternalMCP)
        #expect(!NativeAgentAppChatSurfaceProfile.mac.deniesExternalMCP)
        #expect(!NativeAgentAppChatSurfaceProfile.slack.deniesExternalMCP)
        #expect(!NativeAgentAppChatSurfaceProfile.telegram.deniesExternalMCP)
        #expect(!NativeAgentAppChatSurfaceProfile.ios.deniesExternalMCP)
    }

    @Test func everyAppOwnedCoreClientFactoryCallInjectsContextFlow() throws {
        let root = try AppSourceScraping.repositoryRoot()
        let sourcesRoot = root.appendingPathComponent("Sources/NativeAgentApp", isDirectory: true)
        let sourceURLs = try AppSourceScraping.swiftSourceURLs(under: sourcesRoot)

        let callSites = try sourceURLs.flatMap { url -> [(String, String)] in
            let source = try String(contentsOf: url, encoding: .utf8)
            return AppSourceScraping.executableCalls(named: "makeChatOrchestrationClient", in: source)
                .map { (url.lastPathComponent, $0) }
        }

        #expect(callSites.count == 3)
        #expect(Set(callSites.map(\.0)) == [
            "AppChatToolDispatcher.swift",
            "BackgroundLoopsAssembly+WorkshopExecution.swift",
            // The Workshop bounded session is a production chat client too —
            // it must pin the same ContextFlow generation (per-site assertion
            // below enforces the injection).
            "WorkshopSession.swift",
        ])
        for (file, call) in callSites {
            let injectsLiveContext = call.contains("contextFlow: NativeContextFlowRuntime.shared")
                || call.contains("contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil")
            #expect(
                injectsLiveContext,
                "\(file) constructs a production chat client without ContextTurnPreparing"
            )
            if file == "BackgroundLoopsAssembly+WorkshopExecution.swift" {
                #expect(call.contains("usesLiveAppBody ? NativeContextFlowRuntime.shared : nil"))
            }
        }
    }

    @Test func productionConversationSurfacesUseInjectedAssemblyPaths() throws {
        let macChat = try AppSourceScraping.appSource("NativeClient+ChatRuntime.swift")
        #expect(AppSourceScraping.executableCalls(named: "makeNativeAgentAppChatOrchestrationClient", in: macChat).isEmpty)
        #expect(macChat.contains("Self.residentMacChatClient"))
        let nativeClient = try AppSourceScraping.appSource("NativeClient.swift")
        #expect(nativeClient.contains("residentMacChatClient"))
        #expect(nativeClient.contains("profile: .mac"))

        let remoteSurfaces = try AppSourceScraping.appSource("BackgroundLoopsAssembly+ChatSurfaces.swift")
        let slack = try AppSourceScraping.functionBody(named: "makeSlackSocketModeLoopIfConfigured", in: remoteSurfaces)
        let telegram = try AppSourceScraping.functionBody(named: "makeTelegramPollLoopIfConfigured", in: remoteSurfaces)
        #expect(slack.contains("makeNativeAgentAppChatOrchestrationClient"))
        #expect(telegram.contains("makeNativeAgentAppChatOrchestrationClient"))
        #expect(AppSourceScraping.executableCalls(named: "makeNativeAgentAppChatOrchestrationClient", in: slack).count == 1)
        #expect(AppSourceScraping.executableCalls(named: "makeNativeAgentAppChatOrchestrationClient", in: telegram).count == 1)
        #expect(slack.contains("profile: .slack"))
        #expect(telegram.contains("profile: .telegram"))
        // Conversation shells must not pre-read a route that can become stale
        // before dispatch. The canonical chat facade owns executable admission.
        #expect(AppSourceScraping.occurrences(of: "checkedRoutingSnapshot()", in: slack) == 0)
        #expect(AppSourceScraping.occurrences(of: "checkedRoutingSnapshot()", in: telegram) == 0)
        #expect(slack.contains("model: \"\""))
        #expect(telegram.contains("model: \"\""))
        #expect(!slack.contains("computeModelPreferences()"))
        #expect(!slack.contains("activeProvidersForSurfaces()"))
        #expect(!telegram.contains("computeModelPreferences()"))
        #expect(!telegram.contains("activeProvidersForSurfaces()"))

        let iCloud = try AppSourceScraping.appSource("AppDelegate+ICloudRuntimeForwarding.swift")
        let iCloudForwarder = try AppSourceScraping.functionBody(named: "forwardToSwiftRuntime", in: iCloud)
        #expect(!iCloudForwarder.contains("makeNativeAgentAppChatOrchestrationClient"))
        #expect(iCloudForwarder.contains("residentIOSChatClient"))
        let appDelegate = try AppSourceScraping.appSource("NativeAgentApp.swift")
        #expect(appDelegate.contains("residentIOSChatClient"))
        #expect(appDelegate.contains("profile: .ios"))
        #expect(!iCloudForwarder.contains("checkedRoutingSnapshot()"))
        #expect(iCloudForwarder.contains("model: \"\""))

        let bridge = try AppSourceScraping.appSource("ClaudeBridge.swift")
        let bridgeMessage = try AppSourceScraping.functionBody(named: "handleMessage", in: bridge)
        #expect(!bridgeMessage.contains("SwiftNativeProviderRouting"))
        #expect(bridgeMessage.contains("model: \"\""))
        let bridgeClient = try AppSourceScraping.functionBody(named: "sharedChatClient", in: bridge)
        #expect(bridgeClient.contains("makeNativeAgentAppChatOrchestrationClient"))
        #expect(bridgeClient.contains("profile: .bridge"))
        let bridgeTools = try AppSourceScraping.functionBody(named: "sharedToolClient", in: bridge)
        #expect(bridgeTools.contains("makeNativeAgentBridgeToolDispatchClient"))
        #expect(!bridgeTools.contains("SwiftToolDispatcher("))

        let workshop = try AppSourceScraping.appSource("BackgroundLoopsAssembly+WorkshopExecution.swift")
        let workshopExecutor = try AppSourceScraping.functionBody(named: "makeWorkshopExecutor", in: workshop)
        #expect(workshopExecutor.contains("makeChatOrchestrationClient"))
        #expect(workshopExecutor.contains("contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil"))

        let workshopSession = try AppSourceScraping.appSource("WorkshopSession.swift")
        let productionTurn = try AppSourceScraping.functionBody(named: "productionTurnExecutor", in: workshopSession)
        #expect(productionTurn.contains("dataRoot == PersistenceCore.defaultDataRoot()"))
        #expect(productionTurn.contains("contextFlow: usesLiveAppBody ? NativeContextFlowRuntime.shared : nil"))
        #expect(workshopSession.contains("allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot()"))

        let githubRuntime = try AppSourceScraping.appSource("GitHubCommandRuntime.swift")
        let liveRuntime = try AppSourceScraping.functionBody(named: "live", in: githubRuntime)
        #expect(liveRuntime.contains("guard usesLiveAppBody else"))
        #expect(liveRuntime.contains("canonical app bridge unavailable for alternate data root"))
        #expect(liveRuntime.contains("canonical notification body unavailable for alternate data root"))

        let backgroundAssembly = try AppSourceScraping.appSource("BackgroundLoopsAssembly.swift")
        let sharedLLM = try AppSourceScraping.functionBody(named: "makeSharedLLMClient", in: backgroundAssembly)
        #expect(sharedLLM.contains("cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)"))
        #expect(sharedLLM.contains("lifecycleObserver: runtime"))
        #expect(sharedLLM.contains("dataRoot: dataRoot"))
        #expect(sharedLLM.contains("AlternateRootUnavailableBackgroundLLMClient"))
        let allLoops = try AppSourceScraping.functionBody(named: "assembleAllLoops", in: backgroundAssembly)
        #expect(allLoops.contains("let cognition = cognitionRuntime(for: dataRoot)"))
        #expect(allLoops.contains("makeCognitionMaintenanceLoop(runtime: cognition)"))
        #expect(allLoops.contains("makeCognitionReplayLoop(runtime: cognition)"))
        #expect(allLoops.contains("makeCognitionReflectionLoop(llm: llm, runtime: cognition)"))

        // Wave C move-only decomposition: observe() stays in the core runtime
        // file; the ingest pair lives in the +Organism extension file — the
        // kind-based wrapper delegates to ingestPreparedOrganismSignal (the
        // interoception seam), which owns the prewarm gate
        // (same actor, same behavior).
        let cognitionRuntimeCore = try AppSourceScraping.appSource("NativeCognitionRuntime.swift")
        let observe = try AppSourceScraping.functionBody(named: "observe", in: cognitionRuntimeCore)
        #expect(observe.contains("if usesLiveAppBody"))
        let cognitionRuntimeOrganism = try AppSourceScraping.appSource("NativeCognitionRuntime+Organism.swift")
        let somatic = try AppSourceScraping.functionBody(named: "ingestPreparedOrganismSignal", in: cognitionRuntimeOrganism)
        #expect(somatic.contains("prewarmContext && usesLiveAppBody"))

        let workshopExecution = try AppSourceScraping.appSource("BackgroundLoopsAssembly+WorkshopExecution.swift")
        let executor = try AppSourceScraping.functionBody(named: "makeWorkshopExecutor", in: workshopExecution)
        #expect(executor.contains("cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)"))
        #expect(!executor.contains("NativeCognitionRuntime.shared"))
        let workshopPumpSource = try AppSourceScraping.appSource("BackgroundLoopsAssembly+Workshop.swift")
        let pump = try AppSourceScraping.functionBody(named: "makeWorkshopPump", in: workshopPumpSource)
        #expect(pump.contains("cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)"))
        #expect(!pump.contains("NativeCognitionRuntime.shared"))

        let dreamAssembly = try AppSourceScraping.appSource("BackgroundLoopsAssembly+DreamsMemory.swift")
        let memoryDelta = try AppSourceScraping.functionBody(named: "makeDreamMemoryDeltaProvider", in: dreamAssembly)
        #expect(memoryDelta.contains("SwiftNativeMemoryV2.resolvedOwner("))
        #expect(memoryDelta.contains("alternateRootEmbedder: MockEmbeddingProvider()"))
        #expect(memoryDelta.contains("memory.listMemory"))
        let feltSummary = try AppSourceScraping.functionBody(named: "makeDreamFeltSummaryProvider", in: dreamAssembly)
        #expect(feltSummary.contains("cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)"))
    }

    // Source-scraping helpers (repositoryRoot / swiftSources / functionBody /
    // executableCalls / balancedEnd / appSource / occurrences) live in the
    // shared AppSourceScraping enum.
}
