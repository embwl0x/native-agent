import Foundation
import Testing
import PersistenceCore
@testable import SwarmRuns

@Test func toolContractSwarmObjectiveAndBoundModel() throws {
    let policy = AgentSwarmPolicy(defaultModel: "work-model")
    for key in ["objective", "query", "prompt", "task"] {
        let input: [String: JSONValue] = [key: .string("Review the proposed change"),
            "model": .string("work-model"), "agents": .null, "workers": .null, "synthesize": .null]
        let request = try AgentSwarmRunRequest.parse(input: input, policy: policy)
        #expect(request.objective == "Review the proposed change")
    }
    do {
        _ = try AgentSwarmRunRequest.parse(input: ["objective": .null], policy: policy)
        Issue.record("Missing objective accepted")
    } catch {
        #expect(error.localizedDescription.contains("objective: \"Review the proposed change\""))
    }
    #expect(throws: AgentSwarmError.self) {
        try AgentSwarmRunRequest.parse(input: ["objective": .string("Review"), "model": .string("other-model")], policy: policy)
    }
}
