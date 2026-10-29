import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApplicationServices
// Blueprint: | `MacActClosedLoop+EffectDifferences.swift` | `MacActClosedLoop`: effect-difference records, redacted JSON, walk comparability, `diff` and target-owned press evidence; complete comparison sets retain receipt caps and context redaction |

extension MacActClosedLoop {
    // MARK: the diff

    public struct ChangedAffordance: Sendable, Equatable {
        public let handle: String
        public let role: String
        public let beforeLabel: String?
        public let afterLabel: String?
        public let beforeValue: String?
        public let afterValue: String?
        public let beforeEnabled: Bool
        public let afterEnabled: Bool
        /// Each text side retains its own compile's enclosing-caption redaction.
        public let beforeLabelJSON: JSONValue?
        public let afterLabelJSON: JSONValue?
        public let beforeValueJSON: JSONValue?
        public let afterValueJSON: JSONValue?

        public init(
            handle: String,
            role: String,
            beforeLabel: String?,
            afterLabel: String?,
            beforeValue: String?,
            afterValue: String?,
            beforeEnabled: Bool,
            afterEnabled: Bool,
            beforeLabelJSON: JSONValue? = nil,
            afterLabelJSON: JSONValue? = nil,
            beforeValueJSON: JSONValue? = nil,
            afterValueJSON: JSONValue? = nil
        ) {
            self.beforeLabelJSON = beforeLabelJSON
            self.afterLabelJSON = afterLabelJSON
            self.beforeValueJSON = beforeValueJSON
            self.afterValueJSON = afterValueJSON
            self.handle = handle
            self.role = role
            self.beforeLabel = beforeLabel
            self.afterLabel = afterLabel
            self.beforeValue = beforeValue
            self.afterValue = afterValue
            self.beforeEnabled = beforeEnabled
            self.afterEnabled = afterEnabled
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            func redacted(_ text: String?, under caption: String?) -> JSONValue {
                guard let text else { return .null }
                return MacScreenViewTextRedaction.redactedLegendString(
                    text,
                    valueChars: valueChars,
                    under: caption
                )
            }
            var object: [String: JSONValue] = [
                "handle": .string(handle),
                "role": .string(role),
            ]
            // The compiler's own redaction wins wherever it exists; the
            // standalone redactor is only the floor for a side that never came
            // from a compile (a focus-only entry).
            if beforeLabel != afterLabel {
                object["label_before"] = beforeLabelJSON ?? redacted(beforeLabel, under: nil)
                object["label_after"] = afterLabelJSON ?? redacted(afterLabel, under: nil)
            }
            if beforeValue != afterValue {
                object["value_before"] = beforeValueJSON
                    ?? redacted(beforeValue, under: afterLabel ?? beforeLabel)
                object["value_after"] = afterValueJSON
                    ?? redacted(afterValue, under: afterLabel ?? beforeLabel)
            }
            if beforeEnabled != afterEnabled {
                object["enabled_before"] = .bool(beforeEnabled)
                object["enabled_after"] = .bool(afterEnabled)
            }
            return .object(object)
        }
    }

    /// Read-only value changes are observable effects and retain the changed display text.
    public struct ReadoutChange: Sendable, Equatable {
        public let handle: String?
        public let path: [Int]
        public let role: String
        public let beforeText: String?
        public let afterText: String?
        /// Before/after text retains each compile's full-context redaction before entering any receipt or sync channel.
        public let beforeJSON: JSONValue?
        public let afterJSON: JSONValue?
        /// Pair an added and removed readout at the same path and role as one changed control, even when retitling changes its handle.
        public let renamed: Bool

        public init(
            handle: String?,
            path: [Int],
            role: String,
            beforeText: String?,
            afterText: String?,
            beforeJSON: JSONValue? = nil,
            afterJSON: JSONValue? = nil,
            renamed: Bool = false
        ) {
            self.handle = handle
            self.path = path
            self.role = role
            self.beforeText = beforeText
            self.afterText = afterText
            self.beforeJSON = beforeJSON
            self.afterJSON = afterJSON
            self.renamed = renamed
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            /// Raw values leave the comparison only as count and digest when canonically redacted.
            func emit(_ json: JSONValue?, raw: String?) -> JSONValue {
                if let json { return json }
                guard let raw else { return .null }
                return MacInjectionResultRedaction.redactedSecret(raw)
            }
            var object: [String: JSONValue] = [
                "role": .string(role),
                "path": .array(path.map { .int(Int64($0)) }),
                "before": emit(beforeJSON, raw: beforeText),
                "after": emit(afterJSON, raw: afterText),
            ]
            if let handle { object["handle"] = .string(handle) }
            // Emitted only when true, so an ordinary changed row is byte-for-byte
            // what it always was.
            if renamed { object["renamed"] = .bool(true) }
            return .object(object)
        }
    }

    /// Added/removed readout rows retain comparison evidence and use the same context-aware redaction as changed readouts.
    public struct ReadoutRow: Sendable, Equatable {
        public let handle: String?
        public let path: [Int]
        public let role: String
        public let text: String?
        /// Emit the compile-redacted text; preserve raw text only for exact diff comparison so distinct secrets remain distinguishable.
        public let textJSON: JSONValue?

        public init(
            handle: String?,
            path: [Int],
            role: String,
            text: String?,
            textJSON: JSONValue? = nil
        ) {
            self.handle = handle
            self.path = path
            self.role = role
            self.text = text
            self.textJSON = textJSON
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            var object: [String: JSONValue] = [
                "role": .string(role),
                "path": .array(path.map { .int(Int64($0)) }),
                // The compile's verdict wins; the standalone redactor is only
                // the floor for a row that never came from one.
                "text": textJSON ?? text.map {
                    MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                } ?? .null,
            ]
            if let handle { object["handle"] = .string(handle) }
            return .object(object)
        }
    }

    public struct EffectDiff: Sendable, Equatable {
        public let added: [MacLookAffordance]
        public let removed: [MacLookFrameEntry]
        public let changed: [ChangedAffordance]
        /// Compute the role census over complete sets before capping receipt rows.
        public let addedByRole: [String: Int]
        public let removedByRole: [String: Int]
        public var addedTotal: Int { added.count }
        public var removedTotal: Int { removed.count }
        public var changedTotal: Int { changed.count }
        public let focusChanged: Bool
        public let focusHandleAfter: String?
        public let focusLabelAfter: String?
        /// The focused element's label retains the after-percept's redaction.
        public let focusLabelJSONAfter: JSONValue?
        public let focusRoleAfter: String?
        public let modalAppeared: Bool
        public let modalDisappeared: Bool
        public let modalLabelAfter: String?
        public let windowTitleChanged: Bool
        public let windowTitleAfter: String?
        // Frames without readouts report none rather than fabricate values.
        public let readoutsChanged: [ReadoutChange]
        public var readoutsChangedTotal: Int { readoutsChanged.count }
        public var readoutsAddedTotal: Int { readoutsAdded.count }
        public var readoutsRemovedTotal: Int { readoutsRemoved.count }
        /// All rows behind those totals; only receipt rendering caps them.
        public let readoutsAdded: [ReadoutRow]
        public let readoutsRemoved: [ReadoutRow]
        /// Were the two compiles allowed to see the same window? False when one
        /// side's walk truncated or the two ran under different caps — the
        /// added/removed affordance and readout CENSUS is a set difference and
        /// means nothing
        /// across mismatched bounds. Said out loud rather than dropped silently.
        public let diffComparable: Bool
        public let diffIncomparableReason: String?

        public init(
            added: [MacLookAffordance],
            removed: [MacLookFrameEntry],
            changed: [ChangedAffordance],
            addedByRole: [String: Int] = [:],
            removedByRole: [String: Int] = [:],
            focusChanged: Bool,
            focusHandleAfter: String?,
            focusLabelAfter: String?,
            focusLabelJSONAfter: JSONValue? = nil,
            focusRoleAfter: String?,
            modalAppeared: Bool,
            modalDisappeared: Bool,
            modalLabelAfter: String?,
            windowTitleChanged: Bool,
            windowTitleAfter: String?,
            readoutsChanged: [ReadoutChange] = [],
            readoutsAdded: [ReadoutRow] = [],
            readoutsRemoved: [ReadoutRow] = [],
            diffComparable: Bool = true,
            diffIncomparableReason: String? = nil
        ) {
            self.readoutsAdded = readoutsAdded
            self.readoutsRemoved = readoutsRemoved
            self.diffComparable = diffComparable
            self.diffIncomparableReason = diffIncomparableReason
            self.added = added
            self.removed = removed
            self.changed = changed
            self.addedByRole = addedByRole
            self.removedByRole = removedByRole
            self.focusChanged = focusChanged
            self.focusHandleAfter = focusHandleAfter
            self.focusLabelAfter = focusLabelAfter
            self.focusLabelJSONAfter = focusLabelJSONAfter
            self.focusRoleAfter = focusRoleAfter
            self.modalAppeared = modalAppeared
            self.modalDisappeared = modalDisappeared
            self.modalLabelAfter = modalLabelAfter
            self.windowTitleChanged = windowTitleChanged
            self.windowTitleAfter = windowTitleAfter
            self.readoutsChanged = readoutsChanged
        }

        /// Any reported change channel makes the diff nonempty, including read-only displays.
        public var isEmpty: Bool { changeReasons.isEmpty }

        /// Name every changed channel; set-membership deltas require comparable walks, while identity-bound channels remain observable under truncation.
        public var changeReasons: [String] {
            var out: [String] = []
            if diffComparable {
                if addedTotal > 0 { out.append("affordances_added") }
                if removedTotal > 0 { out.append("affordances_removed") }
                if readoutsAddedTotal > 0 { out.append("readouts_added") }
                if readoutsRemovedTotal > 0 { out.append("readouts_removed") }
            }
            if changedTotal > 0 { out.append("affordances_changed") }
            if focusChanged { out.append("focus_changed") }
            if modalAppeared { out.append("modal_appeared") }
            if modalDisappeared { out.append("modal_disappeared") }
            if windowTitleChanged { out.append("window_title_changed") }
            if readoutsChangedTotal > 0 { out.append("readouts_changed") }
            return out
        }

        public var windowChanged: Bool { !changeReasons.isEmpty }

        /// Navigation requires a title/modal transition or comparable affordance turnover; readout changes, focus and enabled-state changes alone do not prove it.
        public var navigated: Bool {
            if windowTitleChanged || modalAppeared || modalDisappeared { return true }
            if diffComparable, addedTotal > 0 || removedTotal > 0 { return true }
            return false
        }
    }

    /// Roles whose value is a position that can move on its own, never a readout.
    static let positionRoles: Set<String> = ["AXSlider", "AXProgressIndicator", "AXBusyIndicator",
                                             "AXScrollBar", "AXLevelIndicator", "AXValueIndicator"]

    /// A screen delta is evidence of a press only when it belongs to the
    /// target. Independent controls, global title/modal churn and a readout
    /// that merely holds still do not establish causation.
    public static func pressEvidence(
        _ diff: EffectDiff, before: MacLookFrame, pressed: MacLookFrameEntry,
        settled: (ReadoutChange) -> Bool
    ) -> (own: Bool, consequence: Bool, readoutOnly: Bool) {
        guard !pressed.path.isEmpty else { return (false, false, false) }
        let retitled = diff.added.contains { $0.path == pressed.path } && diff.removed.contains { $0.path == pressed.path }
        var own = retitled
        var linked = false
        for row in diff.changed {
            guard let path = before.entries[row.handle]?.path,
                  path.starts(with: pressed.path) else { continue }
            own = true
            if !Self.positionRoles.contains(row.role),
               row.beforeValue != row.afterValue || row.beforeLabel != row.afterLabel { linked = true }
        }
        let structural = linked || (diff.diffComparable &&
            (diff.added.contains { $0.path != pressed.path && $0.path.starts(with: pressed.path) }
             || diff.removed.contains { $0.path != pressed.path && $0.path.starts(with: pressed.path) }))
        let readoutOnly = !structural && diff.readoutsChanged.contains {
            !Self.positionRoles.contains($0.role) && $0.path.starts(with: pressed.path) && settled($0)
        }
        return (own, structural || readoutOnly, readoutOnly)
    }

    /// Only complete walks under matching known caps have a comparable census; absent cap records cannot prove a mismatch.
    public static func comparability(
        before: MacLookCompileCaps?,
        after: MacLookCompileCaps?
    ) -> (comparable: Bool, reason: String?) {
        if before?.truncated == true, after?.truncated == true {
            return (false, "both the look's walk and the post-action walk truncated")
        }
        if before?.truncated == true { return (false, "the look's walk truncated") }
        if after?.truncated == true { return (false, "the post-action walk truncated") }
        guard let before, let after else { return (true, nil) }
        func mismatch(_ name: String, _ lhs: Int?, _ rhs: Int?) -> String? {
            guard let lhs, let rhs, lhs != rhs else { return nil }
            return "\(name) was \(lhs) for the look and \(rhs) for the post-action compile"
        }
        let reasons = [
            mismatch("max_affordances", before.maxAffordances, after.maxAffordances),
            mismatch("max_nodes", before.maxNodes, after.maxNodes),
            mismatch("max_depth", before.maxDepth, after.maxDepth),
        ].compactMap { $0 }
        guard reasons.isEmpty else { return (false, reasons.joined(separator: "; ")) }
        return (true, nil)
    }

    public static func diff(
        before: MacLookFrame,
        after: MacLookPercept,
        afterWindowTitle: String?,
        afterCaps: MacLookCompileCaps? = nil
    ) -> EffectDiff {
        var afterByHandle: [String: MacLookAffordance] = [:]
        for affordance in after.affordances where !affordance.handle.isEmpty {
            if afterByHandle[affordance.handle] == nil { afterByHandle[affordance.handle] = affordance }
        }
        let beforeEntries = before.entries

        var added: [MacLookAffordance] = []
        var removed: [MacLookFrameEntry] = []
        var changed: [ChangedAffordance] = []

        for affordance in after.affordances where !affordance.handle.isEmpty {
            guard let was = beforeEntries[affordance.handle] else {
                added.append(affordance)
                continue
            }
            let beforeLabel = normalizedLabel(was.label)
            let afterLabel = normalizedLabel(affordance.label)
            let beforeValue = normalizedLabel(was.value)
            let afterValue = normalizedLabel(affordance.value)
            guard beforeLabel != afterLabel
                || beforeValue != afterValue
                || was.enabled != affordance.enabled else { continue }
            changed.append(ChangedAffordance(
                handle: affordance.handle,
                role: affordance.role,
                beforeLabel: beforeLabel,
                afterLabel: afterLabel,
                beforeValue: beforeValue,
                afterValue: afterValue,
                beforeEnabled: was.enabled,
                afterEnabled: affordance.enabled,
                beforeLabelJSON: was.labelJSON,
                afterLabelJSON: affordance.labelJSON,
                beforeValueJSON: was.valueJSON,
                afterValueJSON: affordance.valueJSON
            ))
        }
        for (handle, entry) in beforeEntries where afterByHandle[handle] == nil {
            removed.append(entry)
        }
        // Deterministic order, so a diff is comparable across calls and a test
        // is not asserting on dictionary iteration order.
        removed.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }
        changed.sort { $0.handle < $1.handle }

        let focusBefore = before.focusHandle
        let focusAfter = after.focus?.handle
        let focusChanged = focusBefore != focusAfter
            || (focusAfter == nil && before.focusHandle != nil)

        let modalAfterLabel = normalizedLabel(after.modal?.label)
        let hadModal = before.hasModal
        let hasModal = after.modal != nil

        let titleBefore = normalizedLabel(before.windowTitle)
        let titleAfter = normalizedLabel(afterWindowTitle)

        // Diff readouts by handle when available, otherwise by path.
        var readoutsChanged: [ReadoutChange] = []
        var readoutsAdded: [ReadoutRow] = []
        let beforeReadouts = before.readouts
        var afterReadoutKeys = Set<String>()
        for readout in after.readouts {
            let key = MacLookReadoutRecord.key(handle: readout.handle, path: readout.path)
            guard afterReadoutKeys.insert(key).inserted else { continue }
            guard let was = beforeReadouts[key] else {
                readoutsAdded.append(ReadoutRow(
                    handle: readout.handle,
                    path: readout.path,
                    role: readout.role,
                    text: normalizedLabel(readout.text),
                    textJSON: readout.textJSON
                ))
                continue
            }
            let beforeText = normalizedLabel(was.text)
            let afterText = normalizedLabel(readout.text)
            guard beforeText != afterText else { continue }
            readoutsChanged.append(ReadoutChange(
                handle: readout.handle,
                path: readout.path,
                role: readout.role,
                beforeText: beforeText,
                afterText: afterText,
                // Each side retains its own compile's redaction; this diff has no snapshot with which to rejudge it.
                beforeJSON: was.textJSON,
                afterJSON: readout.textJSON
            ))
        }
        var readoutsRemoved = beforeReadouts.values
            .filter { !afterReadoutKeys.contains($0.key) }
            // Removed readouts retain the frame's own compile-redacted text.
            .map { ReadoutRow(handle: $0.handle, path: $0.path, role: $0.role, text: normalizedLabel($0.text), textJSON: $0.textJSON) }
            .sorted { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        // Pair by path and role, consuming duplicate identities in original order.
        var removedByPath: [[Int]: [String: [Int]]] = [:]
        for index in readoutsRemoved.indices.reversed() {
            let row = readoutsRemoved[index]
            removedByPath[row.path, default: [:]][row.role, default: []].append(index)
        }
        var pairedAdded: [ReadoutRow] = []
        var pairedRemoved = Set<Int>()
        for row in readoutsAdded {
            guard let index = removedByPath[row.path]?[row.role]?.popLast() else {
                pairedAdded.append(row)
                continue
            }
            let was = readoutsRemoved[index]
            pairedRemoved.insert(index)
            readoutsChanged.append(ReadoutChange(
                handle: row.handle,
                path: row.path,
                role: row.role,
                beforeText: was.text,
                afterText: row.text,
                // Each side retains its own complete-context redaction verdict.
                beforeJSON: was.textJSON,
                afterJSON: row.textJSON,
                renamed: true
            ))
        }
        readoutsAdded = pairedAdded
        readoutsRemoved = readoutsRemoved.enumerated().filter { !pairedRemoved.contains($0.offset) }.map(\.element)
        readoutsChanged.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        readoutsAdded.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        var addedByRole: [String: Int] = [:]
        for affordance in added { addedByRole[affordance.role, default: 0] += 1 }
        var removedByRole: [String: Int] = [:]
        for entry in removed { removedByRole[entry.role, default: 0] += 1 }

        let comparable = comparability(before: before.caps, after: afterCaps)

        return EffectDiff(
            added: added,
            removed: removed,
            changed: changed,
            addedByRole: addedByRole,
            removedByRole: removedByRole,
            focusChanged: focusChanged,
            focusHandleAfter: focusAfter,
            focusLabelAfter: normalizedLabel(after.focus?.label),
            focusLabelJSONAfter: after.focus?.labelJSON,
            focusRoleAfter: after.focus?.role,
            modalAppeared: hasModal && !hadModal,
            modalDisappeared: !hasModal && hadModal,
            modalLabelAfter: modalAfterLabel,
            windowTitleChanged: titleBefore != titleAfter,
            windowTitleAfter: titleAfter,
            readoutsChanged: readoutsChanged,
            readoutsAdded: readoutsAdded,
            readoutsRemoved: readoutsRemoved,
            diffComparable: comparable.comparable,
            diffIncomparableReason: comparable.reason
        )
    }
}
