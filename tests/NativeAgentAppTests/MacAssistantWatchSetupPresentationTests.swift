import Testing
import Foundation
@testable import NativeAgentApp

private func watchSetupResponse(
    status: String = "attention",
    accessStatus: String = "needs_permission",
    templateStatus: String = "needs_permission"
) -> MacAssistantStatusResponse {
    MacAssistantStatusResponse(
        status: status,
        summary: "Calendar permission is required before the daily watch can run.",
        access: [
            MacAssistantAccessItem(
                id: "local_calendar",
                title: "Calendar",
                status: accessStatus,
                detail: "Local Calendar access is checked through the live Mac integration.",
                setupRoute: "mac-integration",
                requiredFor: ["local_calendar_watch"],
                actionIds: ["mac.calendar_list_upcoming"],
                toolNames: ["calendar_list_upcoming"],
                nextStep: "Allow Calendar access when macOS asks."
            ),
        ],
        watchTemplates: [
            MacAssistantWatchTemplate(
                id: "local_calendar_watch",
                title: "Daily Calendar Watch",
                status: templateStatus,
                summary: "Reports upcoming events after Calendar permission is available.",
                scheduleLabel: "Every morning",
                sources: ["Calendar"],
                requiredAccess: ["local_calendar"],
                actionIds: ["scheduler.schedule_job"]
            ),
        ],
        blockedAccessCount: 1,
        templateAttentionCount: 1,
        schedulerActions: ["scheduler.schedule_job"],
        createsJobs: false,
        createdAt: "2026-08-24T00:00:00Z"
    )
}

@Test("Assistant Watch setup preserves real readiness inventory and marks stale refreshes honestly")
func macAssistantWatchSetupPresentationStates() {
    let ready = MacAssistantWatchSetupLoadState.current(watchSetupResponse(
        status: "ready",
        accessStatus: "ready",
        templateStatus: "ready"
    ))
    #expect(ready.isCurrent)
    #expect(ready.badgeText == "Ready")
    #expect(ready.badgeStatus == "ready")

    let response = watchSetupResponse()
    let current = MacAssistantWatchSetupLoadState.current(response)
    #expect(current.isCurrent)
    #expect(current.badgeText == "Attention")
    #expect(current.badgeStatus == "attention")
    #expect(current.diagnosticText == nil)
    #expect(current.response?.access.first?.title == "Calendar")
    #expect(current.response?.access.first?.status == "needs_permission")
    #expect(current.response?.watchTemplates.first?.title == "Daily Calendar Watch")
    #expect(current.response?.watchTemplates.first?.status == "needs_permission")
    #expect(current.response?.createsJobs == false,
            "a setup template must not be presented as a durable watch receipt")

    let stale = current.afterFailure("Couldn’t refresh Assistant Watch setup: bridge unavailable")
    #expect(!stale.isCurrent)
    #expect(stale.badgeText == "Stale")
    #expect(stale.badgeStatus == "attention")
    #expect(stale.diagnosticText?.contains("bridge unavailable") == true)
    // A failed refresh must keep the last inventory visible, but only under an
    // explicit stale badge; hiding it would erase the user's next setup step.
    #expect(stale.response == response)

    let unavailable = MacAssistantWatchSetupLoadState.loading.afterFailure(
        "Couldn’t refresh Assistant Watch setup: service unavailable"
    )
    #expect(!unavailable.isCurrent)
    #expect(unavailable.badgeText == "Unavailable")
    #expect(unavailable.badgeStatus == "failed")
    #expect(unavailable.response == nil)
    #expect(unavailable.diagnosticText?.contains("service unavailable") == true)
}

@MainActor
@Test("an older setup check cannot replace readiness from a newer completed setup action")
func watchSetupLatestReadOwnsReadiness() async {
    let state = MacAssistantWatchSetupReadState()
    var continuation: CheckedContinuation<MacAssistantStatusResponse, Never>?
    let beforeSetup = Task { @MainActor in
        await state.reload { await withCheckedContinuation { continuation = $0 } }
    }
    while continuation == nil { await Task.yield() }
    let ready = watchSetupResponse(status: "ready", accessStatus: "ready", templateStatus: "ready")
    #expect(await state.reload { ready })
    continuation?.resume(returning: watchSetupResponse())
    #expect(!(await beforeSetup.value))
    #expect(state.loadState.response == ready)
    #expect(state.loadState.isCurrent)
    #expect(!state.isLoading)
}

@MainActor
@Test("a failed setup refresh stays stale during retry and cancellation cannot invent a failure")
func watchSetupRetryAndCancellationPreserveEvidence() async {
    let state = MacAssistantWatchSetupReadState()
    #expect(await state.reload { watchSetupResponse() })
    #expect(!(await state.reload { throw NSError(domain: "WatchSetupTest", code: 1) }))
    let stale = state.loadState
    var continuation: CheckedContinuation<MacAssistantStatusResponse, any Error>?
    let retry = Task { @MainActor in
        await state.reload { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    while continuation == nil { await Task.yield() }
    #expect(state.isLoading)
    #expect(state.loadState == stale)
    retry.cancel()
    continuation?.resume(throwing: CancellationError())
    #expect(!(await retry.value))
    #expect(state.loadState == stale)
    #expect(!state.isLoading)
}
