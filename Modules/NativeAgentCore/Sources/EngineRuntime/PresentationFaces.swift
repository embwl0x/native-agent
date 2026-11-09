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
    private var faces: [String: PartFaces] = [:]
    private var inputs: [String:JSONValue] = [:]
    private var epochs: [String:UInt64] = [:]
    public nonisolated init(dataRoot: URL, feed: FaceFeedSource) { self.dataRoot=dataRoot; self.feed=feed }

    public func words(_ key: String) async -> String? { await words(key, readyOnly: false) }

    /// Readiness checks can omit diagnostics; displayed words carry the owner's preparation failure on every door.
    public func words(_ key: String, readyOnly: Bool) async -> String? {
        await faces[key]?.snapshots["presentation-copy"]?.copyWords(readyOnly: readyOnly)
    }

    @discardableResult
    public func prepare(_ key: String, input: JSONValue) async -> String {
        let snapshot = await prepareSnapshot(key,input:input)
        if snapshot.status == .ready, let text=snapshot.face?.sections.first?.rows.first?.title { return text }
        return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
    }

    public func prepareSnapshot(_ key: String, input: JSONValue) async -> PartFaceSnapshot {
        if inputs[key] != input { inputs[key]=input; epochs[key,default:0] += 1 }
        let face: PartFaces
        if let existing = faces[key] { face = existing } else {
            let root=dataRoot
            face=PartFaces(dataRoot:root, feed: feed, key: { _ in PageFaceKey.copy(key) }) { id,input,version in
                await NativeAgentEngine.forRoot(root).tools.face(id: id, input: input, version: version)
            }
            faces[key] = face
        }
        return await face.sourceChanged(id:"presentation-copy",epoch:epochs[key] ?? 0,input:input)
    }
}
