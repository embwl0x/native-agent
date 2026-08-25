import ChatOrchestration

// Fence app.background — process lifecycle wiring guards.
//
// Ledger rows closed here:
//   app.background.osBackgroundActivity
//   app.background.lifecycle.envSkipLoginItem
//   app.background.lifecycle.registerLoginItem / lifecycle.loginItem (guard half)
//   app.background.lifecycle.stayAliveAfterLastWindow
//   app.background.lifecycle.sigpipeIgnore
//   app.background.lifecycle.terminationDrain / lifecycle.applicationWillTerminate
//   app.background.lifecycle.sleepWakeObservers
//   app.background.selfRestart.uiControls
//   app.background.manager.wakeAutoAssembles
//
// These are LIFECYCLE/LEAK surfaces: none of them produce a receipt, an error,
// or a UI change when they regress. A dropped `removeObserver` leaks an observer
// per restart; a chained DispatchGroup entry starves a drain; a task identifier
// that maps to no loop `continue`s past its own schedule and the weekly work
// simply never runs. Where the runtime state is unreachable from a test process
// (AppKit delegates, NSBackgroundActivityScheduler, SMAppService), the guard is
// a structural scrape of the one call site — which is exactly what bites when
// someone edits it.

import Foundation
import Testing
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private struct WiringStubLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "{}" }
}

private struct WiringProbeLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval = 86_400
    func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
}

private actor AssembleCounter {
    private(set) var calls = 0
    func bump() { calls += 1 }
}

private final class RestartOwnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var spawnCount = 0
    private var terminationCount = 0

    func recordSpawn() {
        lock.lock()
        spawnCount += 1
        lock.unlock()
    }

    func recordTermination() {
        lock.lock()
        terminationCount += 1
        lock.unlock()
    }

    func snapshot() -> (spawns: Int, terminations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (spawnCount, terminationCount)
    }
}

@Suite("app.background lifecycle wiring")
struct BackgroundLifecycleWiringContractTests {

    // MARK: - NSBackgroundActivityScheduler registration

    @Test("every background-activity identifier maps to a real loop id and a real interval")
    func backgroundActivityTablesAgreeAndCoverRealLoops() throws {
        let ids = AppDelegate.bgTaskIdentifiers
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3, "duplicate identifiers silently overwrite each other's schedule")

        // The registration loop `continue`s when EITHER lookup misses — a
        // silent "this weekly job never runs again". The three tables must
        // therefore carry identical key sets.
        let source = try AppSourceScraping.appSource("AppDelegate+BackgroundTasks.swift")
        func suffixes(inVarNamed name: String) throws -> Set<String> {
            guard let decl = source.range(of: "var \(name): ") else {
                throw AppSourceScraping.ScrapeError("missing \(name)")
            }
            guard let open = source[decl.upperBound...].firstIndex(of: "{"),
                  let close = AppSourceScraping.balancedEnd(
                    in: source, startingAt: open, opening: "{", closing: "}")
            else { throw AppSourceScraping.ScrapeError("unbalanced \(name)") }
            let body = String(source[open...close])
            var found: Set<String> = []
            var cursor = body.startIndex
            let needle = "backgroundTaskIdentifier(\""
            while let match = body.range(of: needle, range: cursor..<body.endIndex) {
                cursor = match.upperBound
                guard let end = body[cursor...].firstIndex(of: "\"") else { break }
                found.insert(String(body[cursor..<end]))
            }
            return found
        }

        let declared = try suffixes(inVarNamed: "bgTaskIdentifiers")
        let loops = try suffixes(inVarNamed: "backgroundLoopIDsByTaskIdentifier")
        let intervals = try suffixes(inVarNamed: "backgroundTaskIntervalsByIdentifier")
        #expect(declared == ["rem_cycle", "memory_consolidation", "self_improvement_sweep"])
        #expect(loops == declared, "a scheduled identifier with no loop mapping silently never ticks")
        #expect(intervals == declared, "a scheduled identifier with no interval silently never ticks")

        // The retired dream activity must be invalidated, never registered —
        // it could otherwise wake independently of the 03:30 scheduler job.
        #expect(!declared.contains("dream_cycle"))
        #expect(source.contains("NSBackgroundActivityScheduler(identifier: retiredDreamTaskIdentifier).invalidate()"))

        // And the mapped loop ids are the ids the real loops actually publish.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BgActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let published: Set<String> = [
            BackgroundLoopsAssembly.makeREMCycleLoop(dataRoot: tmp, llm: WiringStubLLM()).loopId,
            BackgroundLoopsAssembly.makeMemoryConsolidationLoop(dataRoot: tmp).loopId,
            BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop(dataRoot: tmp, llm: WiringStubLLM()).loopId,
        ]
        #expect(published == loops,
                "the OS-scheduled ids drifted from the ids the loops publish: \(published) vs \(loops)")
    }

    // MARK: - login item

    @Test("login-item registration is skipped only by the exact string \"1\"")
    func loginItemSkipFlagIsExactMatch() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        // An `!= "1"` guard is the whole contract: "true"/"0"/"" must all still
        // register. A loosened truthy parse would silently stop auto-launch for
        // anyone with the var set to anything at all.
        #expect(launch.contains(
            "if ProcessInfo.processInfo.environment[\"NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER\"] != \"1\" {"))
        #expect(!launch.contains("NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER\"]?.lowercased()"))
        // Exactly one gate, one call site.
        #expect(AppSourceScraping.occurrences(
            of: "NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER", in: launch) == 1)
        #expect(AppSourceScraping.occurrences(
            of: "AppDelegate.registerLoginItemIfNeeded()", in: launch) == 1)
    }

    // EVAL FENCE: app.background / app.background.lifecycle.loginItem
    @Test("login-item registration admits only real global or user Applications descendants")
    func loginItemRegistrationIsInstallLocationGated() throws {
        let home = "/Users/eval"
        #expect(LoginItemInstallLocation.allows(
            bundlePath: "/Applications/NativeAgent.app",
            homeDirectory: home
        ))
        #expect(LoginItemInstallLocation.allows(
            bundlePath: "/Users/eval/Applications/NativeAgent.app",
            homeDirectory: home
        ))
        #expect(!LoginItemInstallLocation.allows(
            bundlePath: "/Users/eval/Projects/NativeAgent/dist/NativeAgent.app",
            homeDirectory: home
        ))
        #expect(!LoginItemInstallLocation.allows(
            bundlePath: "/Applications-old/NativeAgent.app",
            homeDirectory: home
        ))
        #expect(!LoginItemInstallLocation.allows(
            bundlePath: "/Users/eval/Applications-old/NativeAgent.app",
            homeDirectory: home
        ))

        // The registration lifecycle must still delegate to the canonical guard
        // before reaching SMAppService.
        let source = try AppSourceScraping.appSource("AppDelegate+ProcessLifecycle.swift")
        let body = try AppSourceScraping.functionBody(named: "registerLoginItemIfNeeded", in: source)
        #expect(body.contains("LoginItemInstallLocation.allows(bundlePath: bundlePath)"))
        #expect(body.contains("SMAppService.mainApp"))
        #expect(body.contains(".register()"))
        // The guard runs BEFORE the register call.
        guard let guardIndex = body.range(of: "LoginItemInstallLocation.allows")?.lowerBound,
              let registerIndex = body.range(of: ".register()")?.lowerBound else {
            Issue.record("could not locate the guard and the register call")
            return
        }
        #expect(guardIndex < registerIndex, "the install-location guard must precede register()")
    }

    // MARK: - stay alive / SIGPIPE

    @Test("closing the last window never terminates the background app")
    func stayAliveAfterLastWindowClosed() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let body = try AppSourceScraping.functionBody(
            named: "applicationShouldTerminateAfterLastWindowClosed", in: launch)
        let statements = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && $0 != "{" && $0 != "}" }
        // One switch, one answer. `true` here kills every background loop the
        // moment the user closes the window — and nothing reports it.
        #expect(statements == ["return false"], "unexpected body: \(statements)")
    }

    @Test("SIGPIPE is ignored in App.init before anything can spawn a subprocess")
    func sigpipeIsIgnoredAtTheEarliestHook() throws {
        // Without SIG_IGN a write to a dead MCP/builder child's stdin kills the
        // WHOLE app — no crash report the user connects to anything.
        let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
        guard let signalIndex = app.range(of: "signal(SIGPIPE, SIG_IGN)")?.lowerBound else {
            Issue.record("App.init no longer ignores SIGPIPE")
            return
        }
        guard let initIndex = app.range(of: "\n    init() {")?.lowerBound,
              let modelIndex = app.range(of: "let appModel = AppModel()")?.lowerBound else {
            Issue.record("could not locate App.init / AppModel construction")
            return
        }
        #expect(initIndex < signalIndex, "SIGPIPE must be disarmed inside App.init")
        #expect(signalIndex < modelIndex,
                "SIGPIPE must be disarmed before anything that can spawn a subprocess is built")
        #expect(AppSourceScraping.occurrences(of: "signal(SIGPIPE, SIG_IGN)", in: app) == 1)
    }

    // MARK: - termination drain

    @Test("every termination drain gets its own group entry and the wait is bounded")
    func terminationDrainEntriesArePairedAndBounded() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let body = try AppSourceScraping.functionBody(named: "applicationWillTerminate", in: launch)

        let enters = AppSourceScraping.occurrences(of: "group.enter()", in: body)
        let leaves = AppSourceScraping.occurrences(of: "group.leave()", in: body)
        #expect(enters > 0)
        #expect(enters == leaves,
                "unbalanced drain bookkeeping: \(enters) enter() vs \(leaves) leave() — quit hangs or drops work")

        // Each enter() must be followed by its own detached/Task closure that
        // ends in leave(): a chained pair (enter, enter, leave, leave) serializes
        // the drains under one budget and starves the later ones.
        var cursor = body.startIndex
        var blocks = 0
        while let enter = body.range(of: "group.enter()", range: cursor..<body.endIndex) {
            guard let nextEnter = body.range(of: "group.enter()", range: enter.upperBound..<body.endIndex)
            else {
                let tail = body[enter.upperBound...]
                #expect(AppSourceScraping.occurrences(of: "group.leave()", in: String(tail)) == 1)
                blocks += 1
                break
            }
            let between = String(body[enter.upperBound..<nextEnter.lowerBound])
            #expect(AppSourceScraping.occurrences(of: "group.leave()", in: between) == 1,
                    "drain block \(blocks) does not close its own group entry")
            blocks += 1
            cursor = enter.upperBound
        }
        #expect(blocks == enters)

        // The total wait is bounded — an unbounded group.wait() at quit is an
        // unkillable app.
        #expect(body.contains("group.wait(timeout: .now() + 3.0)"))
        #expect(!body.contains("group.wait()"))
        // The one drain that can wedge on SQLite/embedder work is bounded BELOW
        // the budget so it cannot consume the whole quit window.
        #expect(body.contains("waitForExecutionMemoryWrites(timeout: 2.5)"))
    }

    @Test("sleep/wake observers are registered in pairs and removed at termination")
    func sleepWakeObserversAreRemovedOnTerminate() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let didFinish = try AppSourceScraping.functionBody(
            named: "applicationDidFinishLaunching", in: launch)
        #expect(didFinish.contains("NSWorkspace.willSleepNotification"))
        #expect(didFinish.contains("NSWorkspace.didWakeNotification"))
        #expect(AppSourceScraping.occurrences(
            of: "NSWorkspace.shared.notificationCenter.addObserver", in: didFinish) == 2)

        let terminate = try AppSourceScraping.functionBody(named: "applicationWillTerminate", in: launch)
        // Without this the observers outlive every in-process restart — an
        // observer leak that only shows up as duplicated wake work.
        #expect(terminate.contains("NSWorkspace.shared.notificationCenter.removeObserver(self)"))
    }

    // MARK: - restart entry points

    @Test("agent restart routes share the coordinator's single relaunch owner")
    func agentRestartRoutesUseOneCoordinatorOwner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restart-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = RestartOwnerProbe()
        let coordinator = AppRestartCoordinator(
            dataRoot: root,
            currentPID: 4242,
            spawnRelauncher: { _ in probe.recordSpawn() },
            scheduleTerminate: { _ in probe.recordTermination() }
        )
        let telegram = TelegramRestartBridge(
            dataRoot: root,
            deferredRestart: { reason in
                await coordinator.requestRestartDeferringTerminate(
                    reason: reason,
                    source: "telegram:/restart"
                )
            }
        )

        let telegramOutcome = await telegram.requestRestart(reason: "poller wedged")
        let armTerminate = try #require(telegramOutcome.armTerminate)
        #expect(probe.snapshot() == (spawns: 1, terminations: 0))
        armTerminate()
        #expect(probe.snapshot() == (spawns: 1, terminations: 1))

        // A second agent surface reaches the same cooldown-bearing owner, so
        // it cannot create an independent relaunch lifecycle.
        _ = await coordinator.requestRestart(reason: "chat route", source: "chat:mac")
        #expect(probe.snapshot() == (spawns: 1, terminations: 1))
    }

    // MARK: - wake auto-assembly

    @Test("an OS wake for an unregistered loop assembles the manifest and reports a distinguishable outcome")
    func wakeForUnknownLoopDoesNotSilentlySucceed() async {
        // NSBackgroundActivityScheduler hands `runTickIfDue(loopId:)` an id from
        // its own table. If that id is not in the manifest the facade still
        // starts everything — and the OS gets a completion. The dangerous shape
        // is a `.completed` for work that never ran.
        let core = BackgroundLoops.BackgroundLoopsManager()
        let counter = AssembleCounter()
        let facade = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: {
                Task { await counter.bump() }
                return [WiringProbeLoop(loopId: "wake_probe_loop")]
            },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )

        let unknown = await facade.runTickIfDue(loopId: "no_such_loop")
        if case .completed = unknown {
            Issue.record("a wake for an unregistered loop reported .completed — the OS is told work happened that never ran")
        }
        // The side effect IS the documented behavior: the manifest gets started.
        #expect(await core.registered() == ["wake_probe_loop"])

        // A wake for a registered id still runs it.
        let known = await facade.runTickIfDue(loopId: "wake_probe_loop")
        if case .failed(let error) = known {
            Issue.record("a wake for a registered loop failed: \(error)")
        }
        await facade.stop()
    }
}
