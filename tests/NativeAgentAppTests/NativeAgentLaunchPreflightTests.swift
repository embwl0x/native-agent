import Testing
@testable import NativeAgentApp

@Suite("NativeAgent launch preflight")
struct NativeAgentLaunchPreflightTests {
    @Test("public root quarantine precedes every process-wide state owner")
    func publicRootQuarantineRunsBeforeSwiftUIConstruction() throws {
        let appMain = try AppSourceScraping.appSource("NativeAgentApp.swift")
        let mainBody = try AppSourceScraping.functionBody(named: "main", in: appMain)
        let claim = try #require(mainBody.range(of: "AppDelegate.claimSingleAppInstance()"))
        let prepare = try #require(
            mainBody.range(of: "NativeAgentPaths.preparePublicReleaseDataRootIfNeeded()")
        )
        let construct = try #require(mainBody.range(of: "NativeAgentApp.main()"))

        #expect(claim.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < construct.lowerBound)

        let delegateLaunch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let launchBody = try AppSourceScraping.functionBody(
            named: "applicationDidFinishLaunching",
            in: delegateLaunch
        )
        #expect(!launchBody.contains("claimSingleAppInstance"))
        #expect(!launchBody.contains("preparePublicReleaseDataRootIfNeeded"))
    }

    @Test("healthy launch does not rebuild the complete memory graph")
    func healthyLaunchUsesAdditiveKnowledgeGraphRepair() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let launchBody = try AppSourceScraping.functionBody(
            named: "applicationDidFinishLaunching",
            in: launch
        )
        let migrationGate = try #require(
            launchBody.range(of: "if !report.skippedAlreadyMigrated")
        )
        let fullRebuild = try #require(
            launchBody.range(of: "reconcileKnowledgeGraphProjection()")
        )
        #expect(migrationGate.lowerBound < fullRebuild.lowerBound)
        #expect(AppSourceScraping.occurrences(
            of: "reconcileKnowledgeGraphProjection()",
            in: launchBody
        ) == 1)

        let sharedURL = try AppSourceScraping.repositoryRoot()
            .appendingPathComponent(
                "Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+SharedInstance.swift"
            )
        let shared = try String(contentsOf: sharedURL, encoding: .utf8)
        let startup = try #require(shared.range(of: "Healthy launches only repair rows"))
        let additive = try #require(shared.range(
            of: "kgIndexer.backfillMissingMemoryIndexRows()",
            range: startup.lowerBound..<shared.endIndex
        ))
        #expect(startup.lowerBound < additive.lowerBound)
    }

    @Test("Codex cannot launch the dist GUI executable")
    func suppressesCodexDistLaunch() {
        #expect(NativeAgentLaunchPreflight.shouldSuppressGUIStart(
            environment: ["CODEX_SHELL": "1"],
            executablePath: "/Users/example/Projects/NativeAgent/dist/NativeAgent.app/Contents/MacOS/NativeAgentApp"
        ))
    }

    @Test("installed app remains launchable from installer fallback")
    func allowsInstalledAppFromCodexShell() {
        #expect(!NativeAgentLaunchPreflight.shouldSuppressGUIStart(
            environment: ["CODEX_SHELL": "1"],
            executablePath: "/Users/example/Applications/NativeAgent.app/Contents/MacOS/NativeAgentApp"
        ))
    }

    @Test("normal host development launch remains available")
    func allowsHostDistLaunch() {
        #expect(!NativeAgentLaunchPreflight.shouldSuppressGUIStart(
            environment: [:],
            executablePath: "/Users/example/Projects/NativeAgent/dist/NativeAgent.app/Contents/MacOS/NativeAgentApp"
        ))
    }

    @Test("lookalike paths do not trigger the guard")
    func ignoresLookalikePaths() {
        #expect(!NativeAgentLaunchPreflight.shouldSuppressGUIStart(
            environment: ["CODEX_SHELL": "1"],
            executablePath: "/tmp/dist/Other.app/Contents/MacOS/NativeAgentApp"
        ))
    }
}
