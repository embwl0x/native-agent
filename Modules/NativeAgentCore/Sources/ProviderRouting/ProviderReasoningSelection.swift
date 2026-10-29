import Foundation
// Blueprint: | `ProviderReasoningSelection.swift` | Normalizes reasoning selection; NativeAgentShared owns supported-choice filtering |

public func normalizedReasoningEffort(options: [String], preferred: String?, selected: String) -> String {
    if options.contains(selected) { return selected }
    if let preferred, options.contains(preferred) { return preferred }
    return options.first ?? "high"
}
