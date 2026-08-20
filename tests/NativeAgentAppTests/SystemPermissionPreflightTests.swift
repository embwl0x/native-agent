import Foundation
import Testing
@testable import NativeAgentApp

/// PATCH-2026-08-18. Root cause 130dc377: Apple Speech became load-bearing for
/// a HEADLESS pipeline while its only consent prompt stayed behind an in-app
/// button, so the grant sat unacquired forever and every voice note failed.
///
/// These tests drive the PURE judgement seam from hand-built snapshots. Host TCC
/// state is deliberately never read here — it is not test input, it varies per
/// machine, and a test that asserts against it proves nothing on CI.
@Suite("System permission preflight")
struct SystemPermissionPreflightTests {
    @Test
    func speechAuthorizationCompletionMayArriveOffMainActor() async {
        let status = await SystemPermissionPreflight.awaitSpeechAuthorization { @Sendable completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(.authorized)
            }
        }

        #expect(status == .authorized)
    }


    private func snapshot(
        _ capability: SystemPermissionCapability,
        _ status: SystemPermissionStatus
    ) -> SystemPermissionSnapshot {
        SystemPermissionSnapshot(capability: capability, status: status)
    }

    // MARK: - healthWarnings

    @Test("never-approved speech recognition is warned — the exact bug shape")
    func notDeterminedSpeechIsWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [snapshot(.speechRecognition, .notDetermined)]
        )
        #expect(warnings.count == 1)
        #expect(warnings.first?.capability == .speechRecognition)
    }

    @Test("denied speech recognition is warned")
    func deniedSpeechIsWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [snapshot(.speechRecognition, .denied)]
        )
        #expect(warnings.map(\.capability) == [.speechRecognition])
    }

    @Test("restricted speech recognition is warned")
    func restrictedSpeechIsWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [snapshot(.speechRecognition, .restricted)]
        )
        #expect(warnings.map(\.capability) == [.speechRecognition])
    }

    @Test("granted speech recognition raises nothing")
    func grantedSpeechIsNotWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [snapshot(.speechRecognition, .granted)]
        )
        #expect(warnings.isEmpty)
    }

    /// `.unknown` means "could not read without prompting", NOT "missing".
    /// Warning on it would put a permanent card in front of the user that no
    /// action can ever clear — the dead-end-alert bug class.
    @Test("unknown status never warns, so unreadable state cannot become a permanent false alarm")
    func unknownStatusIsNotWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [
                snapshot(.speechRecognition, .unknown),
                snapshot(.automation, .unknown),
                snapshot(.notifications, .unknown),
            ]
        )
        #expect(warnings.isEmpty)
    }

    /// The discriminator that makes this a bug-class fix rather than a one-off.
    /// Microphone is denied here too, but it is only ever reached from a
    /// user-initiated in-app action that fires its own prompt at point of use —
    /// so it is not an orphaned grant and must not produce a card.
    @Test("denied microphone is NOT warned — it is not headless-load-bearing")
    func deniedMicrophoneIsNotWarned() {
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: [snapshot(.microphone, .denied)]
        )
        #expect(warnings.isEmpty)
    }

    @Test("non-headless capabilities are all excluded even when denied")
    func nonHeadlessCapabilitiesExcluded() {
        let denied: [SystemPermissionCapability] = [
            .microphone, .screenRecording, .calendars, .reminders, .contacts,
        ]
        let warnings = SystemPermissionPreflight.healthWarnings(
            from: denied.map { snapshot($0, .denied) }
        )
        #expect(warnings.isEmpty)
    }

    @Test("mixed set surfaces only the orphanable, non-granted capabilities")
    func mixedSetFiltersCorrectly() {
        let warnings = SystemPermissionPreflight.healthWarnings(from: [
            snapshot(.speechRecognition, .denied),      // warn
            snapshot(.accessibility, .granted),         // headless but fine
            snapshot(.automation, .unknown),            // unreadable, stays quiet
            snapshot(.microphone, .denied),             // not headless
            snapshot(.notifications, .notDetermined),   // warn
        ])
        #expect(Set(warnings.map(\.capability)) == [.speechRecognition, .notifications])
    }

    // MARK: - isHeadlessLoadBearing

    /// Pins the classification itself. If someone later makes a capability
    /// load-bearing for a background path, this test is where the change has to
    /// be declared — the point is that the answer lives in the type, not in
    /// someone's memory.
    @Test("headless-load-bearing classification is explicit for every capability")
    func headlessClassificationIsPinned() {
        let headless = Set(
            SystemPermissionCapability.allCases.filter(\.isHeadlessLoadBearing)
        )
        #expect(headless == [.speechRecognition, .accessibility, .automation, .notifications])
    }

    // MARK: - warningSummary

    @Test("summary names both the capability and the System Settings pane")
    func summaryNamesCapabilityAndPane() {
        for status: SystemPermissionStatus in [.notDetermined, .denied, .restricted] {
            let text = SystemPermissionPreflight.warningSummary(
                for: snapshot(.speechRecognition, status)
            )
            #expect(text.contains("Speech Recognition"))
            #expect(text.contains("System Settings"))
            #expect(text.contains("Privacy & Security"))
        }
    }

    /// The denied copy must say macOS will not ask again. A user who is told
    /// only "it is denied" will keep pressing an in-app button that is a silent
    /// no-op, because TCC refuses to re-prompt a resolved grant.
    @Test("denied copy states that macOS will not re-prompt")
    func deniedCopyExplainsNoReprompt() {
        let text = SystemPermissionPreflight.warningSummary(
            for: snapshot(.speechRecognition, .denied)
        )
        #expect(text.lowercased().contains("not re-prompt") || text.lowercased().contains("will not re-prompt"))
    }

    @Test("never-approved copy is distinct from the denied copy")
    func notDeterminedCopyIsDistinct() {
        let never = SystemPermissionPreflight.warningSummary(
            for: snapshot(.speechRecognition, .notDetermined)
        )
        let denied = SystemPermissionPreflight.warningSummary(
            for: snapshot(.speechRecognition, .denied)
        )
        #expect(never != denied)
        #expect(never.contains("never been approved"))
    }

    // MARK: - settings deep link

    @Test("every Privacy-pane capability produces a usable System Settings URL")
    func settingsURLsResolve() throws {
        let url = try #require(SystemPermissionPreflight.settingsURL(for: .speechRecognition))
        #expect(url.absoluteString.hasPrefix("x-apple.systempreferences:"))
        #expect(url.absoluteString.hasSuffix("Privacy_SpeechRecognition"))
    }

    /// Notifications do not live under Privacy & Security, so returning a
    /// Privacy anchor for it would deep-link the user to the wrong pane.
    @Test("notifications has no Privacy pane anchor rather than a wrong one")
    func notificationsHasNoPrivacyAnchor() {
        #expect(SystemPermissionPreflight.settingsURL(for: .notifications) == nil)
    }
}
