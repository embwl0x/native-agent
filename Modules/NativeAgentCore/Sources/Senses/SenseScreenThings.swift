import Foundation
import PersistenceCore

/// Window handles retain exact selections. Supplemental AX surfaces use the
/// existing native target resolver, which re-observes them before acting.
public enum SenseScreenThings {
    public static let accessibilityReadLine = "raw view · accessibility · Read directly from the app's accessibility tree."
    public static func isNativeScreenPage(_ page: NativePage) -> Bool {
        guard case .app = page.corner, page.address.hasPrefix("{"),
              let value = try? JSONValue.parse(Data(page.address.utf8)) else { return false }
        return string(object(value)["__sense_screen_frame"]) != nil
    }

    /// What a screen page prints for a thing: the handle of an exact window
    /// selection (the page states its frame once), else the whole address.
    public static func printed(_ address: String) -> String {
        guard address.hasPrefix("{"), case .object(let fields)? = try? JSONValue.parse(Data(address.utf8)),
              string(fields["frame_id"]) != nil, let handle = string(fields["handle"]) else { return address }
        return handle
    }

    public static func page(in result: JSONValue) throws -> NativePage? {
        guard case .object(let fields) = result, let page = object(fields["detail"])["native_page"] else { return nil }
        return try JSONDecoder().decode(NativePage.self, from: page.serializedData(pretty: false))
    }

    public static func text(in result: JSONValue) -> String? {
        guard case .object(let fields) = result, object(fields["detail"])["native_page"] != nil else { return nil }
        return string(fields["text"])
    }

    public static func captureStatus(in result: JSONValue) -> String? {
        guard case .object(let fields) = result else { return nil }
        return string(object(fields["detail"])["pixel_capture_status"])
    }
    public static func things(in result: JSONValue, corner: SenseCorner) throws -> [NativeThing] {
        guard case .app(let bundleID) = corner, case .object(let fields) = result else { return [] }
        if let page = try page(in: result) { return page.things }
        let detail = object(fields["detail"])
        let controls = object(detail["controls"] ?? fields["controls"])
        guard let frame = string(controls["frame_id"]), case .array(let rows)? = controls["affordances"] else { return [] }
        return try rows.compactMap { row in
            let node = object(row)
            guard let handle = string(node["handle"]),
                  let role = string(node["role"]) else { return nil }
            let kind = plainRole(role)
            let label = string(node["label"])
            let name = label == role ? kind : label ?? kind
            let address = try JSONValue.object(["app": .string(bundleID), "frame_id": .string(frame), "handle": .string(handle)]).serialize(pretty: false)
            let detail = [string(node["value"]), string(node["state"]), node["enabled"] == .bool(false) ? "disabled" : nil].compactMap { $0 }.joined(separator: "; ")
            // A look affordance is interactive: the loop presses it (AXPress or
            // the click at its frame). Its row says nothing about editability.
            return NativeThing(name: name, kind: kind, address: address, detail: detail.isEmpty ? nil : detail,
                verbs: node["enabled"] == .bool(false) ? [] : verbs(role: role, actions: ["AXPress"], settable: []))
        }
    }

    /// The one verb table: what a control advertises, never its role alone.
    /// Press needs AXPress; typing and focus need a settable value or focus,
    /// so a read-only field offers neither. Select and toggle are a press (or
    /// the click at its frame) on a row or a checkable.
    public static func verbs(role: String, actions: [String], settable: [String]) -> [String] {
        var verbs = actions.contains("AXPress") ? ["press"] : []
        if editableRoles.contains(role) {
            if settable.contains("AXValue") || settable.contains("AXFocused") { verbs += ["type"] }
            if settable.contains("AXFocused") { verbs += ["focus"] }
        }
        if ["AXRow", "AXCell", "AXOutlineRow", "AXListItem", "AXRadioButton", "AXTab"].contains(role) { verbs += ["select"] }
        if ["AXCheckBox", "AXSwitch"].contains(role) { verbs += ["toggle"] }
        return verbs
    }

    public static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField"]

    private static func plainRole(_ role: String) -> String {
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return bare.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
    }

    public static func selection(_ address: String, verb: String, args: JSONValue) throws -> JSONValue {
        guard case .object(let target) = try JSONValue.parse(Data(address.utf8)),
              string(target["app"]) != nil,
              case .object(let supplied) = args,
              supplied.keys.allSatisfy({ ["text", "mode"].contains($0) }) else {
            throw SenseFailure(code: "invalid_address", message: "Read the screen again to select a current app thing.")
        }
        var request: [String: JSONValue]
        var activation = verb
        if string(target["frame_id"]) != nil, string(target["handle"]) != nil {
            request = ["app": target["app"]!, "frame_id": target["frame_id"]!, "handle": target["handle"]!]
            if let related = object(target["__sense_screen_activations"])[verb],
               let handle = string(object(related)["handle"]), let boundVerb = string(object(related)["verb"]) {
                request["handle"] = .string(handle)
                activation = boundVerb
            }
        } else if let name = string(target["target"]), string(target["__sense_screen_frame"]) != nil {
            request = ["app": target["app"]!, "target": .string(name), "__sense_native_surface": .bool(true)]
            if let label = string(target["label"]) { request["__sense_native_label"] = .string(label) }
        } else {
            throw SenseFailure(code: "invalid_address", message: "Read the screen again to select a current app thing.")
        }
        guard ["press", "open", "type", "select", "focus", "toggle", "scroll"].contains(activation) else {
            throw SenseFailure(code: "invalid_address", message: "Read the screen again to select a current app thing.")
        }
        request["verb"] = .string(activation == "press" ? "click" : activation)
        request.merge(supplied) { _, new in new }
        return .object(request)
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let fields)? = value { fields } else { [:] } }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value, !text.isEmpty { text } else { nil } }
}
