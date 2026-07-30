import Testing
import PersistenceCore
@testable import MCPDispatcher

@Test
func mcpInvocationOutcomeNormalizesRawAndAdapterWrappedErrors() {
    let rawSuccess: JSONValue = .object([
        "content": .array([]),
        "isError": .bool(false),
    ])
    let rawError: JSONValue = .object([
        "content": .array([]),
        "isError": .bool(true),
    ])
    let wrappedError: JSONValue = .object([
        "status": .string("ok"),
        "result": rawError,
    ])

    #expect(MCPInvocationOutcome.classify(response: rawSuccess).kind == .responseReceived)
    #expect(MCPInvocationOutcome.classify(response: rawError).kind == .remoteReportedError)
    #expect(MCPInvocationOutcome.classify(response: wrappedError).kind == .remoteReportedError)
    #expect(MCPInvocationOutcome.classify(response: wrappedError).providerToolResultIsError)
    #expect(MCPInvocationOutcome.classify(response: wrappedError).displayStatus == "error")
}

@Test
func mcpInvocationOutcomeInspectsOnlyTheProtocolEnvelope() {
    let successfulBusinessPayload: JSONValue = .object([
        "status": .string("ok"),
        "result": .object([
            "status": .string("ok"),
            "data": .object([
                "isError": .bool(true),
                "description": .string("a quoted downstream field, not MCP protocol state"),
            ]),
        ]),
    ])
    #expect(MCPInvocationOutcome.classify(response: successfulBusinessPayload).kind == .responseReceived)
}
