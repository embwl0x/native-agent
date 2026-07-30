import MemoryV2
import Testing
@testable import NativeAgentApp

@Test func memoryStackPollsOnlyDuringUnresolvedPerformanceModeWarmup() {
    var snapshot = MemoryV2NativeStackSnapshot.empty
    snapshot.coreMLReady = true
    snapshot.embeddingMode = ManagedEmbeddingProvider.balancedMode
    #expect(!snapshot.shouldPollEmbeddingStartup)

    snapshot.embeddingMode = ManagedEmbeddingProvider.performanceMode
    #expect(snapshot.shouldPollEmbeddingStartup)

    snapshot.coreMLLoaded = true
    #expect(!snapshot.shouldPollEmbeddingStartup)

    snapshot.coreMLLoaded = false
    snapshot.coreMLLastLoadError = "load failed"
    #expect(!snapshot.shouldPollEmbeddingStartup)
}
