import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    // MARK: - Percept reconstruction
    //
    // The look organ answers in JSON whose strings have ALREADY been through
    // the compiler's redaction under the full node context. Those verdicts are
    // carried through verbatim into `MacScreenText`, which is what decides what
    // prints — this file never re-redacts and never re-renders a raw string.
    // A withheld string arrives as an object rather than a `.string`, so it
    // prints as `⟨redacted⟩` and matches no name.

    static func percept(from output: [String: JSONValue]) -> MacLookPercept {
        let app = object(output["app"] ?? .null)
        let (windowRaw, windowJSON) = text(output["window"])
        let focus = object(output["focus"] ?? .null)
        let modal = object(output["modal"] ?? .null)

        return MacLookPercept(
            app: string(app["name"]).map {
                MacAXAppInfo(
                    name: $0,
                    bundleIdentifier: string(app["bundle_id"]),
                    processIdentifier: int(app["pid"]).flatMap(Int32.init(exactly:)) ?? 0
                )
            },
            windowTitle: windowRaw,
            focus: string(focus["role"]).map { role in
                let (label, labelJSON) = text(focus["label"])
                return MacLookFocus(
                    role: role,
                    label: label,
                    handle: string(focus["handle"]),
                    path: path(focus["path"]),
                    labelJSON: labelJSON
                )
            },
            modal: string(modal["role"]).map { role in
                let (label, labelJSON) = text(modal["label"])
                return MacLookModal(
                    role: role,
                    subrole: string(modal["subrole"]),
                    label: label,
                    path: path(modal["path"]),
                    labelJSON: labelJSON
                )
            },
            landmarks: array(output["landmarks"]).map { row in
                let landmark = object(row)
                let (label, labelJSON) = text(landmark["label"])
                return MacLookLandmark(
                    kind: string(landmark["kind"]) ?? "region",
                    role: string(landmark["role"]) ?? "AXUnknown",
                    label: label,
                    depth: Int(int(landmark["depth"]) ?? 1),
                    path: path(landmark["path"]),
                    frame: frame(landmark["frame"]),
                    labelJSON: labelJSON
                )
            },
            affordances: array(output["affordances"]).compactMap { row in
                let affordance = object(row)
                guard let handle = string(affordance["handle"]),
                      let role = string(affordance["role"]) else { return nil }
                let (label, labelJSON) = text(affordance["label"])
                let (value, valueJSON) = text(affordance["value"])
                return MacLookAffordance(
                    handle: handle,
                    role: role,
                    subrole: string(affordance["subrole"]),
                    label: label ?? "",
                    labelSource: string(affordance["label_source"]) ?? "title",
                    value: value,
                    secret: affordance["secret_field"] == .bool(true),
                    enabled: affordance["enabled"] != .bool(false),
                    selected: bool(affordance["selected"]),
                    frame: frame(affordance["frame"]),
                    path: path(affordance["path"]),
                    labelJSON: labelJSON,
                    valueJSON: valueJSON
                )
            },
            unlabeledByRole: object(output["unlabeled"] ?? .null).reduce(into: [:]) { out, entry in
                out[entry.key] = Int(int(entry.value) ?? 0)
            },
            affordancesOmitted: Int(int(output["affordances_omitted"]) ?? 0),
            interactiveCount: Int(int(output["interactive_count"]) ?? 0),
            labeledCount: Int(int(output["labeled_count"]) ?? 0),
            truncated: output["truncated"] == .bool(true),
            truncationReasons: array(output["truncation_reasons"]).compactMap { string($0) },
            skippedAtLeast: Int(int(output["skipped_at_least"]) ?? 0),
            windowTitleJSON: windowJSON,
            readouts: array(output["readouts"]).map { row in
                let readout = object(row)
                let (value, valueJSON) = text(readout["text"])
                return MacLookReadout(
                    handle: string(readout["handle"]),
                    role: string(readout["role"]) ?? "AXStaticText",
                    text: value ?? "",
                    source: string(readout["source"]) ?? "value",
                    path: path(readout["path"]),
                    nearFocus: readout["near_focus"] == .bool(true),
                    inModal: readout["in_modal"] == .bool(true),
                    textJSON: valueJSON
                )
            },
            readoutsOmitted: Int(int(output["readouts_omitted"]) ?? 0)
        )
    }

    /// The SAME split `MacScreenRender.screen(from:)` makes — a control ROLE, or
    /// anything inside a control CONTAINER — using the same two sets, so the
    /// ordinal she reads in the render is the row this resolves. A test pins the
    /// agreement rather than leaving it to inspection.
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

    /// Fuse additive evidence without printing the same AX/vision label twice.
    /// AX is the authoritative semantic lane and therefore stays first.
    static func adding(
        contents: [MacScreenRender.Content] = [],
        controls: [MacScreenRender.Control] = [],
        values: [MacScreenRender.Value] = [],
        to screen: MacScreenRender.Screen
    ) -> MacScreenRender.Screen {
        var known = Set<String>()
        for control in screen.controls {
            if let label = control.label.display { known.insert(normalize(label)) }
        }
        for content in screen.contents {
            for row in content.rows {
                if let label = row.label?.display { known.insert(normalize(label)) }
            }
        }
        for value in screen.values {
            if let text = value.text.display { known.insert(normalize(text)) }
        }

        let newControls = controls.filter { control in
            // AX-backed rows were reconciled with targets by identity above.
            // Equal labels on distinct paths are not duplicate controls.
            if control.sourceAXPath != nil {
                if let label = control.label.display { known.insert(normalize(label)) }
                return true
            }
            guard let label = control.label.display else { return true }
            return known.insert(normalize(label)).inserted
        }
        var newContents: [MacScreenRender.Content] = []
        for content in contents {
            if content.kind == .canvas {
                if !screen.contents.contains(where: { $0.kind == .canvas }) { newContents.append(content) }
                continue
            }
            let rows = content.rows.filter { row in
                if row.sourceAXPath != nil {
                    if let label = row.label?.display { known.insert(normalize(label)) }
                    return true
                }
                guard let label = row.label?.display else { return true }
                return known.insert(normalize(label)).inserted
            }
            if !rows.isEmpty {
                newContents.append(MacScreenRender.Content(
                    kind: content.kind,
                    noun: content.noun,
                    rows: rows,
                    totalRows: rows.count,
                    scrollable: content.scrollable,
                    canvas: content.canvas
                ))
            }
        }
        let newValues = values.filter { value in
            guard let text = value.text.display else { return true }
            return known.insert(normalize(text)).inserted
        }

        // An open native menu is the immediate interaction surface. Keep its
        // choices ahead of background toolbar controls under the render cap,
        // preserving order within each role so existing ordinals stay valid.
        let allControls = screen.controls + newControls
        let orderedControls = allControls.filter { $0.kind == "menu item" }
            + allControls.filter { $0.kind != "menu item" }

        return MacScreenRender.Screen(
            appName: screen.appName,
            windowTitle: screen.windowTitle,
            isFront: screen.isFront,
            otherWindows: screen.otherWindows,
            provenance: screen.provenance,
            modal: screen.modal,
            whereSteps: screen.whereSteps,
            contents: screen.contents + newContents,
            controls: orderedControls,
            totalControls: screen.totalControls + newControls.count,
            unlabeledControls: screen.unlabeledControls,
            values: screen.values + newValues,
            totalValues: screen.totalValues + newValues.count,
            unclassifiedOmittedTargets: screen.unclassifiedOmittedTargets
        )
    }

    // MARK: - JSON primitives

    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    static func visionValueTexts(_ detail: [String: JSONValue]) -> Set<String>? {
        let source = detail["vision_effect_value_text"] ?? detail["vision_value_text"]
        guard case .array(let values)? = source else { return nil }
        return Set(values.compactMap { string($0) }.map(normalize))
    }

    static func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let array)? = value else { return [] }
        return array
    }

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    static func int(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let number)?: return number
        case .double(let number)?: return Int64(exactly: number.rounded(.towardZero))
        default: return nil
        }
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let number)?: return Double(number)
        case .double(let number)? where number.isFinite: return number
        default: return nil
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

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

    /// A string channel out of the look, as the pair `MacScreenText` needs: the
    /// clear text when redaction let it through, and a NON-EMPTY placeholder
    /// plus the withholding verdict when it did not — so the render prints
    /// `⟨redacted⟩` (visibly absent) rather than `⟨unlabeled⟩` (a different
    /// fact).
    static func text(_ value: JSONValue?) -> (String?, JSONValue?) {
        switch value {
        case .string(let clear)?:
            return (clear, .string(clear))
        case .object?:
            return ("⟨withheld⟩", value)
        default:
            return (nil, nil)
        }
    }

}
