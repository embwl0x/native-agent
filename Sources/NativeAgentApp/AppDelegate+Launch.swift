import Foundation
import AppKit
import NativeAgentCore
import WorkshopExecution
import SelfImprovement
import ChatOrchestration
import BackgroundLoops
import MemoryV2
import PersistenceCore
import PersonaEngine
import MCPDispatcher
import GitHubConnector
import Browser
import OSLog

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let workspace = try NativeAgentWorkspaceRoot.prepare(dataRoot: NativeAgentPaths.dataRoot)
            NSLog("[workspace] canonical work root ready at %@", workspace.path)
        } catch {
            // Chat and private state can still start; file/build tools will
            // return their normal checked failure if the directory remains
            // unavailable. Do not replace a recoverable workspace error with a
            // second app-lifecycle gate.
            NSLog("[workspace] canonical work root unavailable: %@", error.localizedDescription)
        }
        do {
            let report = try WorkshopStorageMigrator.migrateIfNeeded(
                dataRoot: NativeAgentPaths.dataRoot
            )
            if report.didMigrate {
                NSLog(
                    "[workshop-migration] absorbed legacy Missions storage: moved=%d deduplicated=%d conflicts=%d archive=%@ receipt=%@",
                    report.moved.count,
                    report.deduplicated.count,
                    report.conflictsPreservedInArchive.count,
                    report.archiveRelativePath ?? "none",
                    report.receiptRelativePath ?? "none"
                )
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Workshop storage migration failed"
            alert.informativeText = "NativeAgent stopped before starting background work so no task state is lost. \(error.localizedDescription)"
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.nativeagent.app", category: "github-credential")
            await GitHubCommandRuntime.shared.replayResidentStateAtLaunch()
            do {
                let configured = try await GitHubCredentialStore.shared.reconcileAtLaunch(
                    dataRoot: NativeAgentPaths.dataRoot
                )
                if configured {
                    logger.info("GitHub credential Keychain reconciliation complete")
                    await GitHubCommandRuntime.shared.recoverAtLaunch()
                }
            } catch {
                logger.error(
                    "GitHub credential Keychain reconciliation failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(contextFlowWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(contextFlowDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        Task.detached(priority: .utility) {
            await NativeContextFlowRuntime.shared.start()
        }

        // PATCH-2026-05-07: use .regular activation policy
        // so the dock icon stays visible. The
        // applicationShouldTerminateAfterLastWindowClosed = false hook still
        // keeps the app and background runtime alive when the user closes the
        // main window, so background work (dream cycle, consolidation,
        // proactive triggers) keeps running.
        NSApp.setActivationPolicy(.regular)
        NativeAgentNotifications.requestAuthorization()

        // Process-wide app services and route retention must not depend on the
        // main SwiftUI Window appearing. The coordinator is configured from
        // NativeAgentApp.init with the shared AppModel, then started exactly
        // once from this guaranteed application lifecycle callback.
        NativeAgentAppCoordinator.shared.applicationDidFinishLaunching()

        // MemoryV2 Path C: one-shot JSON → SQLite migration. Idempotent;
        // a sentinel file under <dataRoot>/memory skips subsequent launches.
        // Detached so first-launch I/O doesn't gate UI ready.
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.nativeagent.app", category: "memory-migration")
            let report = await MemoryV2Migrator().migrate()
            if report.skippedAlreadyMigrated {
                logger.info("MemoryV2 migration: already complete; skipped")
            } else {
                logger.info(
                    "MemoryV2 migration: memories=\(report.memoriesImported, privacy: .public) proposals=\(report.proposalsImported, privacy: .public) tombstones=\(report.tombstonesImported, privacy: .public) errors=\(report.errors.count, privacy: .public)"
                )
                for err in report.errors.prefix(5) {
                    logger.error("MemoryV2 migration error: \(err, privacy: .public)")
                }
            }
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "memory-v2",
                stableID: "migration",
                operation: .reconcile,
                reason: "memory_migration_finished"
            ))
            await DerivedStateInvalidationCenter.shared.flush()
        }

        // Swift-native cutover/fin-integration: register background activity entries
        // BEFORE NSApplication finishes launching.
        // Per Apple's docs, BGTaskScheduler.register(...) must be called from
        // applicationDidFinishLaunching (or earlier) — registering it from
        // a Task body races the first system wake on cold launch.
        Self.registerBackgroundTaskHandlers()

        // Make the mission planner TOOL-AWARE for EVERY path, incl. the
        // autonomous trigger scheduler (which builds its runner via the core
        // makeWorkshopRunner and so can't be wired per-call-site). Configured
        // SYNCHRONOUSLY here, before any detached loop/trigger task spawns, so
        // a mission Agent fires on her own plans real tools — not synthesis-only
        // (2026-06-15, the user: missions do everything, including unattended).
        WorkshopExecution.WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())

        // restart_app / Telegram /restart (2026-06-10): inject the AppKit
        // terminate hook into the shared restart coordinator. The module
        // can't import AppKit, so termination is an app-layer closure —
        // same injection pattern as the other capability closures the
        // loops assembly wires. Until this runs, restart requests refuse
        // honestly with `restart_unavailable` (fail closed, never a silent
        // half-restart). The grace delay lets the in-flight turn persist
        // and the reply reach its surface before the app exits.
        Task.detached(priority: .utility) {
            await AppRestartCoordinator.shared.configure(
                scheduleTerminate: { graceSeconds in
                    DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
                        NSLog("[restart_app] grace elapsed — terminating for relaunch")
                        NSApp.terminate(nil)
                    }
                }
            )
        }

        // HOTFIX 2026-06-03: every subsystem bring-up gets its OWN detached
        // Task so a wedge in any one (SQLite file-lock contention, slow
        // iCloud daemon, locked Spotlight index, etc.) cannot cascade into a
        // launch freeze of the others. Pre-hotfix this was ONE Task with
        // five `await`s; a single SQLite open block stalled all five. Each
        // subsystem is now independent; the launch task returns immediately.
        Task.detached(priority: .utility) {
            // Skills-recall rework (2026-07-03): reconcile skill-pointer
            // memory rows against the bodies on disk. Lives HERE and not in
            // the window .task — that block only fires when the main window
            // appears, and the app cold-starts menu-bar-only (the exact trap
            // the ClaudeBridge comment in NativeAgentApp.swift records).
            await syncSkillPointerIndex()
            await reconcileMemoryEmbeddingEpochAtLaunch()
        }
        Task.detached(priority: .utility) {
            await NativeCognitionRuntime.shared.bootstrap()
        }
        Task.detached(priority: .utility) {
            await MemorySpotlightBootstrap.shared.reindexAll()
        }
        Task.detached(priority: .utility) {
            // NativeAgentApp owns composition; Core owns process lifecycle,
            // execution, and status for the injected manifest.
            // Prime GitHub's semantic baseline before its refresh loop can
            // publish. This closes the launch race without replaying old work
            // as fresh resident physiology.
            await GitHubCommandRuntime.shared.replayResidentStateAtLaunch()
            let loops = BackgroundLoopsAssembly.assembleAllLoops()
            await BackgroundLoopsManager.shared.start(loops: loops)
            // CRASH RECONCILIATION for the Workshop→memory lane (gpt-5.5
            // review BLOCKING 1, 2026-08-02). Mission-memory writes are handed
            // off to a detached queue, so a crash — or a kill inside the 3s
            // termination budget — can leave a terminal `mission.json` on disk
            // with no memory behind it. `applicationWillTerminate` drains the
            // queue for a CLEAN quit; this repairs the unclean one, bounded to
            // recent executions (see the method's own doc for the window).
            //
            // Sequenced INSIDE this task, after `start(loops:)`, because
            // WorkshopExecutorRef is configured by the loop assembly — a
            // sibling Task.detached would race it and find the ref nil.
            if let executor = WorkshopExecutorRef.shared.current() {
                _ = await executor.reconcileMissedMissionMemories()
            }
        }
        Task.detached(priority: .utility) {
            // Reconcile historical Desk feeds written before parent/child
            // terminal-state invariants existed. The store repairs by appending
            // ordinary set_status ops under its canonical flock; it never
            // rewrites the event log or hot-edits desk_state.json.
            do {
                _ = try await SwiftNativeDeskStore(
                    dataRoot: PersistenceCore.defaultDataRoot()
                ).reconcileTerminalParentsWithNonTerminalDescendants()
            } catch {
                FileHandle.standardError.write(
                    Data("Desk hierarchy reconciliation failed: \(error)\n".utf8)
                )
            }
        }
        Task.detached(priority: .utility) {
            // UserMDGenerator opens the SQLite db; isolated so a file-lock
            // contention (e.g. another instance holding the GRDB pool) can't
            // stall the rest of bring-up.
            if let gen = UserMDGenerator.shared {
                // Pre-onboarding this throws `onboardingIncomplete` and writes
                // nothing (fix-blank-install-onboarding, 2026-08-02). It used
                // to create the persona dir and an empty USER.md on a blank
                // machine, which satisfied onboarding's own identity-anchor
                // check and hid the wizard depending on who won the launch
                // race. The gate lives in the generator, so EVERY caller —
                // launch, memory-insert pokes, consolidation — is covered and
                // the outcome no longer depends on task ordering.
                _ = try? await gen.regenerate()
                if let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() {
                    await bridge.underlyingStorage().attachUserMDGenerator(gen)
                }
            }
        }
        Task.detached(priority: .utility) {
            await AdaptiveMemoryPromoter.shared.configure(
                memory: SwiftNativeMemoryV2.shared,
                extractor: SemanticAdaptiveFactExtractor()
            )
        }
        Task.detached(priority: .utility) {
            // U3 wave-1 item 3: stage the one-shot memory-repair approval
            // cards (truncated daemon-era rows + legacy note duplicate purge)
            // if the wounds still exist and no card was staged before.
            // Staging only — NOTHING mutates the memory store until the
            // card is explicitly approved (resolveApproval → memory.repair
            // executor). Idempotent across launches via stamp files.
            //
            // Review blocker fix (2026-06-10): reconcile FIRST — a crash
            // between resolve-persist and the repair executor leaves a
            // resolved+approved record whose repair never applied, and the
            // staging stamp would dead-end it forever. The reconciliation
            // runs the idempotent executor for any resolved memory.repair
            // record lacking an execution annotation (and, for canceled
            // ones, clears the stamp so stageIfNeeded below re-stages).
            await NativeClient.reconcileUnappliedMemoryRepairs()
            await MemoryRepairOneShot.stageIfNeeded(dataRoot: PersistenceCore.defaultDataRoot())
            // U3 wave-2: same reconcile-then-stage pattern for the kind
            // backfill (item 5), and the consolidation-swap reconcile
            // (item 7) — re-drives approved-unexecuted swaps, detects
            // already-applied by fingerprint, cleans denied/orphaned
            // candidate stores. All approval-gated; nothing here mutates
            // the memory store without an approved card.
            await NativeClient.reconcileUnappliedKindBackfills()
            await NativeClient.stageKindBackfillIfNeeded()
            _ = await MemoryConsolidationGate.reconcile(
                dataRoot: PersistenceCore.defaultDataRoot())
            // U5 W-A item 3 (2026-06-11): generic resolve→execute crash-
            // window reconcile for the four kinds that lacked launch
            // coverage (rem.proposal, mission.step, self_improvement.apply,
            // browser.open_url). Re-fires the SAME executors resolveApproval
            // runs, keyed on "resolved + no executedAction annotation";
            // per-kind idempotency hooks (REM status-flip no-op, mission
            // in-lock staleApproval guard, approved-only self-improvement,
            // browser runs.json terminal-state cap) keep re-runs from
            // double-executing side effects.
            // Browser Core owns restart recovery for any navigation whose
            // persisted operation deadline elapsed while the app was down.
            // Repair before approval reconciliation so a stranded effect is
            // recorded outcome-unknown/failed and is never reopened merely to
            // heal an approval annotation.
            do {
                _ = try await SwiftNativeBrowserClient.defaultClient()
                    .executeBrowserOperation(.recoverStrandedRunning)
            } catch {
                NSLog("[browser] restart recovery failed: %@", String(describing: error))
            }
            await NativeClient.reconcileUnappliedApprovalExecutions()
            // Terminal-event reconciliation normally stages this exact card.
            // Launch repair closes the safe crash/restart gap without a poll:
            // if enough canonical procedure receipts already exist, stage the
            // same local-only activation review once.
            await WorkshopProcedureExactActivationCoordinator
                .reconcileLocalFileCopyIfQualified()
            // U2b wave 2: self-evolution lane, in dependency order —
            // (1) post-install verify FIRST: an in-flight install's
            //     pending_verify must reach its verdict (verified card /
            //     auto-revert / wait) before anything re-drives executors;
            // (2) crash-window reconcile: resolved self_evolution.apply
            //     records lacking an executedAction annotation re-run the
            //     idempotent executor (promote is marker-idempotent, the
            //     install leg heals on already-staged state, and the
            //     systemRebuild gate is re-checked — with the per-action
            //     flag off the executor stops at the annotated "awaiting
            //     systemRebuild.enabled" boundary, never the installer);
            // (3) staging: GREEN candidates become explicit-human-only
            //     approval cards (risk pinned critical; no auto-approve
            //     path exists for this action).
            let evolutionDeps = NativeClient.SelfEvolutionDeps.production()
            await NativeClient.runEvolutionVerifyAtLaunch(deps: evolutionDeps)
            await NativeClient.reconcileUnappliedSelfEvolution(deps: evolutionDeps)
            await BackgroundLoopsAssembly.stageEvolutionApprovals()
        }

        // PATCH-2026-06-17 dream-single-owner: dream cadence is owned solely
        // by TriggerScheduler's `nativeagent-nightly-dream` calendar job.
        // BackgroundLoopsManager and NSBackgroundActivityScheduler must not
        // register an unattended dream loop.

        // PATCH-2026-05-06: wkwebview-browser Start browser IPC server, preferring port 8766.
        Task { @MainActor in
            BrowserWindowController.shared.startIPCServer()
        }
        // PATCH-2026-05-07: mac-control-bridge Start Mac Control bridge, preferring
        // 8770, so local mac-control calls execute under NativeAgent.app's bundle
        // identity (TCC attributes Automation/Accessibility/etc. to NativeAgent).
        // PATCH-2026-05-07: bridge-off-main Start on a background queue so
        // we don't compete with iCloudBridge.setup()'s synchronous-but-slow
        // ubiquity container query for MainActor time.
        DispatchQueue.global(qos: .userInitiated).async {
            MacControlBridge.shared.start()
        }
        // ClaudeBridge: localhost HTTP on 8771 so Claude (Claude Code
        // CLI) can query Agent's state, fire chat turns, and run tools
        // without UI click-through. Sibling of MacControlBridge — started
        // in the SAME lifecycle hook so menu-bar/background launches
        // (which never show the main window and never fire SwiftUI .task
        // modifiers) still bring the bridge up. (Previously wired in
        // MainWindowContent's .task — silently never fired.) Synchronous
        // DispatchQueue dispatch (not Task.detached) so the actor isolation
        // can't defer it past application launch finish — mirrors
        // MacControlBridge above.
        NSLog("[claude-bootstrap] dispatching ClaudeBridge.startServer on dispatch queue")
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeBridge.shared.startSyncForBootstrap()
        }
        // PATCH-2026-05-07: icloud-bridge start iCloud bridge and wire iOS→Swift runtime forwarding
        Task { @MainActor in
            iCloudBridge.shared.setup()
            iCloudBridge.shared.observeIncomingMessages { msg in
                // Forward iOS message to the in-process Swift chat runtime.
                // iCloudBridge only archives the source file after this returns true.
                await AppDelegate.forwardToSwiftRuntime(msg)
            }
        }
        // AUTO-BOOTSTRAP: publish pairing material to iCloud KVS so iOS can
        // pair automatically without QR scans or manual key entry.
        // PairingSecretManager.loadOrGenerateSecret() is the single source of truth
        // for the HMAC key (same secret MacSyncEngine and iCloudBridge use for signing).
        // Run off-main so file I/O + KVS write don't compete with UI setup.
        Task.detached(priority: .userInitiated) {
            await PairingSecretManager.publishMaterialToKVS()
        }

        // PATCH-2026-05-07: app-owned runtime Auto-register for login start so
        // the menu-bar app is always there. Idempotent — calling register()
        // when already enabled is a no-op.
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER"] != "1" {
            Task.detached(priority: .background) {
                await AppDelegate.registerLoginItemIfNeeded()
            }
        }

    }

    // PATCH-2026-05-07: app-owned runtime Don't quit when the user closes the
    // last window — the menu-bar app is still running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // runtime integration + background loops: drain Swift-native subsystems
    // before process exit.
    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Stop the loopback bridges first, synchronously: once the listeners are
        // cancelled and their token/descriptor files are gone, no new request can
        // land mid-drain and no stale credential outlives the process.
        ClaudeBridge.shared.stop()
        MacControlBridge.shared.stop()
        MainActor.assumeIsolated {
            BrowserWindowController.shared.stopIPCServer()
        }

        let group = DispatchGroup()
        // Each drain gets its own group entry. Chaining them behind one entry
        // serialized them under a single 3s budget, so a slow cognition flush
        // starved the Core-owned loop drain of any budget at all. Independent
        // drains run concurrently and each gets the full 3s.
        group.enter()
        Task.detached {
            await NativeCognitionRuntime.shared.flushForTermination()
            group.leave()
        }
        group.enter()
        Task.detached {
            // Wave-1 review (gpt-5.5): TurnPlanTraceWriter is fire-and-forget
            // on the turn path; drain its chain at quit so a trace enqueued
            // moments before termination isn't lost.
            await TurnPlanTraceWriter.shared.drain()
            group.leave()
        }
        group.enter()
        Task.detached {
            // Interoception review (gpt-5.5): the vitals snapshot is never
            // written on the observe path — persist it here, at termination,
            // so the telemetry survives across runs.
            await NativeCognitionRuntime.shared.persistProviderVitalsSnapshot()
            group.leave()
        }
        group.enter()
        Task.detached {
            await BackgroundLoopsManager.shared.stop()
            group.leave()
        }
        // Workshop mission memories are written OFF the terminal path by a
        // detached queue, and `BackgroundLoopsManager.stop()` cancels loop
        // tasks — it does not drain that queue (gpt-5.5 review BLOCKING 1,
        // 2026-08-02). Without this, a mission that reached terminal moments
        // before quit left `mission.json` on disk and no memory: she did the
        // work and could not remember it. Bounded BELOW the 3s budget so a
        // wedged SQLite/embedder can never hold up quit — an unfinished drain
        // logs what it abandoned instead of blocking. The crash case (this
        // never runs at all) is repaired at next launch by
        // `reconcileMissedMissionMemories`.
        group.enter()
        Task.detached {
            await WorkshopExecutorRef.shared.current()?
                .waitForMissionMemoryWrites(timeout: 2.5)
            group.leave()
        }
        // MCP stdio children don't reliably exit on stdin EOF — stop the
        // pool explicitly or they orphan on quit.
        group.enter()
        Task.detached {
            await SwiftNativeMCPDispatcher.sharedPool.stopAll()
            group.leave()
        }
        group.enter()
        Task.detached {
            await NativeContextFlowRuntime.shared.stop()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 3.0)
    }

    @objc private func contextFlowWillSleep(_ notification: Notification) {
        Task.detached(priority: .utility) {
            await NativeContextFlowRuntime.shared.prepareForSleep()
        }
    }

    @objc private func contextFlowDidWake(_ notification: Notification) {
        Task.detached(priority: .utility) {
            await NativeContextFlowRuntime.shared.reconcileAfterWake()
            // R-F4: Task.sleep deadlines do not advance across system sleep, so
            // the cognition maintenance + residual-repair timers fire late until
            // the next sensory event re-arms them. Re-anchor them to the
            // post-wake clock, following the ContextFlow re-anchor pattern.
            await NativeCognitionRuntime.shared.reanchorDeadlinesAfterWake()
        }
    }

}
