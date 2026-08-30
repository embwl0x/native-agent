import Foundation
import Testing
@testable import NativeAgentApp
@testable import NativeAgentShared

// Eval coverage — fence `app.desk`. The vocabulary and receipt surfaces around
// the desk: what the Runs list CALLS a run, what the New Task sheet believes
// about failure, what the schedule's one receipt line says, and whether the
// Observatory can print a count it does not have.
//
// Ledger rows covered:
//   desk.runs.kindDisplayName        — wrong value: a raw wire id reaching the
//                                      product through the `default:` branch
//   desk.runs.kindDisplayNameParity  — wrong value: RunsView claims in a
//                                      comment to mirror the iOS map
//   desk.hub.newTaskSheet            — wrong value: the sheet infers success
//                                      from a string PREFIX of statusText, so
//                                      a reworded producer dismisses on failure
//                                      and eats the user's text
//   desk.hub.newTaskButton           — the button posts a notification and
//                                      relies on a presenter in another file
//   desk.scheduler.reflectionOutcome — wrong value: the only receipt the Add
//                                      Nightly Reflection button produces
//   workshop.observatory.headerCountsUnavailable — silent zero: "0/N open
//                                      pursuits" for a desk that could not be read

// MARK: - run-kind vocabulary

/// The rename layer over legacy wire ids. `claude` and `mission` are
/// compatibility identifiers; neither may reach a reader, and the `default:`
/// branch must never be what keeps them out.
///
/// Mutation proof: deleting the `case "claude"` line makes the map fall
/// through to `kind.capitalized` and this test goes red on "Claude".
@Test("no run-kind display name leaks a retired wire identifier")
func runKindDisplayNamesNeverLeakARawWireIdentifier() {
    let retired = ["claude", "mission"]
    for surface in [RunKindVocabulary.Surface.mac, .iOS] {
        for wireID in retired {
            let label = RunKindVocabulary.displayName(wireID, on: surface)
            #expect(label.lowercased() != wireID,
                    "\(surface): `\(wireID)` renders as its own wire id")
            #expect(label != wireID.capitalized,
                    "\(surface): `\(wireID)` renders as \(label) — the capitalized wire id, not a product name")
        }
        let unknown = RunKindVocabulary.displayName("future_internal_kind", on: surface)
        #expect(unknown == "Other run")
    }
}

/// The shared owner makes all non-product compatibility vocabulary agree
/// between platforms. `mission` is deliberately surface-specific until its
/// product rename is unified.
@Test("run-kind vocabulary agrees across surfaces except the named mission wording")
func runKindVocabularyHasOnlyItsRecordedSurfaceDifference() {
    for kind in ["codex", "claude", "swarm", "future_internal_kind"] {
        #expect(
            RunKindVocabulary.displayName(kind, on: .mac)
                == RunKindVocabulary.displayName(kind, on: .iOS),
            "\(kind) unexpectedly differs between surfaces")
    }
    #expect(RunKindVocabulary.displayName("mission", on: .mac) == "Desk")
    #expect(RunKindVocabulary.displayName("mission", on: .iOS) == "Workshop")
}

// MARK: - New Desk Task: failure stays inline, success dismisses

@Test("New Desk Task presentation keeps failures inline and still dismisses on success")
func newTaskPresentationSeparatesInlineFailuresFromDismissal() {
    #expect(NewDeskTaskPresentation.inlineError(from: NewDeskTaskPresentation.successStatus) == nil)
    #expect(
        NewDeskTaskPresentation.inlineError(
            from: NewDeskTaskPresentation.failureStatus("trust store unavailable")
        ) == "Couldn’t create this task. trust store unavailable"
    )
    #expect(
        NewDeskTaskPresentation.inlineError(
            from: NewDeskTaskPresentation.failureStatus("")
        ) == "Couldn’t create this task. Try again."
    )
}

/// The only Create-Task entry point posts a notification whose presenter lives
/// in ContentView. One poster, one subscriber, one sheet.
@Test("New Task posts a notification exactly one presenter subscribes to")
func newTaskButtonAndPresenterShareOneNotification() throws {
    let hub = try AppSourceScraping.appSource("WorkshopHubView.swift")
    let content = try AppSourceScraping.appSource("ContentView.swift")

    #expect(hub.contains("NotificationCenter.default.post(name: .newWorkshopTaskRequest"),
            "the New Task button no longer posts the request")
    #expect(AppSourceScraping.occurrences(
        of: "publisher(for: .newWorkshopTaskRequest)", in: content) == 1,
        "expected exactly one subscriber for the New Task request")
    #expect(AppSourceScraping.occurrences(of: "NewWorkshopTaskSheet(", in: content) == 1,
            "expected exactly one presenter of the New Desk Task sheet")
    // The name is declared once, as a symbol — not re-spelled as a raw string
    // at either end.
    #expect(AppSourceScraping.occurrences(
        of: "Notification.Name(\"NativeAgent.newWorkshopTaskRequest\")", in: content) == 1)
}

// MARK: - the schedule's one receipt

/// `NightlyReflectionJobOutcome` is the entire receipt for the Add Nightly
/// Reflection button. Three success shapes and one failure share one line, so
/// they have to be distinguishable in the message AND agree with `succeeded`
/// (which drives the icon and colour).
///
/// Mutation proof: making `.alreadyPresent` return the `.added` message, or
/// making `.failed` report `succeeded == true`, fails this test.
@Test("every nightly-reflection outcome is distinguishable and matches its succeeded flag")
func nightlyReflectionOutcomesAreDistinguishableAndHonest() {
    let outcomes: [NightlyReflectionJobOutcome] = [
        .added, .alreadyPresent, .repaired, .failed("scheduler unreachable"),
    ]

    // Distinguishable: a reader can tell "created" from "was already there"
    // from "repaired" from "failed".
    let messages = outcomes.map(\.message)
    #expect(Set(messages).count == outcomes.count,
            "two outcomes render the same line: \(messages)")
    for message in messages {
        #expect(!message.isEmpty)
    }

    // The flag that picks the icon/colour agrees with the case.
    #expect(NightlyReflectionJobOutcome.added.succeeded)
    #expect(NightlyReflectionJobOutcome.alreadyPresent.succeeded)
    #expect(NightlyReflectionJobOutcome.repaired.succeeded)
    #expect(!NightlyReflectionJobOutcome.failed("x").succeeded)

    // A failure carries its detail rather than a generic apology, and no
    // success line reads as a failure.
    #expect(NightlyReflectionJobOutcome.failed("scheduler unreachable").message
        .contains("scheduler unreachable"))
    for outcome in outcomes where outcome.succeeded {
        #expect(!outcome.message.lowercased().contains("could not"),
                "a successful outcome reads as a failure: \(outcome.message)")
    }
}

// MARK: - the Observatory never prints a count it does not have

/// `WorkshopObservatorySnapshot.model == nil` means the Desk store read FAILED.
/// The collapsed hint is already tested; the expanded header is a second,
/// independent honesty branch over the same nil, and it is the one that renders
/// the numeric chips ("3/5 open pursuits").
///
/// Mutation proof: replacing the header's `else` branch with chips fed a
/// defaulted model fails this test.
@Test("the Observatory header renders no numeric chip without a model")
func observatoryHeaderRendersNoCountsWithoutAModel() throws {
    let source = try AppSourceScraping.appSource("WorkshopObservatoryPanel.swift")
    let header = try AppSourceScraping.functionBody(named: "header", in: source)

    guard let gate = header.range(of: "if let model = snapshot.model {"),
          let elseBranch = header.range(of: "} else {", range: gate.upperBound..<header.endIndex)
    else {
        Issue.record("the Observatory header no longer branches on snapshot.model — re-pin this test")
        return
    }
    let withModel = String(header[gate.upperBound..<elseBranch.lowerBound])
    let withoutModel = String(header[elseBranch.upperBound...])

    // Chips only exist on the branch that has a model.
    #expect(AppSourceScraping.occurrences(of: "metricChip(", in: withModel) >= 2,
            "the header stopped rendering its metric chips entirely")
    #expect(AppSourceScraping.occurrences(of: "metricChip(", in: withoutModel) == 0,
            "the no-model branch renders a metric chip — a count for a desk that could not be read")

    // And the no-model branch interpolates nothing at all, so it cannot print a
    // defaulted zero.
    #expect(!withoutModel.contains("\\("),
            "the no-model branch interpolates a value: \(withoutModel.prefix(200))")
    #expect(withoutModel.contains("Counts unavailable"),
            "the no-model branch no longer says the counts are unavailable")

    // The model-level invariant behind the branch: the counts have exactly one
    // source, so a nil model has no number to print.
    let unavailable = WorkshopObservatorySnapshot(
        model: nil,
        deskUnavailable: "desk store unreadable",
        receipts: .rows([]))
    #expect(unavailable.model == nil)
    #expect(!unavailable.hint.contains("0"),
            "the collapsed hint prints a zero for an unreadable desk: \(unavailable.hint)")
}
