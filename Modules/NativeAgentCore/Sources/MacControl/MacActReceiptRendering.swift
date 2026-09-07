import Foundation
import PersistenceCore

/// Pure rendering of the observed act effect; execution and verification stay
/// with SwiftNativeMacControl and MacActClosedLoop.
enum MacActReceiptRendering {
    /// The readout THIS act moved: the first one that CHANGED, else the first
    /// one it ADDED, else nil (nothing moved ⇒ the glance falls back to the
    /// ranked readout, which is the honest description of a screen the act did
    /// not change).
    ///
    /// Resolved back to the post-act percept's own `MacLookReadout` so the
    /// glance prints COMPILE-TIME-redacted text — a diff row's text re-rendered
    /// here would have no node context and could print what the look withheld.
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

    /// Redacted before/after snapshot of the element the verb acted on.
    /// - Parameters:
    ///   - labelJSON/valueJSON: gpt-5.5 round-2 B4 — the text as a COMPILE saw
    ///     it, with the enclosing-caption context (the group titled "CVV" two
    ///     rows up) that a re-redaction of the stored string cannot recover.
    ///     `acted_element` is the third way a hidden value could leave, after
    ///     `changed` and `affordances_removed`.
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

    /// Agent round 2 — the semantic summary of a BULK change.
    ///
    /// Alongside (never instead of) the capped lists: counts by role, so "44
    /// added" is legible as "40 AXRow, 3 AXButton, 1 AXImage", and the container
    /// the focus now sits in with its first children named, which is what
    /// "Finder switched to list view" actually looks like from the inside.
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
        // gpt-5.5 round-3 B4 — the summary describes nodes the percept does not
        // carry as affordances (the focus container, its first children), and
        // it was redacting their RAW attributes with the standalone shape test
        // only. That test cannot see the group titled "CVV" two rows up, so a
        // child labeled with a card code sailed through `first_children` while
        // the affordance list correctly withheld it. This is the SAME
        // full-context pass the compile ran, over the same snapshot: the
        // summary can no longer disagree with the percept it summarizes.
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
                    // Fail closed: a node the map has no verdict for is a node
                    // nothing judged in context, and the context-free second
                    // opinion is the hole itself.
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
            "affordances_added": .array(diff.added.map { $0.toJSON(valueChars: valueChars) }),
            "affordances_removed": .array(diff.removed.map { entry in
                .object([
                    "handle": .string(entry.handle),
                    "role": .string(entry.role),
                    // B4: the entry's COMPILE-TIME redaction, not a fresh
                    // context-free pass over the stored string.
                    "label": entry.labelJSON ?? entry.label.map {
                        MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                    } ?? .null,
                ])
            }),
            "changed": .array(diff.changed.map { $0.toJSON(valueChars: valueChars) }),
            "affordances_added_total": .int(Int64(diff.addedTotal)),
            "affordances_removed_total": .int(Int64(diff.removedTotal)),
            "changed_total": .int(Int64(diff.changedTotal)),
            "focus_changed": .bool(diff.focusChanged),
            // `window_changed` NAMES ITS EVIDENCE (Agent round 2). It is exactly
            // `!change_reasons.isEmpty`, so a true with nothing behind it cannot
            // be emitted.
            "window_changed": .bool(diff.windowChanged),
            "change_reasons": .array(diff.changeReasons.map { .string($0) }),
            // …and when the two compiles ran under different bounds, the
            // added/removed census is EXCLUDED from those reasons and the
            // payload says so rather than dropping it silently.
            "diff_comparable": .bool(diff.diffComparable),
            // Agent acceptance round 1, finding A — the READ-ONLY values that
            // moved. Pressing Equals changes no affordance label; without this
            // the answer she acted for was nowhere in the result.
            "readouts_changed": .array(diff.readoutsChanged.map { $0.toJSON(valueChars: valueChars) }),
            "readouts_changed_total": .int(Int64(diff.readoutsChangedTotal)),
            "readouts_added_total": .int(Int64(diff.readoutsAddedTotal)),
            "readouts_removed_total": .int(Int64(diff.readoutsRemovedTotal)),
            // The ROWS, not just the totals: `readouts_added_total: 2` does not
            // contain "42", and that number was the whole reason she acted.
            "readouts_added": .array(diff.readoutsAdded.map { $0.toJSON(valueChars: valueChars) }),
            "readouts_removed": .array(diff.readoutsRemoved.map { $0.toJSON(valueChars: valueChars) }),
        ]
        if let reason = diff.diffIncomparableReason {
            out["diff_incomparable_reason"] = .string(reason)
            out["diff_incomparable_note"] = .string(
                "the affordances added/removed census is NOT counted as evidence of change here — "
                + "the two compiles did not see the same window. The rows are still listed; the "
                + "identity-keyed channels (changed, focus, modal, window title, readouts) are unaffected."
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
