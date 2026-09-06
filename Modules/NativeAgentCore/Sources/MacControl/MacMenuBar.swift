// MacMenuBar.swift — THE MENU BAR ORGAN (fable51 sweep item 29).
//
// Every Mac app publishes its complete functionality, in words, in a tree that
// never moves: File › Export › PDF…. It is the cheapest deterministic route to
// anything an app can do — no coordinate, no scroll, no guessing which toolbar
// glyph means "export". And `AXMenuBar` was EXPLICITLY EXCLUDED from every walk
// in this module (`MacAccessibilityReader` refuses to descend into one;
// `MacTransientMenus` says in its own doc comment that it is "not a hidden
// menu-bar expansion"), so File › Export › PDF was unreachable.
//
// The exclusion was right for the walks it guarded. A window walk that
// wandered into the menu bar would spend its whole node budget on 400 menu
// items nobody asked about, on every single look. This organ is the other
// answer to the same problem: ON DEMAND, bounded, and separate.
//
// THE BOUNDS, and why each one:
//   • `maxPathDepth` = 3 NAMED levels (File › Export › PDF…). Beyond three, a
//     Mac menu is a preference tree, and the cost of walking it is paid on
//     every menu read for a path nobody speaks.
//   • `maxItems` — a hard ceiling on leaves returned, reported when it bites.
//   • ONE walk. No secondary walk, no "expand this submenu" round trip: an
//     organ that needs a second call to answer the first is a corridor, and
//     the reason `mac_look`'s glance exists is that Agent should pay for the
//     answer, not for the parsing.
//
// AND THE REFUSALS ARE WORDS. A disabled item is not a missing item: "Export is
// there but greyed out right now" is a fact about the app's state and the only
// answer that stops a model from re-trying the same press forever.

import Foundation
import NativeAgentCore
import PersistenceCore

public enum MacMenuBar {
    /// Named levels in a path. `File › Export › PDF…` is three.
    public static let maxPathDepth = 3
    /// Leaves returned by one read.
    public static let maxItems = 160
    /// Children considered under any one menu. A menu with more than this is
    /// a list, and this organ says so rather than walking it.
    public static let maxChildrenPerMenu = 60
    /// Characters of one item's title. Menu titles are short by design; a
    /// longer one is a document name that wandered into a Window menu.
    public static let maxTitleChars = 80

    /// The separators a person or a model might type between levels. `›` is
    /// what this organ PRINTS; the rest are accepted because refusing a path
    /// over a character is a refusal about typography, not about the app.
    public static let separators: [String] = ["›", "»", "->", "→", ">", "/", "|"]

    /// One addressable menu path.
    public struct Item: Sendable, Equatable {
        /// The named levels, outermost first: ["File", "Export", "PDF…"].
        public let titlePath: [String]
        /// The child-index chain from the AXMenuBar element. This is the ACT
        /// address and it never leaves this module — it is bookkeeping, and the
        /// four-verb wall exists so bookkeeping does not reach the model.
        public let path: [Int]
        public let enabled: Bool
        /// True when this item OPENS something rather than doing something. It
        /// is still returned (a model that cannot see "Export" cannot ask for
        /// "Export › PDF"), and pressing it is still a legitimate act.
        public let hasSubmenu: Bool

        public init(
            titlePath: [String],
            path: [Int],
            enabled: Bool,
            hasSubmenu: Bool
        ) {
            self.titlePath = titlePath
            self.path = path
            self.enabled = enabled
            self.hasSubmenu = hasSubmenu
        }

        /// How this organ PRINTS a path.
        public var display: String { titlePath.joined(separator: " › ") }
    }

    public struct Reading: Sendable, Equatable {
        public let items: [Item]
        /// True when a bound cut the walk. Reported so a model can tell "this
        /// app has no Export" apart from "I stopped counting".
        public let truncated: Bool
        /// Set when there is no menu bar to read at all.
        public let unavailable: String?

        public init(items: [Item], truncated: Bool, unavailable: String? = nil) {
            self.items = items
            self.truncated = truncated
            self.unavailable = unavailable
        }
    }

    // MARK: - The walk

    /// ONE bounded, read-only descent of the app's menu bar. Nothing is
    /// pressed, nothing is opened, no attribute is written.
    ///
    /// Structure, which is fixed across every Cocoa and Electron app:
    ///   AXMenuBar → AXMenuBarItem "File" → AXMenu → AXMenuItem "Export"
    ///                                             → AXMenu → AXMenuItem "PDF…"
    /// The AXMenu wrappers carry no name, so they cost a level of TREE depth
    /// but not a level of NAMED depth — which is why the cap is expressed in
    /// named levels: it is the thing a person counts when they say
    /// "File › Export › PDF".
    public static func read(source: any MacAXElementSource, pid: Int32) -> Reading {
        guard pid != getpid() else {
            return Reading(items: [], truncated: false, unavailable: "self_process")
        }
        guard source.isTrusted() else {
            return Reading(items: [], truncated: false, unavailable: "accessibility_not_trusted")
        }
        guard let root = source.menuBarRoot(pid: pid) else {
            return Reading(items: [], truncated: false, unavailable: "no_menu_bar")
        }
        var items: [Item] = []
        var truncated = false

        func descend(_ element: MacAXElementRef, titles: [String], indices: [Int]) {
            guard items.count < maxItems else {
                truncated = true
                return
            }
            let children = source.children(of: element, limit: maxChildrenPerMenu + 1)
            if children.count > maxChildrenPerMenu { truncated = true }
            for (offset, child) in children.prefix(maxChildrenPerMenu).enumerated() {
                guard items.count < maxItems else {
                    truncated = true
                    return
                }
                guard let attributes = source.attributes(of: child) else { continue }
                let indexPath = indices + [offset]
                switch attributes.role {
                case "AXMenu":
                    // An unnamed wrapper: it costs tree depth, never a named
                    // level, so descending through it is free of the cap.
                    descend(child, titles: titles, indices: indexPath)
                case "AXMenuBarItem", "AXMenuItem":
                    let title = cleanTitle(attributes.title ?? attributes.value)
                    // A separator publishes no title. It is furniture, not an
                    // address; skipping it is not hiding anything.
                    guard let title, !title.isEmpty else { continue }
                    let names = titles + [title]
                    // Does it OPEN something? The AXMenu child is the answer,
                    // and asking costs one ranged child read. Its real OFFSET
                    // is recorded, never assumed to be 0 — the act address is
                    // a child-index chain and an assumed index is a wrong-press
                    // waiting to happen in the one app that orders it otherwise.
                    let submenu = source
                        .children(of: child, limit: 4)
                        .enumerated()
                        .first { source.attributes(of: $0.element)?.role == "AXMenu" }
                    items.append(Item(
                        titlePath: names,
                        path: indexPath,
                        enabled: attributes.enabled,
                        hasSubmenu: submenu != nil
                    ))
                    if let submenu, names.count < maxPathDepth {
                        descend(
                            submenu.element,
                            titles: names,
                            indices: indexPath + [submenu.offset]
                        )
                    } else if submenu != nil {
                        // The cap stopped the descent, and saying so is the
                        // difference between "this app has no PDF export" and
                        // "I did not look that deep".
                        truncated = true
                    }
                default:
                    continue
                }
            }
        }

        descend(root, titles: [], indices: [])
        return Reading(items: items, truncated: truncated)
    }

    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTitleChars))
    }

    // MARK: - Naming one path

    public enum Resolution: Sendable, Equatable {
        case matched(Item)
        /// Nothing answers to that path. `nearest` is what the menu bar DOES
        /// offer at the same depth, so a refusal teaches instead of stonewalls.
        case notFound(nearest: [String])
        case ambiguous(candidates: [String])
        /// It is right there, and the app has it switched off. A different fact
        /// from "not found", and the only one that stops a re-try loop.
        case disabled(Item)
    }

    /// Split a spoken path on any accepted separator.
    public static func components(_ raw: String) -> [String] {
        var working = raw
        for separator in separators where separator != "›" {
            working = working.replacingOccurrences(of: separator, with: "›")
        }
        return working
            .split(separator: "›")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Resolve a spoken path against one reading.
    ///
    /// Three passes, narrowest first, exactly like the background-sight
    /// resolver and for the same reason: an exact "Export" must never lose to a
    /// substring match on "Export Selection…". A pass finding several is an
    /// ANSWER (the candidates), never a coin flip.
    public static func resolve(_ raw: String, among items: [Item]) -> Resolution {
        // BOTH SIDES are normalized, and that is not a detail: a menu title
        // carries a trailing ellipsis ("Export…") that a person never types,
        // and normalizing only the menu's side means the exact path this organ
        // PRINTS does not resolve when it is handed straight back.
        let wanted = components(raw).map(normalized)
        guard !wanted.isEmpty else { return .notFound(nearest: topLevelNames(items)) }
        func levels(_ item: Item) -> [String] { item.titlePath.map(normalized) }

        let sameDepth = items.filter { $0.titlePath.count == wanted.count }
        let passes: [(Item) -> Bool] = [
            { levels($0) == wanted },
            { zip(levels($0), wanted).allSatisfy { $0.hasPrefix($1) } },
            { zip(levels($0), wanted).allSatisfy { $0.contains($1) } },
        ]
        for pass in passes {
            let hits = sameDepth.filter(pass)
            if hits.count == 1 {
                return hits[0].enabled ? .matched(hits[0]) : .disabled(hits[0])
            }
            if hits.count > 1 {
                return .ambiguous(candidates: hits.map(\.display).sorted())
            }
        }
        return .notFound(nearest: nearest(to: wanted, among: items))
    }

    /// Menu titles carry trailing ellipses ("Export…") and surrounding space;
    /// a person says "Export". Neither is part of the name.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func topLevelNames(_ items: [Item]) -> [String] {
        items.filter { $0.titlePath.count == 1 }.map(\.display)
    }

    /// What the menu bar offers at the depth she asked about, so a "not found"
    /// carries the alternatives rather than a dead end.
    static func nearest(to wanted: [String], among items: [Item], limit: Int = 10) -> [String] {
        let sameDepth = items.filter { $0.titlePath.count == wanted.count }
        let pool = sameDepth.isEmpty ? items.filter { $0.titlePath.count == 1 } : sameDepth
        guard let head = wanted.first.map(normalized) else {
            return Array(pool.prefix(limit).map(\.display))
        }
        // Prefer the ones whose FIRST level she got right — "File › Exprt"
        // should come back with File's items, not with the whole menu bar.
        let sameBranch = pool.filter { normalized($0.titlePath.first ?? "").hasPrefix(head) }
        let chosen = sameBranch.isEmpty ? pool : sameBranch
        return Array(chosen.prefix(limit).map(\.display))
    }

    // MARK: - Words and JSON

    /// The refusal, in words. Every branch names the state and the next move.
    public static func words(for resolution: Resolution, requested raw: String) -> String? {
        switch resolution {
        case .matched:
            return nil
        case .disabled(let item):
            return "\"\(item.display)\" is in the menu but it is greyed out right now, "
                + "so pressing it would do nothing. The app has it switched off in this state."
        case .ambiguous(let candidates):
            return "\"\(raw)\" matches more than one menu path — "
                + candidates.joined(separator: ", ") + ". Say which one."
        case .notFound(let nearest):
            guard !nearest.isEmpty else {
                return "There is no \"\(raw)\" in this app's menu bar."
            }
            return "There is no \"\(raw)\" in this app's menu bar. What is there: "
                + nearest.joined(separator: ", ") + "."
        }
    }

    /// The read's payload. Titles go through the same shape redactor every
    /// other perception organ uses: a Window menu lists open document names,
    /// and a document can be called anything.
    public static func json(_ reading: Reading) -> JSONValue {
        var out: [String: JSONValue] = [
            "count": .int(Int64(reading.items.count)),
            "truncated": .bool(reading.truncated),
            "max_depth": .int(Int64(maxPathDepth)),
        ]
        if let unavailable = reading.unavailable {
            out["available"] = .bool(false)
            out["status"] = .string(unavailable)
            return .object(out)
        }
        out["available"] = .bool(true)
        out["paths"] = .array(reading.items.map { item in
            var row: [String: JSONValue] = [
                "path": MacScreenViewTextRedaction.redactedLegendString(
                    item.display,
                    valueChars: maxTitleChars * maxPathDepth
                ),
                "enabled": .bool(item.enabled),
            ]
            if item.hasSubmenu { row["opens_submenu"] = .bool(true) }
            return .object(row)
        })
        return .object(out)
    }
}
