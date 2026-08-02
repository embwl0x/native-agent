import Foundation
import MemoryV2
import Onboarding
import Testing
@testable import NativeAgentApp

// fix-blank-install-onboarding (2026-08-02): end-to-end proof that a blank
// install still needs onboarding after a launch pass.
//
// The defect was a race between two launch-time actors over the SAME file:
// AppDelegate's launch task ran `UserMDGenerator.regenerate()` unconditionally,
// which wrote `<personaRoot>/USER.md` even with zero memories, while the
// wizard's `startOnboarding()` treated any USER.md as proof of an existing
// identity. Launch first → the wizard never appeared. Wizard first → its Build
// died on `persona_already_exists`, and the retry path then read `hasExisting`
// and dismissed the wizard as if it had succeeded.
//
// These tests drive both orderings against real files in a temp root and
// require the SAME outcome, so the fix is proven order-independent rather than
// merely winning the race in practice. Nothing here touches the live data root.
@Suite("Blank install onboarding reachability")
struct BlankInstallOnboardingReachabilityTests {
    private struct Install {
        let base: URL
        let dataRoot: URL
        let personaRoot: URL
        var userMD: URL { personaRoot.appendingPathComponent("USER.md") }
        var soul: URL { personaRoot.appendingPathComponent("SOUL.md") }
        var sentinel: URL { dataRoot.appendingPathComponent(".onboarded") }
    }

    private func blankInstall() throws -> Install {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blank-install-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let personaRoot = base.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        // personaRoot is deliberately NOT created: a blank machine has none,
        // and the generator used to create it as a side effect.
        return Install(base: base, dataRoot: dataRoot, personaRoot: personaRoot)
    }

    /// The exact launch-time call AppDelegate makes, against a temp root.
    private func runLaunchUserMDPass(_ install: Install) async throws {
        let storage = try MemoryStorage(dataRoot: install.dataRoot)
        let generator = UserMDGenerator(
            storage: storage,
            dataRoot: install.dataRoot,
            personaRoot: install.personaRoot
        )
        _ = try? await generator.regenerate(persona: MemoryV2Defaults.personaID)
    }

    @Test("launch first: the launch pass leaves onboarding required")
    func launchBeforeWizardLeavesOnboardingRequired() async throws {
        let install = try blankInstall()
        defer { try? FileManager.default.removeItem(at: install.base) }

        try await runLaunchUserMDPass(install)

        // Old behavior: USER.md (header only) existed here, and hasExisting was
        // true — the wizard was never shown on a blank machine.
        #expect(!FileManager.default.fileExists(atPath: install.userMD.path))
        let client = SwiftNativeOnboardingClient(
            personaRoot: install.personaRoot,
            dataRoot: install.dataRoot
        )
        let start = try await client.startOnboarding()
        #expect(start.hasExisting == false)
        #expect(start.resetRequired == false)
    }

    @Test("wizard first: Build succeeds and a later launch pass is a no-op")
    func wizardBeforeLaunchCompletesCleanly() async throws {
        let install = try blankInstall()
        defer { try? FileManager.default.removeItem(at: install.base) }

        let client = SwiftNativeOnboardingClient(
            personaRoot: install.personaRoot,
            dataRoot: install.dataRoot
        )
        #expect(try await client.startOnboarding().hasExisting == false)
        let built = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        // Old behavior on this ordering: `persona_already_exists`, because the
        // launch pass had already planted USER.md.
        #expect(built.ok == true, "Build must succeed on a blank install: \(built.error ?? "-")")
        #expect(FileManager.default.fileExists(atPath: install.soul.path))
        #expect(FileManager.default.fileExists(atPath: install.sentinel.path))

        let userBefore = try String(contentsOf: install.userMD, encoding: .utf8)
        try await runLaunchUserMDPass(install)
        // Post-onboarding the generator is allowed to run; with zero memories
        // it only rewrites its own body and must not destroy the identity doc.
        let userAfter = try String(contentsOf: install.userMD, encoding: .utf8)
        #expect(!userAfter.isEmpty)
        #expect(userBefore.isEmpty == false)
        #expect(try await client.startOnboarding().hasExisting == true)
    }

    @Test("both orderings agree: onboarding is required exactly once")
    func orderingIsDeterministic() async throws {
        var outcomes: [Bool] = []
        for launchFirst in [true, false] {
            let install = try blankInstall()
            defer { try? FileManager.default.removeItem(at: install.base) }
            let client = SwiftNativeOnboardingClient(
                personaRoot: install.personaRoot,
                dataRoot: install.dataRoot
            )
            if launchFirst {
                try await runLaunchUserMDPass(install)
                outcomes.append(try await client.startOnboarding().hasExisting)
            } else {
                outcomes.append(try await client.startOnboarding().hasExisting)
                try await runLaunchUserMDPass(install)
            }
        }
        #expect(outcomes == [false, false], "launch order must not decide whether onboarding runs")
    }

    // MARK: - Wizard: a failed Build is never completion

    @Test("a failed Build never dismisses the wizard as successful")
    @MainActor func failedBuildIsNotCompletion() {
        // Old behavior: `hasExisting` always meant onComplete(), so a Build
        // that failed with persona_already_exists closed the wizard silently.
        #expect(OnboardingWizard.existingPersonaDisposition(buildFailed: true) == .blockedNeedsReset)
        #expect(OnboardingWizard.existingPersonaDisposition(buildFailed: false) == .alreadyOnboarded)
    }

    @Test("persona_already_exists surfaces as guidance, not a raw error code")
    @MainActor func buildFailureCopyIsHumanReadable() {
        let message = OnboardingWizard.buildFailureMessage(error: "persona_already_exists", detail: nil)
        #expect(!message.contains("persona_already_exists"))
        #expect(message.lowercased().contains("reset"))
        #expect(OnboardingWizard.buildFailureMessage(error: "template_error", detail: "boom") == "boom")
    }

    // MARK: - A failed Doctor repair is never completion (gpt-5.5 BLOCKING 2)
    //
    // `finishSuccessfulOnboarding` used to DISCARD the repair result, and
    // `runDoctor` returned true whenever a report came back at all — even one
    // whose rollup was "fail". So a repair that threw, or that reported an
    // unrepaired store, still wrote the first-run welcome marker and showed
    // "<Agent> is ready" over a broken scaffold. The two questions now live on
    // separate members of the outcome type.

    private func check(_ id: String, _ status: String) -> DoctorCheck {
        DoctorCheck(id: id, title: id, status: status, detail: "detail for \(id)", repair: nil)
    }

    @Test("a run that never produced a report is not a success")
    func unavailableRunIsNotSuccess() {
        let outcome = AppModel.DoctorRunOutcome.unavailable("A Doctor run is already in progress.")
        #expect(outcome.didRun == false)
        #expect(outcome.failingScaffoldChecks.isEmpty)
        #expect(outcome.failureDetail.contains("already in progress"))
    }

    @Test("a completed run with a failing scaffold check is not a success")
    func failingScaffoldCheckBlocksCompletion() {
        let outcome = AppModel.DoctorRunOutcome.completed(
            status: "fail",
            failingChecks: [check("stores.runtime_json", "fail")]
        )
        // Old behavior: this returned `true` and the wizard showed `.done`.
        #expect(outcome.didRun == true)
        #expect(outcome.failingScaffoldChecks.map(\.id) == ["stores.runtime_json"])
    }

    /// The `live.*` namespace covers optional, user-configured subsystems
    /// (Telegram token, SearXNG URL). They are real Doctor findings but they are
    /// NOT the app-owned scaffold — blocking onboarding on them would strand a
    /// user who deliberately skipped provider/Telegram setup in the wizard.
    @Test("a failing live.* check does not block onboarding")
    func liveCoverageFailureDoesNotBlock() {
        let outcome = AppModel.DoctorRunOutcome.completed(
            status: "fail",
            failingChecks: [check("live.telegram", "fail"), check("live.search", "fail")]
        )
        #expect(outcome.didRun == true)
        #expect(outcome.failingScaffoldChecks.isEmpty)
    }

    @Test("a clean run is the only shape that completes onboarding")
    func cleanRunCompletes() {
        let outcome = AppModel.DoctorRunOutcome.completed(status: "ok", failingChecks: [])
        #expect(outcome.didRun == true)
        #expect(outcome.failingScaffoldChecks.isEmpty)
    }

    @Test("scaffold failure copy is honest and actionable, never 'ready'")
    @MainActor func scaffoldFailureCopyIsHonest() {
        let thrown = OnboardingWizard.scaffoldRepairFailureMessage(.unavailable("disk full"))
        #expect(thrown.contains("disk full"))
        #expect(thrown.lowercased().contains("retry"))
        #expect(thrown.lowercased().contains("not ready yet"), "must not imply the install is usable")
        #expect(!thrown.lowercased().contains("is ready"))

        let failed = OnboardingWizard.scaffoldRepairFailureMessage(
            .completed(status: "fail", failingChecks: [check("stores.runtime_json", "fail")])
        )
        // Names the failing check so the user knows WHAT to fix...
        #expect(failed.contains("stores.runtime_json"))
        // ...and says the identity docs did land, so nothing reads as lost.
        #expect(failed.lowercased().contains("identity documents were written"))
        #expect(failed.lowercased().contains("diagnostics"))
    }
}
