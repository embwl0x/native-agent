import Foundation
// Blueprint: | `ProviderReasoningSelection.swift` | Preserves an explicit effort or the row's declared default; capability admission belongs to routing |

public func normalizedReasoningEffort(preferred: String?, selected: String) -> String {
    // A selected value is the person's choice. Admission reports unsupported
    // controls instead of silently selecting a different one.
    selected.isEmpty ? (preferred ?? "") : selected
}
