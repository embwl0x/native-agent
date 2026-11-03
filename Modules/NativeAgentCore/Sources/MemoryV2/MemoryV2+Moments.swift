// Retained moment-row interpretation; current provenance belongs to MemoryDataProvenance.

import Transcripts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryV2+Moments.swift` | `MemoryMoments`: retained moment-row vocabulary and recall origin; live provenance and time helpers belong to MemoryDataProvenance |

// MARK: - The record's vocabulary and shared helpers

public enum MemoryMoments {
    /// Metadata `lane` AND `kind` of the retired lane's rows.
    public static let lane = "moment"
    public static let kind = "moment"
    /// The source prefix the lane's rows carry.
    public static let sourcePrefix = "moment-promoter"

    /// True when a proposal/memory row belongs to the retired lane. A row
    /// staged before `lane` existed is identified by its kind.
    public static func isMoment(_ metadata: JSONValue?) -> Bool {
        guard case .object(let obj)? = metadata else { return false }
        if case .string(let value)? = obj["lane"] { return value == lane }
        if case .string(let value)? = obj["kind"] { return value == kind }
        return false
    }

    public static func metadataNumber(_ metadata: JSONValue?, _ key: String) -> Double? {
        guard case .object(let obj)? = metadata else { return nil }
        switch obj[key] {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Keep the conversation seat visible without treating acceptance as proof
    /// that the person said it. The promoter's source names the original seat.
    public static func recallOrigin(source: String?, metadata: JSONValue?, dataRoot: URL = defaultDataRoot()) -> JSONValue? {
        guard isMoment(metadata) || source?.hasPrefix("\(sourcePrefix):") == true else { return nil }
        let sourceSession = source.flatMap {
            $0.hasPrefix("\(sourcePrefix):") ? String($0.dropFirst(sourcePrefix.count + 1)) : nil
        }
        let session = sourceSession ?? metadata?.objectValue?["session_id"]?.stringValue
        let storedAuthor = metadata?.objectValue?["author"]?.stringValue.flatMap { ["app", "peer", "user"].contains($0) ? $0 : nil }
        let author = SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)?.isPeerConversation == true
            ? "peer" : (storedAuthor ?? "unknown")
        var origin: [String: JSONValue] = ["author": .string(author)]
        if let session, !session.isEmpty { origin["session_id"] = .string(session) }
        if let source, !source.isEmpty { origin["source"] = .string(source) }
        if let surface = metadata?.objectValue?["surface"]?.stringValue, !surface.isEmpty {
            origin["surface"] = .string(surface)
        }
        return .object(origin)
    }

    /// A row's own sentence: the lane appended its quote to the stored content.
    public static func narration(ofStored content: String, metadata: JSONValue?) -> String {
        guard let quote = metadata?.objectValue?["quote"]?.stringValue, !quote.isEmpty else { return content }
        let suffix = " — \"\(quote)\""
        guard content.hasSuffix(suffix) else { return content }
        return String(content.dropLast(suffix.count))
    }

}
