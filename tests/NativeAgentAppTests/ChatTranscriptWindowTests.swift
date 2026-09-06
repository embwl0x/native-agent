import Testing
@testable import NativeAgentApp

@Test func transcriptWindowRemainsBoundedThroughSearchAndAllPages() {
    let count = 10_000
    #expect(ChatTranscriptWindow.range(count: count) == 9700..<10000)
    #expect(ChatTranscriptWindow.range(count: count, start: -150).contains(0))
    for start in stride(from: -300, through: count + 300, by: 150) {
        let page = ChatTranscriptWindow.range(count: count, start: start)
        #expect(page.count <= 300)
        #expect(page.lowerBound >= 0 && page.upperBound <= count)
    }
    #expect(ChatTranscriptWindow.range(count: 0).isEmpty)
    #expect(ChatTranscriptWindow.range(count: 23) == 0..<23)
}
