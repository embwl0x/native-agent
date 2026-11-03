import Foundation
import PersistenceCore
// Blueprint: | `KnowledgeGraph+Disclosure.swift` | `KnowledgeGraphMemoryDisclosure`: graph source references checked against canonical memory disclosure for a requested audience |

/// Graph metadata names its source; MemoryV2 alone decides whether that source
/// may reach the audience. This value is scoped to a single read operation.
public struct KnowledgeGraphMemoryDisclosure: Sendable {
    private let memoryIDs: Set<String>
    private let factIDs: Set<String>

    public init(records: [MemoryRecord], surface: String, personaID: String? = nil, at now: Date = Date()) {
        memoryIDs = Set(records.filter {
            MemoryRecordDisclosurePolicy.classify($0, at: now)?
                .permits(surface: surface, personaID: personaID) == true
        }.map(\.id))
        factIDs = Set(memoryIDs.map(SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID))
    }

    public func permits(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        var hasMemorySource = false
        for key in ["memory_id", "last_memory_id"] {
            if let source = object[key], source != .null {
                hasMemorySource = true
                guard case .string(let id) = source, memoryIDs.contains(id) else { return false }
            }
        }
        if case .string(let id)? = object["id"], id.hasPrefix("memfact_") {
            return factIDs.contains(id)
        }
        // The shared primary-user identity is profile-backed. Its facts and
        // relationships still need their own permitted memory source above.
        if object["id"]?.stringValue != nil,
           object["type"]?.stringValue == "person",
           object["role"]?.stringValue == "primary_user" {
            return true
        }
        // Any other indexer stamp without its source is not disclosure evidence.
        if object["indexer"]?.stringValue == SwiftNativeKnowledgeGraphIndexer.indexVersion
            || object[SwiftNativeKnowledgeGraphIndexer.createdByKey]?.stringValue == SwiftNativeKnowledgeGraphIndexer.indexVersion {
            return hasMemorySource
        }
        return true
    }
}
