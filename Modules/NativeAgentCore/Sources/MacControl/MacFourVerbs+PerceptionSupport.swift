import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+PerceptionSupport.swift` | `MacFourVerbs`: shared rendering/targeting `partition` and `supplementalDuplicateIndex` |

extension MacFourVerbs {
    /// The one row/control split consumed by rendering and targeting, so a
    /// printed ordinal always names the same affordance.
    static func partition(
        _ percept: MacLookPercept
    ) -> (rows: [MacLookAffordance], controls: [MacLookAffordance]) {
        let containers = percept.landmarks
            .filter { MacScreenRender.controlContainerKinds.contains($0.kind) }
            .map(\.path)
        func insideContainer(_ path: [Int]) -> Bool {
            containers.contains { container in
                container.count < path.count && Array(path.prefix(container.count)) == container
            }
        }
        var rows: [MacLookAffordance] = []
        var controls: [MacLookAffordance] = []
        for affordance in percept.affordances {
            let isControl = !MacScreenRender.contentRowRoles.contains(affordance.role)
                && (MacPerceptionCompiler.controlRoles.contains(affordance.role)
                    || insideContainer(affordance.path))
            if isControl { controls.append(affordance) } else { rows.append(affordance) }
        }
        return (rows, controls)
    }

    /// Fuse only one supported identity. An AX path is capture-local: labels
    /// and available geometry must still agree so a reordered tree cannot
    /// donate a different control's physical mark to an old semantic handle.
    /// A matching row/cell and its contained filename may share the named item,
    /// without sharing marks; separate rows and interactive descendants cannot.
    static func supplementalDuplicateIndex(
        _ candidate: MacFourVerbsSupplementalTarget, among targets: [ActTarget]
    ) -> Int? {
        let display = candidate.label?.display.map(normalize)
        let matches = targets.indices.filter { index in
            let existing = targets[index]
            let existingLabel = existing.label.map(normalize)
            let sameLabel = display != nil && display == existingLabel
            let incompatibleLabel = display != nil && existingLabel != nil && !sameLabel
            if let path = candidate.sourceAXPath, let existingPath = existing.sourceAXPath,
               path != existingPath {
                let itemKinds: Set<String> = ["row", "cell", "item"]
                let displayKinds = itemKinds.union(["text"])
                let shorter = path.count < existingPath.count ? path : existingPath
                let longer = path.count < existingPath.count ? existingPath : path
                return sameLabel && display?.isEmpty == false
                    && candidate.enabled == existing.enabled
                    && !candidate.physicalOnly && !existing.physicalOnly
                    && displayKinds.contains(candidate.kind) && displayKinds.contains(existing.kind)
                    && (itemKinds.contains(candidate.kind) || itemKinds.contains(existing.kind))
                    && !shorter.isEmpty && longer.count - shorter.count <= 2
                    && longer.starts(with: shorter)
                    && framesOverlap(candidate.frame, existing.frame)
            }
            guard candidate.kind == existing.kind else { return false }
            if let path = candidate.sourceAXPath, let existingPath = existing.sourceAXPath {
                guard path == existingPath, !incompatibleLabel else { return false }
                return existing.frame.map { framesOverlap(candidate.frame, $0) } ?? sameLabel
            }
            // Named moving pixel regions can overlap by design. Their live
            // names, not geometric containment, identify the region.
            if candidate.physicalOnly || existing.physicalOnly { return sameLabel }
            guard !incompatibleLabel else { return false }
            if let frame = existing.frame { return framesOverlap(candidate.frame, frame) }
            return sameLabel
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func framesOverlap(_ lhs: MacAXFrame, _ rhs: MacAXFrame?) -> Bool {
        guard let rhs, lhs.w > 0, lhs.h > 0, rhs.w > 0, rhs.h > 0 else { return false }
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.w, rhs.x + rhs.w)
        let bottom = min(lhs.y + lhs.h, rhs.y + rhs.h)
        guard right > left, bottom > top else { return false }
        let intersection = (right - left) * (bottom - top)
        let smaller = min(lhs.w * lhs.h, rhs.w * rhs.h)
        return smaller > 0 && intersection / smaller >= 0.65
    }


    // MARK: - JSON primitives

    static func object(_ value: JSONValue?) -> [String: JSONValue] { value?.objectValue ?? [:] }

    static func array(_ value: JSONValue?) -> [JSONValue] { value?.arrayValue ?? [] }
    static func string(_ value: JSONValue?) -> String? { value?.stringValue }
    static func int(_ value: JSONValue?) -> Int64? { value?.integerValue }
    static func number(_ value: JSONValue?) -> Double? { value?.numberValue(coercingStrings: false, finiteOnly: true) }
    static func bool(_ value: JSONValue?) -> Bool? { value?.boolValue }

    static func frame(_ value: JSONValue?) -> MacAXFrame? {
        let value = object(value)
        guard let x = number(value["x"]), let y = number(value["y"]),
              let w = number(value["w"]), let h = number(value["h"]),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }

    static func path(_ value: JSONValue?) -> [Int] {
        array(value).compactMap { int($0).map(Int.init) }
    }

}
