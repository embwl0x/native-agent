import BackgroundWork

extension BackgroundLoopsAssembly {
    static let unconfiguredLaneInterval = UnconfiguredBackgroundLane.unconfiguredLaneInterval
    static let telegramUnconfiguredReason = UnconfiguredBackgroundLane.telegramUnconfiguredReason
    static let slackUnconfiguredReason = UnconfiguredBackgroundLane.slackUnconfiguredReason

    static func unconfiguredLanePlaceholder(
        loopId: String, reason: String
    ) -> UnconfiguredBackgroundLane.UnconfiguredLaneLoop {
        UnconfiguredBackgroundLane.unconfiguredLanePlaceholder(loopId: loopId, reason: reason)
    }
}
