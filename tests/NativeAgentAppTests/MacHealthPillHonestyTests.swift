import Foundation
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — rows `public-api.AppModel.systemHealthSummary` and
// `ui.healthPill`.
//
// The toolbar pill is the one always-visible claim the Mac app makes about
// itself. Two silent-failure modes live behind it:
//
//   1. wrong value — `systemHealthSummary` buckets doctor checks by a
//      `status.lowercased() == "fail"` / `== "warn"` string compare. Any other
//      spelling counts as neither, and the pill reads "OK" over a failing
//      system. Nothing pinned the bucketing before this file.
//   2. wrong value — HealthPill's own `label(for:)`/`color(for:)` are private,
//      so the mapping from summary to tint could disagree with the summary
//      itself (green pill, failing system) with no test noticing.
//
// (1) is testable behaviourally: AppModel is constructible in this target and
// `doctorReport` is a settable stored property. (2) is only reachable as a
// source-conformance assertion over the private switch — which still bites: a
// mutation that returns `NativeAgentTheme.ok` for `.error` fails the test.

private func check(_ id: String, status: String) -> DoctorCheck {
    DoctorCheck(id: id, title: id, status: status, detail: "", repair: nil)
}

private func report(_ statuses: [String]) -> DoctorReport {
    DoctorReport(
        status: "ok",
        repaired: false,
        checks: statuses.enumerated().map { check("c\($0.offset)", status: $0.element) }
    )
}

@MainActor
@Test("cold launch is Checking, never OK — the pill holds no belief before Doctor runs")
func systemHealthSummary_coldLaunchIsUnknown() {
    let model = AppModel()
    // Nothing has run. The honest answer is "I do not know", not "all clear".
    #expect(model.doctorReport == nil)
    #expect(model.systemHealthSummary == .unknown)
}

@MainActor
@Test("a failing check outranks warnings and reports the fail count, not the total")
func systemHealthSummary_failOutranksWarnAndCountsOnlyFails() {
    let model = AppModel()
    model.doctorReport = report(["ok", "warn", "fail", "warn", "fail"])

    // Worst-first: two fails and two warns must read as two ISSUES.
    #expect(model.systemHealthSummary == .error(count: 2))

    model.doctorReport = report(["ok", "warn", "ok"])
    #expect(model.systemHealthSummary == .warn(count: 1))

    model.doctorReport = report(["ok", "ok"])
    #expect(model.systemHealthSummary == .ok)
}

@MainActor
@Test("bucketing is case-insensitive in both directions")
func systemHealthSummary_isCaseInsensitive() {
    let model = AppModel()
    model.doctorReport = report(["FAIL"])
    #expect(model.systemHealthSummary == .error(count: 1))

    model.doctorReport = report(["Warn"])
    #expect(model.systemHealthSummary == .warn(count: 1))
}

@MainActor
@Test("an empty check list is OK, but a report that arrives with no checks is not silently unknown")
func systemHealthSummary_emptyChecksIsOKNotUnknown() {
    let model = AppModel()
    model.doctorReport = report([])
    // `.unknown` is reserved for "Doctor has never run". A run that produced no
    // checks is a different (and reportable) fact; collapsing the two would let
    // a broken Doctor masquerade as a cold launch forever.
    #expect(model.systemHealthSummary == .ok)
}

@MainActor
@Test("the accepted status vocabulary is exactly {fail, warn} — anything else reads as OK")
func systemHealthSummary_vocabularyIsClosedAndDocumented() {
    let model = AppModel()

    // This is the live hazard, pinned so it is visible rather than latent: a
    // doctor check that starts emitting a NEAR-MISS spelling is counted as
    // neither fail nor warn, and the pill says OK over a failing system. The
    // test asserts the exact boundary the production compare draws today; if
    // the compare is ever widened (or moved behind a shared vocabulary), this
    // is the test that has to be updated deliberately.
    for nearMiss in ["failed", "failure", "error", "critical", "FAIL ", "warning", "degraded"] {
        model.doctorReport = report([nearMiss])
        #expect(
            model.systemHealthSummary == .ok,
            "status '\(nearMiss)' now buckets differently — widen or narrow this vocabulary pin deliberately"
        )
    }

    // And the two that DO count still count, so this test cannot pass by the
    // bucketing having been deleted wholesale.
    model.doctorReport = report(["fail"])
    #expect(model.systemHealthSummary == .error(count: 1))
    model.doctorReport = report(["warn"])
    #expect(model.systemHealthSummary == .warn(count: 1))
}

@Test("the pill's tint never says ok over a warn/error summary")
func healthPill_colorNeverDisagreesWithTheSummary() throws {
    let source = try AppSourceScraping.appSource("HealthPill.swift")
    let colorBody = try #require(
        AppSourceScraping.looseFunctionBody(named: "color", in: source),
        "HealthPill.color(for:) not found — re-anchor this guard"
    )

    // Each arm must carry its OWN tint. The failure this pins is a refactor
    // that collapses `.warn`/`.error` onto the ok tint (or drops an arm so the
    // switch falls through to a shared default).
    #expect(colorBody.contains("case .unknown: .secondary"))
    #expect(colorBody.contains("case .ok: NativeAgentTheme.ok"))
    #expect(colorBody.contains("case .warn: NativeAgentTheme.warn"))
    #expect(colorBody.contains("case .error: NativeAgentTheme.fail"))

    // Exactly one arm may name the ok tint.
    #expect(AppSourceScraping.occurrences(of: "NativeAgentTheme.ok", in: colorBody) == 1)

    let labelBody = try #require(
        AppSourceScraping.looseFunctionBody(named: "label", in: source),
        "HealthPill.label(for:) not found — re-anchor this guard"
    )
    // The word the user reads must match the bucket: "OK" belongs to .ok alone,
    // and the cold-launch arm must not borrow it.
    #expect(labelBody.contains("case .unknown:"))
    #expect(labelBody.contains("\"Checking\""))
    #expect(AppSourceScraping.occurrences(of: "\"OK\"", in: labelBody) == 1)

    // The rendered pill must read BOTH from the same summary value — two
    // independent recomputations are how the dot and the word drift apart.
    #expect(source.contains("let summary = appModel.systemHealthSummary"))
    #expect(source.contains("let label = label(for: summary)"))
    #expect(source.contains("let statusColor = color(for: summary)"))
}
