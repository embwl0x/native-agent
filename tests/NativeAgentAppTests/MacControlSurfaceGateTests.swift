import Foundation
import MacControl
import Testing
import TrustCenter
@testable import NativeAgentApp

// Ledger fence app.mac — rows `ui.macControl.workbench`,
// `ui.macControl.enableMacAccessAndProbe`, `ui.macControl.unsavedBadge`, and
// `route.assistantWatchRefreshToken`.
//
// The Mac Control page is the most consequential surface in this fence: a live
// shell runner, a file writer, and the only in-app view of what the agent did
// to the Mac. Its workbench catalog owns the route and gate for each action,
// while its cross-panel refresh is a bare @State integer.

private func macControlSource() throws -> String {
    try AppSourceScraping.appSource("MacControlPermissionsView.swift")
}

// MARK: - workbench action catalog and gates

@Test("every mounted workbench action is natively implemented and policy-gated")
func macControlWorkbench_everyActionCarriesAllThreeClauses() throws {
    let source = try macControlSource()
    let enabledPolicy = TrustMacControlPolicy(
        enabled: true,
        fileOpsAllowed: true,
        shellAllowed: true,
        notificationsAllowed: true
    )

    // The workbench is driven by this production action catalog, rather than
    // duplicated button predicates. It must never advertise a core 501 action.
    #expect(Set(MacControlWorkbenchAction.allCases.map(\.rawValue)).isDisjoint(with: macControlUnsupportedActions))
    #expect(Set(MacControlWorkbenchAction.allCases.map(\.title)) == Set(["Run Shell", "Read File", "Write File", "Notify"]))

    for action in MacControlWorkbenchAction.allCases {
        #expect(action.availability(policy: enabledPolicy, policySaved: true).isEnabled)
        #expect(!action.availability(policy: enabledPolicy, policySaved: false).isEnabled)
        #expect(!action.availability(policy: TrustMacControlPolicy(), policySaved: true).isEnabled)
    }

    // Keep the view mounted to the action catalog, so a future ad-hoc route
    // cannot bypass these behavioral checks.
    #expect(source.contains("workbenchButton(.shell"))
    #expect(source.contains("workbenchButton(.fileRead"))
    #expect(source.contains("workbenchButton(.fileWrite"))
    #expect(source.contains("workbenchButton(.notify"))
    #expect(!source.contains("Run Shortcut"))
    #expect(!source.contains("Run System Action"))
    for unsupported in macControlUnsupportedActions {
        #expect(!source.contains("\"/v1/mac_control/\(unsupported)\""),
                "unsupported action \(unsupported) must not regain a literal workbench route")
    }
}

// MARK: - the Apple-data probe's connector ids (silent zero)

@Test("both probe action ids exist in the live connector registry")
func macControlProbe_actionIdsResolveInTheRegistry() throws {
    let source = try macControlSource()
    let probe = try #require(
        AppSourceScraping.looseFunctionBody(named: "probeAppleDataAccess", in: source),
        "probeAppleDataAccess not found"
    )

    // Scrape the literals the view actually sends rather than hard-coding them
    // here: a rename in the view alone must not be able to pass this test.
    var ids: [String] = []
    var cursor = probe.startIndex
    while let match = probe.range(of: "id: \"", range: cursor..<probe.endIndex) {
        let rest = probe[match.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { break }
        ids.append(String(rest[..<end]))
        cursor = end
    }
    #expect(ids.count == 2, "expected two probe actions, found \(ids)")

    // This probe exists solely to force the macOS TCC prompts. If either id is
    // renamed the probe fails quietly and the user is told to wait for prompts
    // that will never appear.
    let registry = Set(connectorActionDescriptors().map(\.id))
    for id in ids {
        #expect(registry.contains(id), "probe action '\(id)' is not in the connector registry")
    }
    #expect(Set(ids) == ["mac.calendar_list_upcoming", "mac.reminders_list_due_today"])

    // Enable Mac Access must still chain preset → probe, and must not probe
    // when the preset failed (otherwise the prompts fire against a policy that
    // was never saved).
    let enable = try #require(
        AppSourceScraping.looseFunctionBody(named: "enableMacAccess", in: source)
    )
    let preset = try #require(enable.range(of: "applyIntegrationPreset(.assistant)"))
    let guardRange = try #require(enable.range(of: "guard saveError == nil else { return }"))
    let probeCall = try #require(enable.range(of: "probeAppleDataAccess()"))
    #expect(preset.lowerBound < guardRange.lowerBound)
    #expect(guardRange.lowerBound < probeCall.lowerBound)
}

// MARK: - unsaved-edit clobber guard

@Test("an inbound trust-policy refresh cannot clobber an in-flight save")
func macControlUnsaved_midSaveRefreshIsRefused() throws {
    let source = try macControlSource()

    // `hasUnsavedChanges` must stay a comparison of the two policies — a
    // separate mutable flag drifts out of sync and the badge lies.
    #expect(source.contains("private var hasUnsavedChanges: Bool {"))
    #expect(source.contains("policy != savedPolicy"))

    // The guard: without it a refresh landing mid-save overwrites the user's
    // toggle edits and they vanish between toggle and Save with no message.
    let changeStart = try #require(source.range(of: ".onChange(of: appModel.trustPolicy)"))
    let open = try #require(source[changeStart.upperBound...].firstIndex(of: "{"))
    let close = try #require(
        AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
    )
    let handler = String(source[open...close])
    let guardRange = try #require(
        handler.range(of: "guard !isSaving else { return }"),
        "the mid-save clobber guard is gone"
    )
    let writeRange = try #require(handler.range(of: "policy = mp"))
    #expect(guardRange.lowerBound < writeRange.lowerBound)
    #expect(handler.contains("savedPolicy = mp"))
}

// MARK: - assistant-watch refresh token (stale UI right after the fix)

@Test("the probe refreshes the assistant-watch panel on BOTH its outcomes")
func assistantWatchRefreshToken_bumpsOnSuccessAndOnFailure() throws {
    let source = try macControlSource()

    let probe = try #require(
        AppSourceScraping.looseFunctionBody(named: "probeAppleDataAccess", in: source)
    )
    // A probe that failed still changed what the panel should say — bumping
    // only on success leaves "needs setup" on screen after the grant landed.
    #expect(AppSourceScraping.occurrences(of: "assistantWatchRefreshToken += 1", in: probe) == 2,
            "probeAppleDataAccess must bump on both the success and the catch arm")
    let catchRange = try #require(probe.range(of: "} catch {"))
    let tail = probe[catchRange.upperBound...]
    #expect(tail.contains("assistantWatchRefreshToken += 1"))

    let preset = try #require(
        AppSourceScraping.looseFunctionBody(named: "applyIntegrationPreset", in: source)
    )
    #expect(preset.contains("assistantWatchRefreshToken += 1"))

    // The token is only useful if it is threaded into the child panel and the
    // child actually reloads on change — either half missing makes every bump
    // above dead code.
    #expect(source.contains("MacAssistantWatchSetupView(refreshToken: assistantWatchRefreshToken)"))
    let watch = try AppSourceScraping.appSource("MacAssistantWatchSetupView.swift")
    #expect(watch.contains(".onChange(of: refreshToken)"))
    let onChange = try #require(watch.range(of: ".onChange(of: refreshToken)"))
    let after = watch[onChange.upperBound...].prefix(200)
    #expect(after.contains("load()"), "the refresh token no longer triggers a reload")
}
