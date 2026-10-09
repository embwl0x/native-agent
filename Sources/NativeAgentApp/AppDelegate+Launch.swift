import ApprovalTransactions
import Foundation
import AppKit
import UserNotifications
import AppIntents
import NativeAgentCore
import WorkshopExecution
import SelfImprovement
import ChatOrchestration
import ChromeControl
import ContextFlow
import BackgroundLoops
import MemoryV2
import NotificationInbox
import PersistenceCore
import Desk
import Transcripts
import TurnTrace
import PersonaEngine
import Skills
import MCPDispatcher
import GitHubConnector
import SlackConnector
import Connectors
import Browser
import Cognition
import OSLog
import os
import DeviceSync
import AppToolRuntime
import NativeAgentShared

private struct AppDerivedStateInvalidationSink: DerivedStateInvalidationSink {
    let dataRoot: URL

    func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        let memoryPath = dataRoot.appendingPathComponent("memory/memory.sqlite").standardizedFileURL.path
        if changes.contains(where: {
            $0.namespace == "memory-v2" && $0.canonicalLocator == memoryPath
        }) {
            await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots(includeMemories: true)
        }
        await DerivedPersonaPinInvalidationSink(dataRoot: dataRoot).sourceDidChange(changes)
    }
}

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            previousWorkApp = app
        }
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(continuationAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // A clicked banner has to reach the app: without a delegate, the
        // identity a Desk reminder carries goes nowhere.
        UNUserNotificationCenter.current().delegate = self
        // Her `app` actions read by their buttons' words on every door.
        // A folded action is shown as its tool (files.write → write_file).
        let labels = AppActions.all.flatMap { action in
            [(action.id, action.label)] + (action.isFold && action.label != action.tool ? [(action.tool, action.label)] : [])
        }
        ToolActivityPresentation.installActionLabels(
            Dictionary(labels, uniquingKeysWith: { first, _ in first }))
        NativeAgentNotificationActions.register()
        AnchorReplyMirror.start()
        NativeAgentShortcuts.updateAppShortcutParameters()
        approvalNotificationTask = Task { @MainActor in
            await NativeAgentApprovalNotifications.observe()
        }
        do {
            try NativeAgentBuildIdentity.current.writeLaunchStamp(root: NativeAgentPaths.dataRoot)
        } catch {
            nativeLog("[launch] Could not record app start time: %@", error.localizedDescription)
        }
        do {
            _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: NativeAgentPaths.dataRoot)
            nativeLog("[workspace] canonical work root ready")
        } catch {
            // Chat and private state can still start; file/build tools will
            // return their normal checked failure if the directory remains
            // unavailable. Do not replace a recoverable workspace error with a
            // second app-lifecycle gate.
            nativeLog("[workspace] canonical work root unavailable: %@", error.localizedDescription)
        }
        Task { await finishLaunching() }
    }

    @MainActor @objc func continuationAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        previousWorkApp = app
    }

    @MainActor
    private func finishLaunching() async {
        // Wire restart before the migration suspension: SwiftUI can already
        // accept turns while Workshop prepares its execution records.
        await AppRestartCoordinator.shared.configure(
            scheduleTerminate: { graceSeconds in
                DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
                    nativeLog("[restart_app] grace elapsed — terminating for relaunch")
                    // Off this main-queue block: a held quit spins a nested run
                    // loop, and the main queue cannot drain while one of its own
                    // blocks is still on the stack — MainActor work would stall.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { AppDelegate.terminateForRestart() }
                    }
                }
            },
            spawnRelauncher: AppRelauncher.spawnDetached(argv:)
        )
        // Finish updating the folder before the runtime can ask Chrome to reload it.
        await Task.detached(priority: .utility) { ChromeExtensionFolder.refreshIfPresent() }.value
        do {
            // 2026-09-18: a first-format migration can visit every execution.
            // Let AppKit finish launching while it runs; runtime ingress and
            // schedulers below still start only after the migration succeeds.
            let report = try await WorkshopStorageMigrator.prepareForReading(dataRoot: NativeAgentPaths.dataRoot)
            if report.didMigrate {
                // P2-7: the legacy missions/ absorption is deleted; the only
                // passes that can report didMigrate now are the execution.json
                // record rename and receipts_dir pointer repair.
                nativeLog(
                    "[workshop-migration] normalized execution records: changed=%d conflicts=%d receipt=%@",
                    report.moved.count,
                    report.conflictsPreservedInArchive.count,
                    report.receiptRelativePath ?? "none"
                )
            }
        } catch {
            nativeLog("%@", "[workshop-migration] failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Desk execution storage migration failed"
            alert.informativeText = "NativeAgent stopped before starting background work so no task state is lost. "
                + UserFacingError.advice(for: error)
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // Normalize skills before background work and remote tool ingress start.
        await SkillRegistryMigration.runIfNeeded(dataRoot: PersistenceCore.defaultDataRoot())
        do { try await SwiftNativeSkillsClient(root: PersistenceCore.defaultDataRoot()).migrateScriptInterpreter() }
        catch { NSLog("Skill interpreter migration failed: %@", error.localizedDescription) }
        // Before Slack's ingress starts: its tokens move from files to Keychain.
        do { try SlackCredentials.migrate(dataRoot: NativeAgentPaths.dataRoot) }
        catch { nativeLog("[slack-credential] Keychain migration failed: %@", error.localizedDescription) }
        do { try await ConnectorOAuthRegistry.migrateXCredentials(dataRoot: NativeAgentPaths.dataRoot) }
        catch { nativeLog("[x-credential] Keychain migration repair state unavailable: %@", error.localizedDescription) }
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
            // 2026-09-06: the invalidation sink belongs to the app, not to
            // Context Flow. It used to be installed inside the Context Flow
            // startup, so with Context Flow off nothing was subscribed and a
            // GROWTH.md edit left retracted REM pins live until the next weekly
            // cycle. Install it here, before the runtime starts; Context Flow
            // then subscribes its coordinator to it.
            await DerivedStateInvalidationCenter.shared.install(
                AppDerivedStateInvalidationSink(dataRoot: NativeAgentPaths.dataRoot)
            )
            await NativeAgentEngine.live.contextFlow.start()
        }

        // U1 (User, 2026-09-10): after the app updates, the agent had no way to
        // know what changed — someone asked theirs and it could not find out.
        // On the first launch after CFBundleShortVersionString changes, leave
        // the agent ONE note; the turn engine reads it into the next turn's
        // dynamic context. A fresh install stores the version and says nothing.
        AppUpdateNoteStore.recordLaunchAtStartup()

        // PATCH-2026-05-07: use .regular activation policy
        // so the dock icon stays visible. The
        // applicationShouldTerminateAfterLastWindowClosed = false hook still
        // keeps the app and background runtime alive when the user closes the
        // main window, so background work (dream cycle, consolidation,
        // proactive triggers) keeps running.
        NSApp.setActivationPolicy(.regular)

        // Speech consent belongs to a voice action. Only reconcile an existing
        // grant here, including changes made in System Settings between launches.
        Task.detached(priority: .utility) {
            await BackgroundLoopsAssembly.retireSystemPermissionCardIfGranted(
                dataRoot: NativeAgentPaths.dataRoot
            )
        }

        // Process-wide app services and route retention must not depend on the
        // main SwiftUI Window appearing. The coordinator is configured from
        // NativeAgentApp.init with the shared AppModel, then started exactly
        // once from this guaranteed application lifecycle callback.
        NativeAgentAppCoordinator.shared.applicationDidFinishLaunching()
        Task.detached(priority: .utility) {
            await NativeAgentEngine.live.chrome.observeBrowserLaunches()
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        }

        // MemoryV2 Path C: one-shot JSON → SQLite migration. Idempotent;
        // a sentinel file under <dataRoot>/memory skips subsequent launches.
        // Detached so first-launch I/O doesn't gate UI ready.
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.nativeagent.app", category: "memory-migration")
            let canonicalStorage: MemoryStorage
            do {
                canonicalStorage = try await SwiftNativeMemoryV2.resolvedStorage(
                    dataRoot: NativeAgentPaths.dataRoot
                )
            } catch {
                logger.error("MemoryV2 canonical storage unavailable; migration and projections refused: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "Memory did not open"
                    alert.informativeText = "NativeAgent is running without memory this session: nothing is recalled or saved. Doctor shows the details under Live memory store."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }
            let report = await MemoryV2Migrator(
                dataRoot: NativeAgentPaths.dataRoot,
                storage: RealMemoryStorage(storage: canonicalStorage)
            ).migrate()
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
            guard report.requiredFailures == 0 else {
                logger.error("MemoryV2 derived projection reconciliation refused because migration is incomplete")
                return
            }

            // A full graph rebuild is only required when this launch actually
            // crossed the canonical migration boundary. On healthy launches,
            // the shared MemoryV2 startup hook performs a bounded additive
            // backfill instead of deleting and recreating every graph row.
            // 2026-09-11: a pending statement retired by its own correction must
            // not leave a tombstone that blocks the correction (Astra comb 1).
            // Idempotent, no-op once clean.
            await SwiftNativeMemoryV2.shared.repairSupersededTombstones()
            if !report.skippedAlreadyMigrated {
                do {
                    _ = try await SwiftNativeMemoryV2.shared.reconcileKnowledgeGraphProjection()
                } catch {
                    logger.error("MemoryV2 Knowledge Graph reconciliation failed: \(String(describing: error), privacy: .public)")
                }
            }
            if let generator = await SwiftNativeMemoryV2.shared.bindUserMDGenerator(
                dataRoot: NativeAgentPaths.dataRoot,
                personaRoot: NativeAgentPaths.personaRoot
            ) {
                do {
                    _ = try await generator.regenerate()
                } catch UserMDGeneratorError.onboardingIncomplete {
                    // Expected on a blank install; onboarding owns first write.
                } catch {
                    logger.error("MemoryV2 USER.md reconciliation failed: \(String(describing: error), privacy: .public)")
                }
            }
            await MemorySpotlightBootstrap.shared.reindexAll()
        }

        // Swift-native cutover/fin-integration: these are macOS
        // NSBackgroundActivityScheduler entries, registered after migration.
        Self.registerBackgroundTaskHandlers()

        // Make the execution planner TOOL-AWARE for EVERY path, incl. the
        // autonomous trigger scheduler (which builds its runner via the core
        // makeWorkshopRunner and so can't be wired per-call-site). Configured
        // SYNCHRONOUSLY here, before any detached loop/trigger task spawns, so
        // an execution Agent fires on her own plans real tools — not synthesis-only
        // (2026-06-15, the user: executions do everything, including unattended).
        WorkshopExecution.WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())

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
            let downloadDescriptor = Bundle.main.url(forResource: "embedding-download", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? EmbeddingModelDownload.Descriptor.parse($0) }
            if downloadDescriptor?.distribution != "separate-download" {
                await reconcileMemoryEmbeddingEpochAtLaunch()
            }
            await SkillRegistryMigration.inheritBuiltInDescriptions(dataRoot: PersistenceCore.defaultDataRoot())
            await syncSkillPointerIndex()
        }
        // The transcript-aging lane defers through the same body throttle as
        // every other background-cognition lane. Installing the gate is a
        // synchronous closure store — no bring-up, nothing to wedge.
        ChatConsolidationGateInstall.install()
        Task.detached(priority: .utility) {
            await NativeAgentEngine.liveCognition.bootstrap()
        }
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.nativeagent.app", category: "chat-reconciliation")
            do {
                let report = try await ChatSessionIndexReconciler(
                    dataRoot: NativeAgentPaths.dataRoot
                ).reconcile()
                if report.sessionsRecovered > 0 || report.corruptTranscripts > 0
                    || report.staleRowsRepaired > 0 {
                    logger.info(
                        "Chat reconciliation: recovered=\(report.sessionsRecovered, privacy: .public) repaired=\(report.staleRowsRepaired, privacy: .public) corrupt=\(report.corruptTranscripts, privacy: .public) examined=\(report.transcriptsExamined, privacy: .public)"
                    )
                }
            } catch {
                logger.error("Chat reconciliation refused: \(String(describing: error), privacy: .public)")
            }
        }
        Task.detached(priority: .utility) {
            // NativeAgentApp owns composition; Core owns process lifecycle,
            // execution, and status for the injected manifest.
            // Prime GitHub's semantic baseline before its refresh loop can
            // publish. This closes the launch race without replaying old work
            // as fresh resident physiology.
            await GitHubCommandRuntime.shared.replayResidentStateAtLaunch()
            // The one engine root, built here before the loops ask it for clients.
            _ = NativeAgentEngine.live
            do { try await SensesAssembly.waitUntilReady() }
            catch { nativeLog("[senses] Launch registration unavailable: %@", error.localizedDescription) }
            let loops = BackgroundLoopsAssembly.assembleAllLoops()
            await installBotProviderCheck()
            await BackgroundLoopsManager.shared.start(loops: loops)
            // CRASH RECONCILIATION for the Workshop→memory lane (gpt-5.5
            // review BLOCKING 1, 2026-08-02). Execution-memory writes are handed
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
                _ = await executor.reconcileMissedExecutionMemories()
            }
        }
        // Refresh the doctor snapshot ONCE after this launch's first completed
        // turn, so the turn-behaviour checks in data/doctor/latest.json report
        // observations instead of the launch-time UNMEASURED.
        DoctorFirstTurnRefresh.arm()
        // Accepted turns that never got a terminal row are an outcome gap, not
        // a mystery: reconcile them, bounded, at launch and after later turns.
        AbandonedTurnReconciliationHook.arm(completedTurnNotification: .chatTurnCompleted)
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
            await AdaptiveMemoryPromoter.shared.configure(
                memory: SwiftNativeMemoryV2.shared,
                // The fact lane (2026-09-11): the memory manager, on the agent's
                // real mind, with the memories it already keeps in view. It
                // replaced the regex template extractor + on-device pass; there
                // is no rule-based conformer to fall back to, by design.
                memoryManager: MindMemoryManager(makeLLMClient: {
                    BackgroundLoopsAssembly.makeSharedLLMClient()
                }),
                
                // Setup ▸ "Moments she keeps". The module never reads
                // UserDefaults; the switch reaches it as this closure, read
                // fresh on every turn so flipping it takes effect at once.
                momentsEnabled: { MomentsLaneSetting.isEnabled() },
                // Settings ▸ "Memories that recur become facts". Same shape as
                // the moments switch: read fresh on every turn, so flipping it
                // takes effect at once.
                adaptivePromotionEnabled: { MemoryPolicyGate.adaptivePromotionEnabled() },
                // A memory is about "User", never "the person" (Agent, 2026-09-11).
                personName: { NativeCognitionRuntime.resolveUserName(dataRoot: PersistenceCore.defaultDataRoot()) }
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
            await MemoryRepairOneShot.stageIfNeeded(
                dataRoot: PersistenceCore.defaultDataRoot(),
                presentation: AppMemoryRepairPresentation())
            // Astra audit 2026-09-11 finding 5: the 13 unscoped LEGACY correction
            // atoms were still mandatory on every turn, because intake scoping by
            // design never edits an atom already in the store. One hand-reviewed
            // pass stamps `context_topics` on the seven task-specific records and
            // leaves the six interpersonal/authorization ones global. Idempotent
            // via a version-stamped marker; receipted beside it.
            await LegacyCorrectionScopeMigration.runIfNeeded(dataRoot: PersistenceCore.defaultDataRoot())
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
            // coverage (rem.proposal, execution.step, self_improvement.apply,
            // browser.open_url). Re-fires the SAME executors resolveApproval
            // runs, keyed on "resolved + no executedAction annotation";
            // per-kind idempotency hooks (REM status-flip no-op, execution
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
                nativeLog("[browser] restart recovery failed: %@", String(describing: error))
            }
            await NativeClient.reconcileUnappliedApprovalExecutions()
            // Terminal-event reconciliation normally stages this exact card.
            // Launch repair closes the safe crash/restart gap without a poll:
            // if enough canonical procedure receipts already exist, stage the
            // same local-only activation review once. First, once ever,
            // re-check legacy v1 procedures against their reviewed evidence so
            // the ones that still match load again; any that cannot stay off
            // and leave one inbox line saying why.
            let procedureDataRoot = PersistenceCore.defaultDataRoot()
            for line in await WorkshopProcedureLegacyRevalidation.runIfNeeded(dataRoot: procedureDataRoot) {
                let cardID = "procedure-legacy-revalidation-\(CausalTransitionEvidence.opaqueIdentity(line).prefix(16))"
                _ = try? await LiveNotificationInbox(
                    path: LiveNotificationInbox.livePath(dataRoot: procedureDataRoot)
                ).appendUnique(.object([
                    "id": .string(cardID),
                    "created_at": .string(NativeTimestampFormat.fractionalZulu(Date())),
                    "source": .string("workshop"),
                    "severity": .string("info"),
                    "title": .string("A saved procedure stays off"),
                    "summary": .string(line),
                    "actions": .array([.object(["id": .string("dismiss"), "label": .string("Dismiss"),
                                                "description": .string("Dismiss this card")])]),
                    "status": .string("unread"),
                ]), id: cardID)
            }
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
            let evolutionDeps = NativeClient.selfEvolutionDeps()
            await SelfEvolutionApprovalExecutor.runEvolutionVerifyAtLaunch(deps: evolutionDeps)
            await ApprovalTransactionCoordinator.reconcileUnappliedSelfEvolution(deps: evolutionDeps)
            await BackgroundLoopsAssembly.stageEvolutionApprovals()
            // Same shape for REM: staging used to run ONLY inside the weekly
            // job, so a row appended by a pass whose staging failed waited up
            // to a week for a card (Astra audit 2026-09-11, finding 9). This
            // generates no REM batch — bounded catch-up through the same
            // stager, idempotent against the store's approval stamp.
            await BackgroundLoopsAssembly.stagePendingREMProposalsAtLaunch()
        }

        // PATCH-2026-06-17 dream-single-owner: dream cadence is owned solely
        // by TriggerScheduler's `nativeagent-nightly-dream` calendar job.
        // BackgroundLoopsManager and NSBackgroundActivityScheduler must not
        // register an unattended dream loop.

        // W8 (2026-08-14) — the ambient activity watcher.
        //
        // Called UNCONDITIONALLY, and that is deliberate. The decision about
        // whether to capture lives in exactly one place: the policy read inside
        // `ActivityWatcher.start()`, which installs no AX observer, no
        // workspace observer and no lock observer, and opens no span, when the
        // Trust Center toggle is off. A second `if` here would be a second gate
        // that can disagree with the first, and the outer one is always the one
        // a later refactor forgets. Default is OFF, and an unreadable policy
        // file decodes to OFF, so a fresh install captures nothing.
        Task { @MainActor in
            ActivityWatchController.shared.startAtLaunch()
        }

        // PATCH-2026-05-06: wkwebview-browser Start browser IPC server on this install's fixed port (8766).
        Task { @MainActor in
            BrowserWindowController.shared.startIPCServer()
        }
        // PATCH-2026-05-07: mac-control-bridge Start Mac Control bridge on its
        // fixed port (8770), so local mac-control calls execute under NativeAgent.app's bundle
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
        nativeLog("[claude-bootstrap] dispatching ClaudeBridge.startServer on dispatch queue")
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeBridge.shared.startSyncForBootstrap()
            NativeAgentA2AGRPCListener.shared.start()
        }
        // PATCH-2026-05-07: icloud-bridge start iCloud bridge and wire iOS→Swift runtime forwarding
        Task { @MainActor in
            NativeAgentEngine.liveDeviceSync.bridge.setup()
            NativeAgentEngine.liveDeviceSync.bridge.observeIncomingMessages { msg in
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
        // 2026-09-22: a first run registers once the first greeting has been
        // delivered (AppModel.maybeSendFirstRunGreeting) instead, so a new
        // user is not added to login items before setup.
        if NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: NativeAgentPaths.dataRoot) {
            AppDelegate.registerLoginItemInBackground()
        }

    }

    // PATCH-2026-05-07: app-owned runtime Don't quit when the user closes the
    // last window — the menu-bar app is still running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NativeAgentEngine.liveDeviceSync.bridge.cloudKitPushRegistrationSucceeded()
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NativeAgentEngine.liveDeviceSync.bridge.cloudKitPushRegistrationFailed(error)
    }

    @MainActor
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map {
            (AnyHashable($0.key), $0.value)
        })
        guard NativeAgentEngine.liveDeviceSync.bridge.recognizesCloudKitRemoteNotification(payload) else { return }
        Task { @MainActor in
            await NativeAgentEngine.liveDeviceSync.bridge.handleCloudKitPushWake()
        }
    }

    /// Set while a restart_app quit is under way. Behind a lock, not the main
    /// actor: a held quit's waiter reads it while the main queue may be stuck.
    nonisolated private static let restartQuit = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var quitWaitingForTurns = false

    /// restart_app's quit waits for no turns: its grace was their allowance,
    /// and the relauncher reopens the bundle once we exit.
    /// A quit already held just stops waiting.
    @MainActor
    static func terminateForRestart() {
        restartQuit.withLock { $0 = true }
        if quitWaitingForTurns { return }
        NSApp.terminate(nil)
        // Reached only when the quit was refused (a modal vetoed it): a later
        // ordinary Quit must still wait for its turns.
        restartQuit.withLock { $0 = false }
    }

    /// Turn-safe quit. A Quit that lands mid-turn (menu, install_app.sh's
    /// AppleScript quit, logout, restart_app) used to kill the turn and lose
    /// its reply. Tool receipts are already durable as each tool finishes
    /// (appendToolMessage → appendJSONLDurable); this lets the turns running
    /// at Quit finish too. Bounded at 20s (none on restart_app): past it the quit
    /// goes ahead and a hung turn dies as before. Turns accepted after Quit
    /// are not waited on.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitWaitingForTurns { return .terminateLater }
        let runs = NativeAgentEngine.live.turns.inFlightRunIDs()
        guard !runs.isEmpty, !Self.restartQuit.withLock({ $0 }) else { return .terminateNow }
        Self.quitWaitingForTurns = true
        nativeLog("[quit] holding quit for %d in-flight turn(s), at most 20s", runs.count)
        Task.detached {
            let deadline = ContinuousClock.now + .seconds(20)
            while !NativeAgentEngine.live.turns.inFlightRunIDs().isDisjoint(with: runs),
                  ContinuousClock.now < deadline,
                  !Self.restartQuit.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let left = NativeAgentEngine.live.turns.inFlightRunIDs().intersection(runs).count
            nativeLog("[quit] %@", left == 0 ? "turns finished — quitting" : "\(left) turn(s) still running at the bound — quitting anyway")
            // A run-loop block, not MainActor.run: if the Quit came from inside
            // a main-queue block (a MainActor task), the main queue cannot drain
            // until that block returns, and the reply would never be delivered.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(main)
        }
        return .terminateLater
    }

    // runtime integration + background loops: drain Swift-native subsystems
    // before process exit.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        approvalNotificationTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Stop the loopback bridges first, synchronously: once the listeners are
        // cancelled and their token/descriptor files are gone, no new request can
        // land mid-drain and no stale credential outlives the process.
        NativeAgentA2AGRPCListener.shared.stop()
        ClaudeBridge.shared.stop()
        MacControlBridge.shared.stop()
        MainActor.assumeIsolated {
            BrowserWindowController.shared.stopIPCServer()
            MoodTintWeather.shared.stop()
            // The phone bridge and its snapshot projection are ingress too.
            // Stop them before cognition/loop drains: otherwise a late iCloud
            // action or cognition-change observation can start new snapshot
            // work while the process is trying to reach a terminal state.
            NativeAgentEngine.liveDeviceSync.bridge.tearDown()
        }

        let group = DispatchGroup()
        // Each drain gets its own group entry. Chaining them behind one entry
        // serialized them under a single 3s budget, so a slow cognition flush
        // starved the Core-owned loop drain of any budget at all. Independent
        // drains run concurrently and each gets the full 3s.
        group.enter()
        Task.detached {
            await NativeAgentEngine.live.chrome.stop()
            group.leave()
        }
        group.enter()
        Task.detached {
            await NativeAgentEngine.liveCognition.flushForTermination()
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
            await BackgroundLoopsManager.shared.shutdown()
            group.leave()
        }
        group.enter()
        Task.detached {
            await SensesAssembly.shutdown()
            group.leave()
        }
        // Workshop execution memories are written OFF the terminal path by a
        // detached queue, and `BackgroundLoopsManager.stop()` cancels loop
        // tasks — it does not drain that queue (gpt-5.5 review BLOCKING 1,
        // 2026-08-02). Without this, an execution that reached terminal moments
        // before quit left `mission.json` on disk and no memory: she did the
        // work and could not remember it. Bounded BELOW the 3s budget so a
        // wedged SQLite/embedder can never hold up quit — an unfinished drain
        // logs what it abandoned instead of blocking. The crash case (this
        // never runs at all) is repaired at next launch by
        // `reconcileMissedExecutionMemories`.
        group.enter()
        Task.detached {
            await WorkshopExecutorRef.shared.current()?
                .waitForExecutionMemoryWrites(timeout: 2.5)
            group.leave()
        }
        // MCP stdio children don't reliably exit on stdin EOF — stop the
        // pool explicitly or they orphan on quit.
        group.enter()
        Task.detached {
            await SwiftNativeMCPDispatcher.stopAllSharedPools()
            group.leave()
        }
        group.enter()
        Task.detached {
            await SwiftToolDispatcher.closeACPConnections()
            group.leave()
        }
        group.enter()
        Task.detached {
            await NativeAgentEngine.live.contextFlow.stop()
            group.leave()
        }
        group.enter()
        // Create the Activity Watch drain ON the main actor before blocking it
        // in `group.wait`. Dispatching `shutdown()` back to MainActor here used
        // to guarantee that teardown could not even begin until the 3s wait had
        // already expired.
        let activityWatchDrain = ActivityWatchController.shared.makeTerminationDrain()
        Task.detached {
            await activityWatchDrain.value
            group.leave()
        }
        _ = group.wait(timeout: .now() + 3.0)
    }

    @objc private func contextFlowWillSleep(_ notification: Notification) {
        Task.detached(priority: .utility) {
            await NativeAgentEngine.live.contextFlow.prepareForSleep()
        }
    }

    @objc private func contextFlowDidWake(_ notification: Notification) {
        Task.detached(priority: .utility) {
            await NativeAgentEngine.live.contextFlow.reconcileAfterWake()
            // R-F4: Task.sleep deadlines do not advance across system sleep, so
            // the cognition maintenance + residual-repair timers fire late until
            // the next sensory event re-arms them. Re-anchor them to the
            // post-wake clock, following the ContextFlow re-anchor pattern.
            await NativeAgentEngine.liveCognition.reanchorDeadlinesAfterWake()
        }
    }

}
