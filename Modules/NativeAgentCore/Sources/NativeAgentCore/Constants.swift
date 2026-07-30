import Foundation

// MARK: - Cross-subsystem constants
//
// Single source of truth for constants that need to be shared across multiple
// subsystem modules.

/// The system's primary model id. Used by:
///   - ProviderRouting: fallback model id when neither `provider.chat_model`
///     nor `provider.model` is set, and seeds the per-surface model picker.
///     Subsystem policy deliberately does not own a second model default.
public let nativeAgentPrimaryModel: String = "gpt-5.6-sol"
