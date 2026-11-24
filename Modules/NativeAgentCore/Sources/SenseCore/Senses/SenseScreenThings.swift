import Foundation
import PersistenceCore
// Blueprint: | `SenseScreenThings.swift` | Exact window selections, related-action bindings and in-turn mac.act verbs |

/// Keep exact window handles; re-observe supplemental AX targets through the native resolver before acting.
public enum SenseScreenThings {
    public static let accessibilityReadLine = "raw view · accessibility · Read directly from the app's accessibility tree."
    public static func isNativeScreenPage(_ page: NativePage) -> Bool {
        guard case .app = page.corner, page.address.hasPrefix("{"),
              let value = try? JSONValue.parse(Data(page.address.utf8)) else { return false }
        return JSONValue.objectOrEmpty(value)["__sense_screen_frame"]?.nonemptyString != nil
    }

    /// Use exact selection handles so the page need state its frame only once; other addresses remain whole.
    public static func printed(_ address: String) -> String {
        guard address.hasPrefix("{"), case .object(let fields)? = try? JSONValue.parse(Data(address.utf8)),
              fields["frame_id"]?.nonemptyString != nil, let handle = fields["handle"]?.nonemptyString else { return address }
        return handle
    }

    public static func page(in result: JSONValue) throws -> NativePage? {
        guard case .object(let fields) = result, let page = JSONValue.objectOrEmpty(fields["detail"])["native_page"] else { return nil }
        return try JSONDecoder().decode(NativePage.self, from: page.serializedData(pretty: false))
    }

    public static func text(in result: JSONValue) -> String? {
        guard case .object(let fields) = result, JSONValue.objectOrEmpty(fields["detail"])["native_page"] != nil else { return nil }
        return fields["text"]?.nonemptyString
    }

    public static func captureStatus(in result: JSONValue) -> String? {
        guard case .object(let fields) = result else { return nil }
        return JSONValue.objectOrEmpty(fields["detail"])["pixel_capture_status"]?.nonemptyString
    }
    public static func things(in result: JSONValue, corner: SenseCorner) throws -> [NativeThing] {
        guard case .app(let bundleID) = corner, case .object(let fields) = result else { return [] }
        if let page = try page(in: result) { return page.things }
        let detail = JSONValue.objectOrEmpty(fields["detail"])
        let controls = JSONValue.objectOrEmpty(detail["controls"] ?? fields["controls"])
        guard let frame = controls["frame_id"]?.nonemptyString, case .array(let rows)? = controls["affordances"] else { return [] }
        return try rows.compactMap { row in
            let node = JSONValue.objectOrEmpty(row)
            guard let handle = node["handle"]?.nonemptyString,
                  let role = node["role"]?.nonemptyString else { return nil }
            let kind = plainRole(role)
            let label = node["label"]?.nonemptyString
            let name = label == role ? kind : label ?? kind
            let address = try JSONValue.object(["app": .string(bundleID), "frame_id": .string(frame), "handle": .string(handle)]).serialize(pretty: false)
            let detail = [node["value"]?.nonemptyString, node["state"]?.nonemptyString, node["enabled"] == .bool(false) ? "disabled" : nil]
                .compactMap { $0 }.joined(separator: "; ")
            // A look affordance is pressable, but supplies no evidence of editability.
            return NativeThing(name: name, kind: kind, address: address, detail: detail.isEmpty ? nil : detail,
                verbs: node["enabled"] == .bool(false) ? [] : verbs(role: role, actions: ["AXPress"], settable: []))
        }
    }

    /// Advertise verbs from actual capabilities, never role alone: pressing requires AXPress or a frame click, while typing/focus requires settable state.
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
              target["app"]?.nonemptyString != nil,
              case .object(let supplied) = args,
              supplied.keys.allSatisfy({ ["text", "mode"].contains($0) }) else {
            throw SenseFailure(code: "invalid_address", message: "Read the screen again to select a current app thing.")
        }
        var request: [String: JSONValue]
        var activation = verb
        if target["frame_id"]?.nonemptyString != nil, target["handle"]?.nonemptyString != nil {
            request = ["app": target["app"]!, "frame_id": target["frame_id"]!, "handle": target["handle"]!]
            if let related = JSONValue.objectOrEmpty(target["__sense_screen_activations"])[verb],
               let handle = JSONValue.objectOrEmpty(related)["handle"]?.nonemptyString, let boundVerb = JSONValue.objectOrEmpty(related)["verb"]?.nonemptyString {
                request["handle"] = .string(handle)
                activation = boundVerb
            }
        } else if let name = target["target"]?.nonemptyString, target["__sense_screen_frame"]?.nonemptyString != nil {
            request = ["app": target["app"]!, "target": .string(name), "__sense_native_surface": .bool(true)]
            if let label = target["label"]?.nonemptyString { request["__sense_native_label"] = .string(label) }
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
}
