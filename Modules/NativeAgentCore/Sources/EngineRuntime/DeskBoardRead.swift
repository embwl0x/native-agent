// DeskBoardRead.swift
// ONE read of the Desk's stores, for every page that renders the Desk.
//
// The primary Desk calls `NativeAgentEngine.desk.loadBoard` (EngineDesk.swift).
// Canonical reads and their failure classification live here, outside the UI.
//
//   desk items    SwiftNativeDeskStore.liveState()  → rows, or a reason
//   executions    SwiftNativeWorkshopRunner.listAll(), classified against the
//                 on-disk probe (DeskLaneState.classify) so a corrupt store
//                 reports a reason instead of an empty bench
//   GitHub        GitHubCommandStore.liveState().items → rows, or the error
//
// The three reads stay INDEPENDENT: one broken lane never blanks the others,
// and every lane carries its own honesty rather than rendering as calm.
//
// The classic page additionally renders a sequencing plan and the handle→alias
// map; those are opt-in (`includeSequencing`) so the newer page pays neither
// the graph walk nor the map build for something it never draws.
//
// NOT here, deliberately:
//   · scheduler jobs — both pages read those through `engine.desk.jobs` /
//     `refreshSchedulerJobs()` on the main actor, not from this store read.
//   · freshness/stale deadlines — `DeskLiveActivityPresentation` (classic) and
//     `DeskPageContent.staleWatches` (new page) are pure projections over the
//     rows below, taken on the main actor with each page's own clock.
//   · the "her hour" trace — a main-actor read on the classic page only.
//
// The read is nonisolated and Sendable-clean; each caller wraps it in its own
// `Task.detached` and publishes under its own request gate.

import Foundation
import PersistenceCore
import Desk
import GitHubConnector
import WorkshopExecution
import NativeAgentShared

/// One read of every Desk store, taken off the main actor.
public struct DeskBoardRead: Sendable {
    /// The desk feed, or nil when it could not be read.
    public var deskState: DeskState?
    /// Why the desk feed could not be read. Non-nil exactly when `deskState` is
    /// nil — a lane that failed says so instead of presenting as empty.
    public var deskError: String?
    public var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    public var github: DeskLaneState<GitHubCommandItem> = .rows([])
    public var overview: WorkOverview?

    /// ONE DeskSequencing.compute() per load — never per row. The derivation
    /// walks the whole blocked-on graph plus every parent chain, so calling it
    /// from a row builder would re-run that walk on every SwiftUI diff pass.
    /// It's pure and Sendable, so it rides along in the background snapshot.
    /// Empty unless `includeSequencing` was asked for.
    public var plan: DeskSequencing.Plan = DeskSequencing.Plan()
    /// handle → alias, built from the SAME state the plan came from. The UI
    /// shows operator aliases ("2.1") and never internal handles — same
    /// invariant DeskProjection holds. Empty unless asked for.
    public var aliasByHandle: [String: String] = [:]

    public var items: [DeskItem] { deskState?.items ?? [] }
    public init(
        deskState: DeskState? = nil,
        deskError: String? = nil,
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([]),
        github: DeskLaneState<GitHubCommandItem> = .rows([]),
        plan: DeskSequencing.Plan = DeskSequencing.Plan(),
        aliasByHandle: [String: String] = [:]
    ) {
        self.deskState = deskState
        self.deskError = deskError
        self.executions = executions
        self.github = github
        self.plan = plan
        self.aliasByHandle = aliasByHandle
    }

}
