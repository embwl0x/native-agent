import AppToolRuntime
import AuthoredCapabilities
import ChatToolRuntime
import ChatTurnRuntime
import Foundation
import NativeAgentCore
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

    public func words(_ key: String) -> String? { words(key, readyOnly: false) }

    /// A transport carries only ready authored words; local readers may also show the owner's failure diagnostic.
    public func words(_ key: String, readyOnly: Bool) -> String? {
        if let snapshot=faces[key]?.snapshots["presentation-copy"] {
            if snapshot.status == .ready { return snapshot.face?.sections.first?.rows.first?.title }
            if readyOnly { return nil }
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
                let invocation = ChatToolInvocation()
                let work = ChatTurnWork(toolInvocation: invocation)
                let execution = AppActionExecution(invocation: invocation, deadlines: work.deadlines, turnWork: work)
                let host=AppToolExecutor.authoredProgramHost(dataRoot:root, turn: nil, execution: execution) { _,_,_,_ in nil }
                return await Parts(root: root).face(id: id, input: input, version: version,
                    invocation: .init(host: host, execution: .init(turn: nil, surface: "presentation", deadlines: execution.deadlines)))
            }
            faces[key] = face
        }
        return await face.sourceChanged(id:"presentation-copy",epoch:epochs[key] ?? 0,input:input)
    }
}
