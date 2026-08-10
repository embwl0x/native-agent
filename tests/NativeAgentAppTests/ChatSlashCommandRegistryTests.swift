import Testing
@testable import NativeAgentApp

@Suite("Chat slash command registry")
struct ChatSlashCommandRegistryTests {
    @Test func commandNamesAreUniqueAndCoverEveryRoute() {
        #expect(ChatSlashCommandRegistry.commandNames.count == ChatSlashCommandRegistry.all.count)
        #expect(Set(ChatSlashCommandRegistry.all.map(\.route)) == Set(ChatSlashCommandRoute.allCases))
    }

    @Test func developerVisibilityAndHelpUseTheSameRegistry() {
        let regular = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: false)
        let developer = ChatSlashCommandRegistry.visible(showDeveloperSurfaces: true)
        let regularHelp = ChatSlashCommandRegistry.helpText(showDeveloperSurfaces: false)
        let developerHelp = ChatSlashCommandRegistry.helpText(showDeveloperSurfaces: true)

        #expect(!regular.contains { $0.command == "nextgen" })
        #expect(developer.contains { $0.command == "nextgen" })
        #expect(!regularHelp.contains("/nextgen"))
        #expect(developerHelp.contains("/nextgen"))
        for command in regular {
            #expect(regularHelp.contains(command.displayedInvocation))
        }
    }
}
