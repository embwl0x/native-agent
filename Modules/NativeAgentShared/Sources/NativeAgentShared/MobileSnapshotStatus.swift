import CryptoKit
import Foundation

#if canImport(Compression)
import Compression
#endif

/// Rebuildable Mac-owned read projections carried through the existing
/// CloudKit `NAStatus` transport. Public Developer ID builds cannot use
/// CloudDocuments, so these bounded bundles preserve the established snapshot
/// file contracts without inventing a second model or authority on iOS.
public enum NAMobileSnapshotGroup: String, CaseIterable, Codable, Sendable {
    case core
    case catalog
    case chat
    case activity
    case advanced

    public var statusKey: String {
        "mobile_snapshot_\(rawValue)_v1"
    }

    public var filenames: [String] {
        switch self {
        case .core:
            [
                "trust_policy.json",
                "personality.json",
                "health.json",
                "organism_living_status.json",
                "sessions.json",
                "pinned_chat_sessions.json",
                "connectors.json",
                "providers.json",
                "model_preferences.json",
                "approvals.json",
            ]
        case .catalog:
            [
                "skills_snapshot.json",
                "tools_snapshot.json",
            ]
        case .chat:
            [
                "chat_transcripts.json",
            ]
        case .activity:
            [
                "workshop_tasks.json",
                "memories.json",
                "memory_proposals.json",
                "training_proposals.json",
                "promotion_candidates.json",
                "inbox.json",
            ]
        case .advanced:
            [
                "turn_summaries.json",
                "command_palette.json",
                "knowledge_graph.json",
                "runs.json",
            ]
        }
    }

    public static func groups(containingAny filenames: Set<String>) -> Set<Self> {
        Set(allCases.filter { !filenames.isDisjoint(with: $0.filenames) })
    }
}

private struct NAMobileSnapshotPayload: Codable {
    var files: [String: Data]
}

private struct NAMobileSnapshotEnvelope: Codable {
    var version: Int
    var group: NAMobileSnapshotGroup
    var encoding: String
    var uncompressedBytes: Int
    var payloadSHA256: String
    var payloadBase64: String
}

public enum NAMobileSnapshotStatusCodec {
    public static let currentVersion = 1
    public static let maximumStatusBytes = 800 * 1024
    public static let maximumUncompressedBytes = 8 * 1024 * 1024

    public static func encode(
        group: NAMobileSnapshotGroup,
        files: [String: Data]
    ) throws -> String {
        let allowed = Set(group.filenames)
        guard !files.isEmpty,
              files.keys.allSatisfy({ allowed.contains($0) }) else {
            throw DeviceSyncError.underlying(
                message: "mobile snapshot \(group.rawValue) contained an unsupported or empty file set"
            )
        }
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        let payload = try payloadEncoder.encode(NAMobileSnapshotPayload(files: files))
        guard payload.count <= maximumUncompressedBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: payload.count,
                maximumBytes: maximumUncompressedBytes
            )
        }
        let compressed = try zlibCompress(payload)
        let envelope = NAMobileSnapshotEnvelope(
            version: currentVersion,
            group: group,
            encoding: "zlib+base64",
            uncompressedBytes: payload.count,
            payloadSHA256: sha256(payload),
            payloadBase64: compressed.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= maximumStatusBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: encoded.count,
                maximumBytes: maximumStatusBytes
            )
        }
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw DeviceSyncError.underlying(
                message: "mobile snapshot status was not UTF-8 encodable"
            )
        }
        return value
    }

    public static func decode(
        _ value: String,
        expectedGroup: NAMobileSnapshotGroup
    ) throws -> [String: Data] {
        let encoded = Data(value.utf8)
        guard encoded.count <= maximumStatusBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: encoded.count,
                maximumBytes: maximumStatusBytes
            )
        }
        let envelope = try JSONDecoder().decode(NAMobileSnapshotEnvelope.self, from: encoded)
        guard envelope.version == currentVersion,
              envelope.group == expectedGroup,
              envelope.encoding == "zlib+base64",
              envelope.uncompressedBytes >= 0,
              envelope.uncompressedBytes <= maximumUncompressedBytes,
              let compressed = Data(base64Encoded: envelope.payloadBase64) else {
            throw DeviceSyncError.underlying(message: "invalid mobile snapshot envelope")
        }
        let payload = try zlibDecompress(
            compressed,
            expectedByteCount: envelope.uncompressedBytes
        )
        guard sha256(payload) == envelope.payloadSHA256 else {
            throw DeviceSyncError.underlying(message: "mobile snapshot payload digest mismatch")
        }
        let decoded = try JSONDecoder().decode(NAMobileSnapshotPayload.self, from: payload)
        let allowed = Set(expectedGroup.filenames)
        guard !decoded.files.isEmpty,
              decoded.files.keys.allSatisfy({
                  allowed.contains($0)
                      && URL(fileURLWithPath: $0).lastPathComponent == $0
              }) else {
            throw DeviceSyncError.underlying(message: "mobile snapshot contained an unsupported filename")
        }
        return decoded.files
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func zlibCompress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        guard !data.isEmpty else { return Data() }
        let destinationCapacity = max(data.count + 64 * 1024, 1024)
        var destination = Data(count: destinationCapacity)
        let encodedCount = data.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { output in
                compression_encode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else {
            throw DeviceSyncError.underlying(message: "mobile snapshot compression failed")
        }
        destination.count = encodedCount
        return destination
        #else
        throw DeviceSyncError.notConfigured
        #endif
    }

    private static func zlibDecompress(
        _ data: Data,
        expectedByteCount: Int
    ) throws -> Data {
        #if canImport(Compression)
        guard expectedByteCount > 0 else {
            guard data.isEmpty else {
                throw DeviceSyncError.underlying(message: "invalid empty mobile snapshot payload")
            }
            return Data()
        }
        var destination = Data(count: expectedByteCount)
        let decodedCount = data.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { output in
                compression_decode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!,
                    expectedByteCount,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedByteCount else {
            throw DeviceSyncError.underlying(message: "mobile snapshot decompression failed")
        }
        return destination
        #else
        throw DeviceSyncError.notConfigured
        #endif
    }
}
