import Foundation

public struct CompiledPersonalityWire: Sendable, Equatable, Codable {
    public let surface: String
    public let fingerprint: String
    public let compiled: String

    public init(surface: String, fingerprint: String, compiled: String) {
        self.surface = surface
        self.fingerprint = fingerprint
        self.compiled = compiled
    }
}

extension PersonaCompiler {
    /// Diagnostic projection of the same selected persona used by live turns.
    /// Missing fixed persona docs are scaffolded first so the packet reflects
    /// persisted defaults (SOUL.md first, USER.md skipped — MemoryV2 owns it —
    /// each write locked); scaffold failures propagate.
    public func compiledPacket(surface: String) async throws -> CompiledPersonalityWire {
        _ = try await engine.scaffoldMissingDocs()
        let packet = try await compile(surface: surface)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let compiled = String(decoding: try encoder.encode(packet), as: UTF8.self)
        return CompiledPersonalityWire(
            surface: packet.surface, fingerprint: packet.fingerprint, compiled: compiled
        )
    }
}
