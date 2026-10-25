import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
// Blueprint: | `SwiftToolDispatcher+SchemaBuilders.swift` | `SwiftToolDispatcher`: `builtInToolSchemas` |


// MARK: - Schema builders

extension SwiftToolDispatcher {
    func builtInToolSchemas(
        includeFullMacFileTools: Bool = false,
        includeFullMacSystemTools: Bool = false,
        includeFullMacAccessibilityReadTools: Bool = false,
        includeFullMacAccessibilityInjectionTools: Bool = false,
        includeActivityQueryTool: Bool = false,
        standingBotMinimumInterval: TimeInterval,
        requestedNames: Set<String>? = nil
    ) -> [LLMToolSchema] {
        BuiltInToolSchemaFactory(
            requestedNames: requestedNames,
            standingBotMinimumInterval: standingBotMinimumInterval
        ).schemas(
            includeFullMacFileTools: includeFullMacFileTools,
            includeFullMacSystemTools: includeFullMacSystemTools,
            includeFullMacAccessibilityReadTools: includeFullMacAccessibilityReadTools,
            includeFullMacAccessibilityInjectionTools: includeFullMacAccessibilityInjectionTools,
            includeActivityQueryTool: includeActivityQueryTool
        )
    }
}
