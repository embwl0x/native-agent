// DeskBoardRead.swift
// ONE read of the Desk's stores, for every page that renders the Desk.
//
// Both Desk surfaces — the classic `DeskView` and the newer `DeskPageView` —
// render the same board from the same stores. Until this file existed they each
// carried their own copy of that read, and the second copy was documented as
// "the classic Desk's load(), minus the parts only the classic Desk renders".
// A copy is a divergence waiting to happen: a store swapped, a lane reordered
// or a failure re-classified on one page would have left the other page quietly
// showing something else.
//
// So the read lives here, once, and both pages call it:
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
//   · scheduler jobs — both pages read those through `AppModel.jobs` /
//     `refreshSchedulerJobs()` on the main actor, not from this store read.
//   · freshness/stale deadlines — `DeskLiveActivityPresentation` (classic) and
//     `DeskPageContent.staleWatches` (new page) are pure projections over the
//     rows below, taken on the main actor with each page's own clock.
//   · the "her hour" trace — a main-actor read on the classic page only.
//
// This function is nonisolated and Sendable-clean; each caller wraps it in its
// own `Task.detached` and publishes under its own request gate.

import Foundation
import PersistenceCore
import WorkshopExecution

/// One read of every Desk store, taken off the main actor.
struct DeskBoardRead: Sendable {
    /// The desk feed, or nil when it could not be read.
    var deskState: DeskState?
    /// Why the desk feed could not be read. Non-nil exactly when `deskState` is
    /// nil — a lane that failed says so instead of presenting as empty.
    var deskError: String?
    var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    var github: DeskLaneState<GitHubCommandItem> = .rows([])

    /// ONE DeskSequencing.compute() per load — never per row. The derivation
    /// walks the whole blocked-on graph plus every parent chain, so calling it
    /// from a row builder would re-run that walk on every SwiftUI diff pass.
    /// It's pure and Sendable, so it rides along in the background snapshot.
    /// Empty unless `includeSequencing` was asked for.
    var plan: DeskSequencing.Plan = DeskSequencing.Plan()
    /// handle → alias, built from the SAME state the plan came from. The UI
    /// shows operator aliases ("2.1") and never internal handles — same
    /// invariant DeskProjection holds. Empty unless asked for.
    var aliasByHandle: [String: String] = [:]

    var items: [DeskItem] { deskState?.items ?? [] }

    /// - Parameter includeSequencing: build the classic page's sequencing plan
    ///   and alias map as well. Off by default: a page that does not render
    ///   them should not pay for them.
    static func load(root: URL, includeSequencing: Bool = false) async -> DeskBoardRead {
        var read = DeskBoardRead()
        do {
            read.deskState = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        } catch {
            read.deskError = DeskItemPresentation.loadFailure(error)
        }
        // Execution and GitHub reads stay independent: one broken lane never
        // blanks the other live Workshop projections. But "lenient" used to
        // mean "silent" — a corrupt store returned [] and the surface said
        // "Quiet right now". Each lane now reports rows OR a reason.
        let runner = SwiftNativeWorkshopRunner(root: root)
        let records = await runner.listAll()
        read.executions = DeskLaneState.classify(
            rows: records,
            probe: DeskView.probeExecutionRecords(runner.executionRecordsRoot),
            noun: "execution record(s)")
        do {
            read.github = .rows(try await GitHubCommandStore(dataRoot: root).liveState().items)
        } catch {
            read.github = .failed(error)
        }
        if includeSequencing {
            read.plan = read.deskState.map { DeskSequencing.compute($0, now: Date()) }
                ?? DeskSequencing.Plan()
            var aliases: [String: String] = [:]
            for item in read.items { aliases[item.handle] = item.alias }
            read.aliasByHandle = aliases
        }
        return read
    }
}
