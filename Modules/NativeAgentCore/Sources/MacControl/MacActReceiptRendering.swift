import Foundation
import PersistenceCore
import TrustCenter
// Blueprint: | `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |

/// Keep rendering separate from execution and verification so receipts cannot invent a verdict.
enum MacActReceiptRendering {
    /// Resolve changed/added readouts back to the post-act percept so glance text retains compile-time enclosing-caption redaction. Diff text alone lacks that
    /// context.
    static func actedReadout(
        diff: MacActClosedLoop.EffectDiff,
        after: MacLookPercept
    ) -> MacLookReadout? {
        func lookup(path: [Int], role: String) -> MacLookReadout? {
            after.readouts.first { $0.path == path && $0.role == role }
        }
        if let changed = diff.readoutsChanged.first,
           let readout = lookup(path: changed.path, role: changed.role) {
            return readout
        }
        if let added = diff.readoutsAdded.first,
           let readout = lookup(path: added.path, role: added.role) {
            return readout
        }
        return nil
    }

    /// Redacted before/after snapshot; label/value JSON retains each compile's enclosing-caption context.
    static func actedElementJSON(
        _ target: MacAXActTarget,
        redactingValue: Bool,
        labelJSON: JSONValue? = nil,
        valueJSON: JSONValue? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(target.role)]
        object["label"] = labelJSON ?? (target.title ?? target.value).map {
            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: MacAXLimits.hardValueChars)
        } ?? .null
        if redactingValue {
            object["value"] = target.value.map { MacInjectionResultRedaction.redactedSecret($0) } ?? .null
        } else if let valueJSON {
            object["value"] = valueJSON
        } else {
            object["value"] = target.value.map {
                MacScreenViewTextRedaction.redactedLegendString(
                    $0,
                    valueChars: MacAXLimits.hardValueChars,
                    under: target.title
                )
            } ?? .null
        }
        object["enabled"] = .bool(target.enabled)
        return .object(object)
    }

    /// Summarize bulk changes with role counts and focus context alongside the capped row lists.
    static func denseEffectSummaryJSON(
        diff: MacActClosedLoop.EffectDiff,
        after: MacLookPercept,
        snapshot: MacAXTreeSnapshot,
        valueChars: Int
    ) -> JSONValue {
        func census(_ byRole: [String: Int]) -> JSONValue {
            .object(byRole.mapValues { .int(Int64($0)) })
        }
        var summary: [String: JSONValue] = [
            "added_by_role": census(diff.addedByRole),
            "removed_by_role": census(diff.removedByRole),
        ]
        // Summary nodes use the same full-context redaction as the percept, including enclosing captions.
        let redactedText = MacPerceptionCompiler.redactedNodeTextMap(snapshot)
        if let focusPath = after.focus?.path, !focusPath.isEmpty {
            let containerPath = Array(focusPath.dropLast())
            let children = snapshot.nodes.filter { $0.path.count == containerPath.count + 1
                && Array($0.path.dropLast()) == containerPath }
            let container = snapshot.nodes.first { $0.path == containerPath }
            var block: [String: JSONValue] = [
                "role": container.map { .string($0.attributes.role) } ?? .null,
                "child_count": .int(Int64(children.count)),
                "path": .array(containerPath.map { .int(Int64($0)) }),
            ]
            block["label"] = container?.attributes.title == nil
                ? .null
                : (redactedText[containerPath] ?? MacInjectionResultRedaction.redactedSecret(
                    container?.attributes.title ?? ""
                ))
            block["first_children"] = .array(
                children.prefix(10).map { child in
                    guard (child.attributes.title ?? child.attributes.value) != nil else {
                        return .string(child.attributes.role)
                    }
                    // Missing contextual redaction must fail closed; a context-free second judgment cannot safely expose text.
                    return redactedText[child.path]
                        ?? MacInjectionResultRedaction.redactedSecret(
                            child.attributes.title ?? child.attributes.value ?? ""
                        )
                }
            )
            summary["new_focus_container"] = .object(block)
        }
        return .object(summary)
    }

    static func effectDiffJSON(
        _ diff: MacActClosedLoop.EffectDiff,
        valueChars: Int
    ) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "affordances_added": .array(diff.added.prefix(MacActClosedLoop.maxDiffRows).map { $0.toJSON(valueChars: valueChars) }),
            "affordances_removed": .array(diff.removed.prefix(MacActClosedLoop.maxDiffRows).map { entry in
                .object([
                    "handle": .string(entry.handle),
                    "role": .string(entry.role),
                    // Use the entry's compile-time redaction; the stored string has no enclosing context.
                    "label": entry.labelJSON ?? entry.label.map {
                        MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                    } ?? .null,
                ])
            }),
            "changed": .array(diff.changed.prefix(MacActClosedLoop.maxDiffRows).map { $0.toJSON(valueChars: valueChars) }),
            "affordances_added_total": .int(Int64(diff.addedTotal)),
            "affordances_removed_total": .int(Int64(diff.removedTotal)),
            "changed_total": .int(Int64(diff.changedTotal)),
            "focus_changed": .bool(diff.focusChanged),
            "window_changed": .bool(diff.windowChanged),
            "change_reasons": .array(diff.changeReasons.map { .string($0) }),
            // Exclude censuses under mismatched walk bounds and report that exclusion so caps cannot masquerade as changes.
            "diff_comparable": .bool(diff.diffComparable),
            // Include changed read-only values, even when affordances are unchanged.
            "readouts_changed": .array(diff.readoutsChanged.prefix(MacActClosedLoop.maxDiffRows).map { $0.toJSON(valueChars: valueChars) }),
            "readouts_changed_total": .int(Int64(diff.readoutsChangedTotal)),
            "readouts_added_total": .int(Int64(diff.readoutsAddedTotal)),
            "readouts_removed_total": .int(Int64(diff.readoutsRemovedTotal)),
            // Keep readout rows alongside totals so the receipt retains the value the act produced.
            "readouts_added": .array(diff.readoutsAdded.prefix(MacActClosedLoop.maxDiffRows).map { $0.toJSON(valueChars: valueChars) }),
            "readouts_removed": .array(diff.readoutsRemoved.prefix(MacActClosedLoop.maxDiffRows).map { $0.toJSON(valueChars: valueChars) }),
        ]
        if let reason = diff.diffIncomparableReason {
            out["diff_incomparable_reason"] = .string(reason)
            out["diff_incomparable_note"] = .string(
                "the affordance and readout added/removed counts are not counted as evidence of change here — "
                + "the two compiles did not see the same window. The rows are still listed; the "
                + "identity-keyed channels (changed, focus, modal, window title, readout values) are unaffected."
            )
        }
        if diff.focusChanged {
            var focus: [String: JSONValue] = [:]
            focus["handle"] = diff.focusHandleAfter.map { .string($0) } ?? .null
            focus["role"] = diff.focusRoleAfter.map { .string($0) } ?? .null
            focus["label"] = diff.focusLabelJSONAfter ?? diff.focusLabelAfter.map {
                MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
            } ?? .null
            out["focus_changed_to"] = .object(focus)
        }
        if diff.modalAppeared || diff.modalDisappeared {
            out["modal"] = .object([
                "appeared": .bool(diff.modalAppeared),
                "disappeared": .bool(diff.modalDisappeared),
                "label": diff.modalLabelAfter.map {
                    MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                } ?? .null,
            ])
        }
        if diff.windowTitleChanged {
            out["window_title"] = diff.windowTitleAfter.map {
                MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
            } ?? .null
        }
        return out
    }

}
