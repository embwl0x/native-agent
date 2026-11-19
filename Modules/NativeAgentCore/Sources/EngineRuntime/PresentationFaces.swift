import AppToolRuntime
import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import ToolExecution
// Blueprint: | `PresentationFaces.swift` | Root-scoped authored copy from frozen inputs; each copy key posts its finished snapshot to the face feed |

/// Root-scoped authored copy: owners and view tasks feed frozen inputs; rendering reads only the face feed.
@MainActor
public final class PresentationFaces {
    private let dataRoot: URL
    private let feed: FaceFeedSource
    private var faces: [JSONValue: PartFaces] = [:]
    private var identities: [String: JSONValue] = [:]
    public nonisolated init(dataRoot: URL, feed: FaceFeedSource) { self.dataRoot=dataRoot; self.feed=feed }

    public func words(_ key: String) async -> String? { await words(key, readyOnly: false) }

    /// Readiness checks can omit diagnostics; displayed words carry the owner's preparation failure on every door.
    public func words(_ key: String, readyOnly: Bool) async -> String? {
        guard let identity = identities[key] else { return nil }
        return await faces[identity]?.snapshots["presentation-copy"]?.copyWords(readyOnly: readyOnly)
    }

    @discardableResult
    public func prepare(_ key: String, input: JSONValue) async -> String {
        let snapshot = await prepareSnapshot(key,input:input)
        if snapshot.status == .ready, let text=snapshot.face?.sections.first?.rows.first?.title { return text }
        return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
    }

    public func prepareSnapshot(_ key: String, input: JSONValue) async -> PartFaceSnapshot {
        let identity: JSONValue
        let copy: Bool
        switch input.objectValue?["kind"]?.stringValue {
        case "headline", "tool":
            identity = .array([.string("input"), input]); copy = true
        default:
            identity = .array([.string("page"), .string(key)]); copy = false
        }
        identities[key] = identity
        let face: PartFaces
        if let existing = faces[identity] { face = existing } else {
            let root=dataRoot
            let address = copy ? "input:" + UUID().uuidString : key
            face=PartFaces(dataRoot:root, feed: feed, key: { _ in PageFaceKey.copy(address) }) { id,input,version in
                await NativeAgentEngine.forRoot(root).tools.face(id: id, input: input, version: version)
            }
            faces[identity] = face
        }
        return await face.sourceChanged(id:"presentation-copy",epoch:0,input:input)
    }
}
