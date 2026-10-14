import Foundation

public func reasoningOptions<Option>(available: [Option], supported: [String]?, id: (Option) -> String) -> [Option] {
    guard let supported, !supported.isEmpty else { return available }
    return available.filter { supported.contains(id($0)) }
}

public func normalizedReasoningEffort(options: [String], preferred: String?, selected: String) -> String {
    if options.contains(selected) { return selected }
    if let preferred, options.contains(preferred) { return preferred }
    return options.first ?? "high"
}
