import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `PresentationFaces.swift` | Root-scoped authored copy from frozen inputs; each copy key posts its finished snapshot to the face feed |

/// Root-scoped authored copy: owners and view tasks feed frozen inputs; rendering reads only the face feed.
@MainActor
public final class PresentationFaces {
    private let faces: PartFaces
    private var inputAddresses: [JSONValue: String] = [:]
    private var addresses: [String: String] = [:]
    public nonisolated init(tools: ToolsFacade, feed: FaceFeedSource) {
        faces = PartFaces(dataRoot: tools.dataRoot, feed: feed, key: { PageFaceKey.copy($0) }) { id, input, version in
            await tools.face(id: id, input: input, version: version)
        }
    }

    public func words(_ keys: [String]) async -> [String: String] {
        await copies(keys).compactMapValues { $0.copyWords() }
    }

    func copies(_ keys: [String]) async -> [String: PartFaceSnapshot] {
        while !Task.isCancelled {
            let requested = keys.map { addresses[$0] }
            let snapshots = await faces.snapshots
            guard zip(keys, requested).allSatisfy({ addresses[$0.0] == $0.1 }) else { continue }
            var values: [String: PartFaceSnapshot] = [:]
            for (key, address) in zip(keys, requested) {
                if let address { values[key] = snapshots[address] }
            }
            return values
        }
        return [:]
    }

    @discardableResult
    public func prepare(_ key: String, input: JSONValue) async -> String {
        let snapshot = await prepareSnapshot(key,input:input)
        if snapshot.status == .ready, let text=snapshot.face?.sections.first?.rows.first?.title { return text }
        return "Readout "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
    }

    public func prepareSnapshot(_ key: String, input: JSONValue) async -> PartFaceSnapshot {
        let address: String
        switch input.objectValue?["kind"]?.stringValue {
        case "headline", "tool":
            if let existing = inputAddresses[input] { address = existing }
            else {
                address = "input:" + UUID().uuidString
                inputAddresses[input] = address
            }
        default:
            address = key
        }
        addresses[key] = address
        return await faces.sourceChanged(id: "presentation-copy", page: address, epoch: 0, input: input)
    }
}
