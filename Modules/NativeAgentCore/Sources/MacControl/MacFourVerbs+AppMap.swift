import Foundation

// Her-screen Phase 5 — per-app maps, the four-verb side (store: MacAppMaps.swift).
//
// Record: only after the closed loop VERIFIED an act on a named control
// (effect observed, the acted element answered the name). Use: only when the
// fresh read had no match, only on an element the live look handed back at the
// remembered path, and only when that live element's kind and label still
// match the entry AND answer the request. Anything else ignores the entry and
// weakens or evicts it. A stale map can cost a miss, never a wrong click.
extension MacFourVerbs {
    /// Controls, never content: a row or a field's label can be someone's
    /// file name, subject line or typed text.
    static let mappableKinds: Set<String> = [
        "button", "menu", "popup", "checkbox", "radio", "tab", "menu item", "disclosure", "stepper", "slider",
    ]

    /// The name as a map key, or nil for an address that is positional
    /// (`row 3`, `button 2 Remove`) or aimed inside a thing (`top of …`).
    static func mapName(_ target: String) -> String? {
        let whole = normalize(target)
        guard !whole.isEmpty, labeledOrdinalAddress(in: target) == nil,
              stripWithinTargetAimQualifier(target) == whole else { return nil }
        if !isExactOnlyName(normalize(stripRoleWords(target))), ordinalAddress(in: target) != nil { return nil }
        return whole
    }

    /// A verified act on a named control: remember where it lives.
    func rememberVerified(_ target: String, _ candidate: ActTarget, in sighting: Sighting) async {
        guard let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
              let asked = Self.mapName(target), let path = candidate.sourceAXPath, !path.isEmpty,
              let label = candidate.label, !label.isEmpty,
              !candidate.isSupplemental, !candidate.regionOnly, !candidate.physicalOnly,
              Self.mappableKinds.contains(candidate.kind),
              // By its LABEL — an alias (focus) or an ordinal is not a name.
              Self.answers(target, ActTarget(handle: candidate.handle, label: label, kind: candidate.kind,
                                             ordinal: nil, enabled: true)) else { return }
        let store = MacAppMapStore.shared
        // App chrome only. A label already vetted when it was first stored is
        // not re-checked; a new one must be a stable system label or appear in
        // the app's own menu bar. Anything else could be content: not stored.
        if !(await store.has(bundle: bundle, window: window, asked: asked, label: label)) {
            if !MacAppMaps.isStableSystemLabel(label) {
                guard await inMenuBar(label, app: sighting.appName) else { return }
            }
        }
        await store.record(bundle: bundle, window: window, asked: asked, label: label,
                           kind: candidate.kind, path: path)
    }

    /// Whether the app's own menu bar has an item with exactly this label
    /// (menus only, never a window walk).
    private func inMenuBar(_ label: String, app: String?) async -> Bool {
        guard let app else { return false }
        guard let result = try? await host.dispatch(action: "menu", body: [
            "find": .string(label), "app": .string(app),
        ]), result.ok else { return false }
        let wanted = Self.normalize(label)
        return Self.array(Self.object(result.output)["found"]).contains { row in
            guard let path = Self.string(Self.object(row)["path"]),
                  let last = MacMenuBar.components(path).last else { return false }
            return Self.normalize(last) == wanted
        }
    }

    /// The fresh read has no match for `target`. A remembered control is used
    /// only when the live element at its path still is that control. Two or
    /// more remembered controls answering is a question, never a pick.
    func mapResolve(_ target: String, in sighting: Sighting) async -> Resolution? {
        guard let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
              let asked = Self.mapName(target) else { return nil }
        let bare = Self.normalize(Self.stripRoleWords(target))
        // A role named in the request ("Save menu item") binds: a remembered
        // Save BUTTON does not answer it.
        let namedKind = Self.trailingRoleQualifier(in: target)?.kind ?? Self.roleHint(in: target)
        let store = MacAppMapStore.shared
        let entries = await store.entries(bundle: bundle, window: window)
            .filter { ($0.asked == asked || Self.normalize($0.label) == bare)
                && (namedKind == nil || $0.kind == namedKind) }
        let live = sighting.targets
        var verified: [ActTarget] = []
        for entry in entries {
            guard let element = live.first(where: { $0.sourceAXPath == entry.path && !$0.isSupplemental }) else {
                // Not in this read at all: maybe gone, maybe past the read's
                // caps. Weaken, don't guess.
                await store.penalize(bundle: bundle, window: window, path: entry.path, evict: false)
                continue
            }
            if element.kind == entry.kind, !element.regionOnly,
               Self.normalize(element.label ?? "") == Self.normalize(entry.label),
               Self.answers(target, element) {
                if !verified.contains(where: { $0.sourceAXPath == element.sourceAXPath }) { verified.append(element) }
                continue
            }
            // Something else lives at that path now.
            await store.penalize(bundle: bundle, window: window, path: entry.path, evict: true)
        }
        if verified.count > 1 { return .ambiguous(verified) }
        return verified.first.map { .hit($0) }
    }

    /// The paths the text render actually printed (its row/control caps).
    static func renderedPaths(_ screen: MacScreenRender.Screen, options: MacScreenRender.Options) -> Set<[Int]> {
        var paths = Set(screen.controls.prefix(options.maxControls).compactMap(\.sourceAXPath))
        for content in screen.contents {
            paths.formUnion(content.rows.prefix(options.maxRows).compactMap(\.sourceAXPath))
        }
        return paths
    }

    /// `KNOWN   AC · C · 0–9 · × (from memory, act by name)` — remembered
    /// controls that ARE in the live read (checked by path, kind and label)
    /// but did not make the render. nil when there are none.
    func knownLine(bundle: String?, windowKind: String?, live: [ActTarget], rendered: Set<[Int]>?) async -> String? {
        guard let bundle, let windowKind, let rendered else { return nil }
        let entries = await MacAppMapStore.shared.entries(bundle: bundle, window: windowKind)
        guard !entries.isEmpty else { return nil }
        var seen: Set<[Int]> = []
        let names = entries
            .filter { !rendered.contains($0.path) }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
            .compactMap { entry -> String? in
                guard seen.insert(entry.path).inserted,
                      let element = live.first(where: { $0.sourceAXPath == entry.path && !$0.isSupplemental }),
                      element.kind == entry.kind, let label = element.label,
                      Self.normalize(label) == Self.normalize(entry.label) else { return nil }
                return label
            }
        guard !names.isEmpty else { return nil }
        return "KNOWN   " + Self.compactNames(Array(names.prefix(24))).joined(separator: " · ")
            + " (from memory, act by name)"
    }

    /// Single digits that form one unbroken run print as `0–9`.
    static func compactNames(_ names: [String]) -> [String] {
        let digits = names.compactMap { $0.count == 1 ? $0.first?.wholeNumberValue : nil }
        let unique = Set(digits)
        guard unique.count >= 3, let low = unique.min(), let high = unique.max(),
              high - low + 1 == unique.count else { return names }
        var out: [String] = []
        var placed = false
        for name in names {
            if name.count == 1, name.first?.wholeNumberValue != nil {
                if !placed { out.append("\(low)–\(high)"); placed = true }
            } else {
                out.append(name)
            }
        }
        return out
    }
}
