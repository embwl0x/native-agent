import MacIntegration

// Blueprint: | `ToolPreloadHeuristics.swift` | `ToolPreloadHeuristics`: shared dispatch-time Mac Integration permission table, without lexical turn-intent inference |

/// Shared tool policy tables; turn intent is not inferred from message text.
public enum ToolPreloadHeuristics {
    /// Dispatch-time Mac Integration permissions, also used by the parallel write veto (owned by `MacIntegrationGates`).
    package static let macIntegrationGates = MacIntegrationGates.byTool

}
