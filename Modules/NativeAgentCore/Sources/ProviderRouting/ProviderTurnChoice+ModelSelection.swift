public extension ProviderTurnChoice {
    init(
        provider: String, model: String, reasoningEffort: String, fast: Bool,
        supportedReasoningEfforts: [String], defaultReasoningEffort: String?, supportsFast: Bool?
    ) {
        self.init(
            provider: provider, model: model,
            reasoningEffort: supportedReasoningEfforts.contains(reasoningEffort)
                ? reasoningEffort : (defaultReasoningEffort ?? supportedReasoningEfforts.first ?? "high"),
            fast: supportsFast == true && fast
        )
    }
}
