import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.macIntegration.permissionRequestFailedAlert
@Suite("Mac integration permission request failure alert", .serialized)
struct MacIntegrationPermissionRequestFailedAlertEvalTests {
    @Test("every framework request failure identifies the permission that failed")
    func failureCopyNamesEachFrameworkPermission() {
        #expect(Set(MacIntegrationFrameworkPermission.allCases) == Set([
            .calendar, .reminders, .contacts, .speechRecognition, .microphone,
        ]))

        for permission in MacIntegrationFrameworkPermission.allCases {
            let message = MacIntegrationPermissionFailurePresentation.registrationFailureMessage(for: permission)
            #expect(message.contains(permission.label), "failure copy lost the affected permission: \(permission)")
            #expect(message.contains("NativeAgent"))
        }
        #expect(MacIntegrationPermissionFailurePresentation.registrationFailureMessage(for: .calendar)
            .contains("Calendar entitlement"))
    }

    @Test("save and request failures remain independently bound")
    func alertGatesCannotSwapTheirErrorStates() {
        #expect(MacIntegrationPermissionFailurePresentation.saveAlertTitle == "Permission Save Failed")
        #expect(MacIntegrationPermissionFailurePresentation.requestAlertTitle == "Permission Request Failed")

        #expect(MacIntegrationPermissionFailurePresentation.saveAlertIsPresented(
            persistenceError: "could not persist", requestError: nil
        ))
        #expect(!MacIntegrationPermissionFailurePresentation.requestAlertIsPresented(
            persistenceError: "could not persist", requestError: nil
        ))

        #expect(!MacIntegrationPermissionFailurePresentation.saveAlertIsPresented(
            persistenceError: nil, requestError: "TCC did not prompt"
        ))
        #expect(MacIntegrationPermissionFailurePresentation.requestAlertIsPresented(
            persistenceError: nil, requestError: "TCC did not prompt"
        ))

        #expect(MacIntegrationPermissionFailurePresentation.saveAlertIsPresented(
            persistenceError: "could not persist", requestError: "TCC did not prompt"
        ))
        #expect(MacIntegrationPermissionFailurePresentation.requestAlertIsPresented(
            persistenceError: "could not persist", requestError: "TCC did not prompt"
        ))
    }
}
