import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Doctor.openOAuthLoginButton
@Suite("Doctor OAuth login button")
struct DoctorOAuthLoginButtonEvalTests {
    @Test("device fallback is an unconditional secondary recovery control")
    func fallbackDoesNotDependOnDoctorReport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NativeAgentApp/DoctorView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "            DisclosureGroup(\"Technical sign-in options\")"))
        let end = try #require(source.range(of: "            Label(safeRepairState.detail", range: start.upperBound..<source.endIndex))
        let disclosure = String(source[start.lowerBound..<end.lowerBound])
        #expect(disclosure.contains("Task { await openOAuthLogin() }"))
        #expect(disclosure.contains("doctor.openOAuthLogin"))
        #expect(!disclosure.contains("doctorReport"))
        #expect(!source.contains("needsLegacyCodexLogin"))
        #expect(source.contains("doctor.openProviders"))
    }

    @Test("device sign-in controls use neutral copy")
    func fallbackControlCopyIsNeutral() {
        #expect(DoctorOAuthLoginButtonPresentation.buttonTitle == "Open device sign-in (fallback)")
        #expect(DoctorOAuthLoginButtonPresentation.openingTitle == "Opening device sign-in…")
        #expect(DoctorOAuthLoginButtonPresentation.panelTitle == "Device sign-in (fallback)")
    }

    @Test("the Doctor receipt claims a browser only when the device-login receipt confirms it")
    func browserConfirmationIsNotInferredFromLoginStart() {
        let opened = DoctorOAuthLoginButtonPresentation.notice(for: .started(login(
            url: "https://auth.openai.com/codex/device",
            code: "ABCD-1234",
            openedBrowser: true
        )))
        #expect(opened == .init(
            detail: "Device sign-in is ready; its browser page was opened. Enter the code shown below.",
            tone: .success
        ))

        let notConfirmed = DoctorOAuthLoginButtonPresentation.notice(for: .started(login(
            url: "https://auth.openai.com/codex/device",
            code: "ABCD-1234",
            openedBrowser: false
        )))
        #expect(notConfirmed == .init(
            detail: "Device sign-in is ready. Open the link shown below and enter the code.",
            tone: .success
        ))
    }

    @Test("pending, unavailable, and terminal outcomes remain visibly distinct")
    func adverseAndPendingOutcomesAreHonest() {
        let pending = DoctorOAuthLoginButtonPresentation.notice(for: .started(login()))
        #expect(pending == .init(
            detail: "Device sign-in process started; waiting for device-login instructions.",
            tone: .progress
        ))

        let unavailable = DoctorOAuthLoginButtonPresentation.notice(for: .failed("   "))
        #expect(unavailable == .init(
            detail: "Could not start Device sign-in: no error detail was returned",
            tone: .failure
        ))

        let terminated = DoctorOAuthLoginButtonPresentation.notice(for: .started(login(
            running: false,
            detail: "codex executable exited with code 127"
        )))
        #expect(terminated == .init(
            detail: "Device sign-in ended before it produced a usable device code. codex executable exited with code 127",
            tone: .failure
        ))
    }

    private func login(
        running: Bool? = true,
        url: String? = nil,
        code: String? = nil,
        openedBrowser: Bool? = false,
        detail: String? = "codex device-login running"
    ) -> CodexDeviceLogin {
        CodexDeviceLogin(
            running: running,
            pid: 42,
            url: url,
            code: code,
            expiresInMinutes: nil,
            openedBrowser: openedBrowser,
            codexHome: nil,
            loginCommand: nil,
            detail: detail,
            exitCode: running == true ? nil : 127,
            startedAt: nil,
            finishedAt: running == true ? nil : "2026-08-24T00:00:00Z"
        )
    }
}
