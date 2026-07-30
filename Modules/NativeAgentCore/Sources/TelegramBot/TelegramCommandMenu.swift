import Foundation

public struct TelegramCommandMenuStatus: Sendable, Codable, Equatable {
    public let commandCount: Int
    public let registryVersion: String
    public let syncedAt: String

    public init(commandCount: Int, registryVersion: String, syncedAt: String) {
        self.commandCount = commandCount
        self.registryVersion = registryVersion
        self.syncedAt = syncedAt
    }
}

public typealias TelegramCommandMenuSync = @Sendable (
    _ token: String,
    _ commands: [TelegramBotCommand]
) async throws -> TelegramCommandMenuStatus
