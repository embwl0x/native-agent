import Testing
@testable import NativeAgentApp

@Suite("Mobile tool catalog projection")
struct MobileToolCatalogProjectionTests {
    @Test("paired iOS snapshot preserves catalog state without granting authority")
    func preservesReadOnlyCatalogState() throws {
        let catalog = ChatToolCatalogSnapshot(
            tools: [
                ChatCatalogTool(
                    name: "calendar_list",
                    description: "List calendar events.",
                    parametersPreview: "start, end",
                    dispatchableVia: "chat",
                    loadState: "on_demand",
                    effectiveAutonomy: "confirm",
                    availableNow: true
                ),
                ChatCatalogTool(
                    name: "time_now",
                    description: "Read the current time.",
                    parametersPreview: nil,
                    dispatchableVia: "chat",
                    loadState: "active",
                    effectiveAutonomy: "auto",
                    availableNow: true
                ),
            ],
            currentlyLoaded: ["time_now"],
            builderAvailable: [],
            builderPolicyLocked: [],
            macAppAvailable: [],
            macAppPolicyLocked: [],
            fullMacActive: false,
            fileOpsAllowed: false,
            systemAllowed: true,
            appControlAllowed: false,
            builderModeDetail: "",
            permissionLevel: "confirm"
        )

        let rows = MobileToolCatalogProjection.records(from: catalog)

        #expect(rows.count == 2)
        #expect(rows[0].id == "calendar_list")
        #expect(rows[0].status == "on_demand")
        #expect(rows[0].riskClass == "confirm")
        #expect(rows[0].autoRun == false)
        #expect(rows[1].id == "time_now")
        #expect(rows[1].status == "active")
        #expect(rows[1].autoRun == true)
    }
}
