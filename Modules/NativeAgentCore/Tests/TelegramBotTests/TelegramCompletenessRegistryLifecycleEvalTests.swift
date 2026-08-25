import Foundation
import Testing
@testable import TelegramBot

@Suite("telegram completeness registry lifecycle")
struct TelegramCompletenessRegistryLifecycleEvalTests {
    // Ledger: telegram.completenessRegistry
    //
    // The registry is process-shared and other suites (CompletenessTests)
    // register bots concurrently, so this test asserts the registry DELTA for
    // the one id it owns — never a global count. The deinit unregisters via a
    // detached Task; `waitForUnregister` is the event-driven completion seam
    // (no sleeps, no polls), bounded by the test's time limit.
    @Test(.timeLimit(.minutes(1)))
    func releasedBotRemovesItsDependenciesAndRegistryReturnsToBaseline() async throws {
        let registry = TelegramBotCompletenessRegistry.shared
        var bot: SwiftNativeTelegramBot? = SwiftNativeTelegramBot(
            dataRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("telegram-registry-\(UUID().uuidString)")
        )
        let identifier = ObjectIdentifier(try #require(bot))
        let idsBeforeRegister = await registry.registeredIDs()
        #expect(!idsBeforeRegister.contains(identifier))
        #expect(await registry.deps(for: identifier) == nil)

        await bot?.registerCompletenessDeps(TelegramBotCompletenessDeps())
        #expect(await registry.deps(for: identifier) != nil)
        let idsAfterRegister = await registry.registeredIDs()
        #expect(idsAfterRegister.contains(identifier))

        bot = nil
        await registry.waitForUnregister(identifier)
        #expect(await registry.deps(for: identifier) == nil)
        let idsAfterRelease = await registry.registeredIDs()
        #expect(!idsAfterRelease.contains(identifier))
    }
}
