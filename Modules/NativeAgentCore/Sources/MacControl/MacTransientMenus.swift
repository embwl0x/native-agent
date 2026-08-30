import Foundation
import NativeAgentCore
import PersistenceCore

/// Current native menu evidence, not a second accessibility address space.
/// Item paths remain private to this read and are never used as window paths.
public enum MacTransientMenus {
    public static let maxMenus = 4
    public static let maxItems = 80

    /// Menus can be siblings of an ancestor of the focused web area, while
    /// focus itself stays on the page. This is a bounded neighborhood search,
    /// not a second full-window walk or a hidden menu-bar expansion.
    static func nearFocus<Element>(
        _ focused: Element?, parent: (Element) -> Element?,
        children: (Element, Int) -> [Element], isMenu: (Element) -> Bool,
        equal: (Element, Element) -> Bool
    ) -> [Element] {
        var cursor = focused
        var ancestors: [Element] = [], menus: [Element] = []
        var remaining = 96
        func append(_ element: Element) {
            if menus.count < maxMenus, isMenu(element), !menus.contains(where: { equal($0, element) }) {
                menus.append(element)
            }
        }
        for _ in 0..<16 {
            guard let current = cursor, !ancestors.contains(where: { equal($0, current) }) else { break }
            ancestors.append(current)
            append(current)
            if remaining > 0, menus.count < maxMenus {
                let nearby = children(current, min(16, remaining)).prefix(min(16, remaining))
                remaining -= nearby.count
                for child in nearby { append(child) }
            }
            if menus.count == maxMenus { break }
            cursor = parent(current)
        }
        return menus
    }

    public struct Menu: Sendable, Equatable {
        public let frame: MacAXFrame
        public let items: [MacAXAttributes]
        public let truncated: Bool
    }

    static func validFrame(_ frame: MacAXFrame) -> Bool {
        [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
            && frame.w > 0 && frame.h > 0
            && abs(frame.x) < 100_000 && abs(frame.y) < 100_000
            && frame.w < 30_000 && frame.h < 30_000
    }

    public static func read(source: any MacAXElementSource, pid: Int32) -> [Menu] {
        guard pid != getpid(), source.isTrusted(), source.frontmostApp()?.processIdentifier == pid else { return [] }
        var remaining = maxItems
        return source.transientMenuRoots(pid: pid).prefix(maxMenus).compactMap { root in
            guard remaining > 0, let attributes = source.attributes(of: root),
                  attributes.role == "AXMenu", let frame = attributes.frame, validFrame(frame) else { return nil }
            let snapshot = MacAccessibilityReader.walk(
                source: source, root: root,
                limits: MacAXLimits(maxNodes: maxItems + 1, maxDepth: 5, valueChars: 200)
            )
            let items = snapshot.nodes.compactMap { node -> MacAXAttributes? in
                let item = node.attributes
                guard item.role == "AXMenuItem", let rect = item.frame, validFrame(rect),
                      item.enabled || !(item.title ?? item.value ?? "").isEmpty,
                      rect.x >= frame.x - 1, rect.y >= frame.y - 1,
                      rect.x + rect.w <= frame.x + frame.w + 1,
                      rect.y + rect.h <= frame.y + frame.h + 1 else { return nil }
                return item
            }.prefix(remaining)
            remaining -= items.count
            return Menu(frame: frame, items: Array(items), truncated: snapshot.truncated || remaining == 0)
        }
    }

    public static func json(_ menus: [Menu]) -> JSONValue {
        .array(menus.map { menu in
            .object([
                "frame": menu.frame.toJSON(),
                "truncated": .bool(menu.truncated),
                "items": .array(menu.items.map { item in
                    var result: [String: JSONValue] = [
                        "role": .string("AXMenuItem"), "enabled": .bool(item.enabled),
                        "frame": item.frame?.toJSON() ?? .null,
                    ]
                    if let title = item.title ?? item.value, !title.isEmpty {
                        result["label"] = MacScreenViewTextRedaction.redactedLegendString(title, valueChars: 200)
                    }
                    if let selected = item.selected { result["selected"] = .bool(selected) }
                    return .object(result)
                }),
            ])
        })
    }

    /// Include real open menu geometry in the capture without changing the
    /// document window's identity or inventing a full-screen semantic root.
    public static func captureFrame(window: MacAXFrame?, menus: [Menu]) -> MacAXFrame? {
        guard var frame = window, validFrame(frame) else { return window }
        for menu in menus {
            let x = min(frame.x, menu.frame.x), y = min(frame.y, menu.frame.y)
            frame = MacAXFrame(x: x, y: y,
                               w: max(frame.x + frame.w, menu.frame.x + menu.frame.w) - x,
                               h: max(frame.y + frame.h, menu.frame.y + menu.frame.h) - y)
        }
        return frame
    }
}
