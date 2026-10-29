import AppToolRuntime
import AuthoredCapabilities
import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import Senses
import ToolExecution
// Blueprint: | `PresentationFaces.swift` | Root-scoped PresentationFaces feeds L0's pure presentation-copy.js cache from frozen inputs outside rendering |

/// Root-scoped authored copy: owners and view tasks feed frozen inputs; rendering reads L0 snapshots, including unavailable status.
@MainActor @Observable
public final class PresentationFaces {
    private let dataRoot: URL
    private var faces: [String:PartFaces] = [:]
    @ObservationIgnored private var inputs: [String:JSONValue] = [:]
    @ObservationIgnored private var epochs: [String:UInt64] = [:]
    public nonisolated init(dataRoot: URL) { self.dataRoot=dataRoot }

    public func words(_ key: String) -> String? {
        if let snapshot=faces[key]?.snapshots["presentation-copy"] {
            if snapshot.status == .ready { return snapshot.face?.sections.first?.rows.first?.title }
            return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
        }
        return nil
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
            face=PartFaces(dataRoot:root) { id,input,version in
                let host=AppToolExecutor.authoredProgramHost(dataRoot:root) { _,_ in nil }
                return await OwnedProgramInvocation.$host.withValue(host) {
                    await Parts(root:root).face(id:id,input:input,version:version)
                }
            }
            faces[key] = face
        }
        return await face.sourceChanged(id:"presentation-copy",epoch:epochs[key] ?? 0,input:input)
    }
}
