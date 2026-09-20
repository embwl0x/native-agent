import Testing
@testable import NativeAgentApp

@MainActor
struct OnboardingNameFieldsTests {
    @Test func suggestedNameIsEditableAndSurvivesNavigation() {
        let state = OnboardingWizardState()
        #expect(!state.agentName.isEmpty)
        #expect(state.agentName == state.suggestedName)
        #expect(!state.canContinue)
        #expect(state.missingNamesMessage == "Enter your name.")

        state.userName = "Visitor"
        #expect(state.canContinue)
        #expect(state.missingNamesMessage == nil)
        state.agentName = "Helper"
        state.step = .provider
        state.goBack()
        #expect(state.agentName == "Helper")
        #expect(state.canContinue)
    }

    @Test func clearedNamesExplainWhatIsMissingIncludingRepair() {
        let state = OnboardingWizardState()
        state.userName = "Visitor"
        state.agentName = " \n"
        #expect(!state.canContinue)
        #expect(state.missingNamesMessage == "Enter an agent name.")
        state.userName = "\t"
        #expect(!state.canContinue)
        #expect(state.missingNamesMessage == "Enter your name and an agent name.")

        state.step = .profileRepair
        #expect(state.trimmedAgentName.isEmpty)
        #expect(state.missingNamesMessage == "Enter your name and an agent name.")
        state.agentName = "Helper"
        state.userName = "Visitor"
        #expect(state.missingNamesMessage == nil)
    }
}
