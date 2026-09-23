import Foundation
import NativeAgentCore
import PersistenceCore

/// A form for one currently advertised owner schema. Bound target fields are
/// supplied by the selected card and cannot be replaced by form values.
struct AgentWorkspaceForm: Sendable, Equatable {
    let tool: String
    let title: String
    let bound: [String: JSONValue]
    let parameters: JSONValue
    /// Drafts are input, never an admitted action. Only explicitly supported
    /// non-authority fields can cross restart; the current owner is rechecked.
    let draftID: UUID
    private(set) var draftValues: [String: JSONValue] = [:]
    private(set) var showOptionalFields = false
    private(set) var focusedField: String?
    private(set) var notice: String?
    private(set) var needsOutcomeReview = false
    private(set) var schemaIssue: String?
    // Ephemeral owner read, never a default to submit or persisted authority.
    private(set) var currentValues: [String: JSONValue] = [:]

    func readingHelperSettings(perform: AgentWorkspace.Perform) async throws -> Self {
        guard helperFields != nil, let id = bound["id"] else { return self }
        var copy = self
        copy.currentValues = [:]
        let result = try await perform("bot_list", ["id": id])
        guard case .object(let root) = result, root["status"] == .string("ok"),
              case .array(let bots)? = root["bots"], bots.count == 1,
              case .object(let bot) = bots[0], bot["id"] == id else {
            return copy.withSchemaIssue("The selected helper could not be read. Your draft stays; no settings were changed.")
        }
        let aliases = ["reasoning_effort": "reasoningEffort", "output_format": "output_format"]
        for name in properties.keys {
            guard let value = bot[aliases[name] ?? name] else { continue }
            guard let bytes = try? value.serializedData(pretty: false), bytes.count <= 8192 else { continue }
            copy.currentValues[name] = value
        }
        return copy
    }

    func withSchemaIssue(_ message: String?) -> Self {
        var copy = self
        copy.schemaIssue = message.map { String($0.prefix(1000)) }
        return copy
    }

    func requiringOutcomeReview() -> Self {
        var copy = self
        copy.needsOutcomeReview = true
        copy.notice = "An attempt was made. Its outcome must be checked before another submission; reopening this draft never repeats it."
        return copy
    }

    func afterOutcomeReview() -> Self {
        var copy = self
        copy.needsOutcomeReview = false
        copy.notice = "A new attempt is now available. Submit only after checking that the previous attempt did not complete."
        return copy
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(schema: LLMToolSchema, title: String, bound: [String: JSONValue]) throws {
        let parameters = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let root) = parameters,
              case .object(let properties)? = root["properties"], properties.count <= 80,
              Set(bound.keys).isSubset(of: Set(properties.keys)),
              schema.parametersJSON.count <= 131_072 else {
            throw Failure(message: "This capability does not provide a bounded form with these target fields. Nothing was run.")
        }
        self.tool = schema.name; self.title = title; self.bound = bound; self.parameters = parameters
        self.draftID = UUID()
        self.showOptionalFields = self.required.isEmpty
    }

    private static let harnessFields: Set<String> = ["__session_id", "current_session_id", "sender", "surface"]

    // Existing legacy drafts containing `fields` keep their original shape.
    // Newly opened exact-helper settings present ordinary editable fields; the
    // form packs the owner's object only at submission, under the same schema.
    private var helperFields: [String: JSONValue]? {
        guard tool == "bot_update", bound["id"] != nil, draftValues["fields"] == nil,
              case .object(let root) = parameters, case .object(let properties)? = root["properties"],
              case .object(let fields)? = properties["fields"],
              case .object(let nested)? = fields["properties"], !nested.isEmpty else { return nil }
        return nested
    }

    var properties: [String: JSONValue] {
        if let helperFields { return helperFields }
        guard case .object(let root) = parameters, case .object(let values)? = root["properties"] else { return [:] }
        return values.filter { !Self.harnessFields.contains($0.key) && bound[$0.key] == nil
            && !(tool == "write_file" && bound["expected_content_sha256"] != nil && $0.key == "append") }
    }

    var required: Set<String> {
        if helperFields != nil { return [] }
        guard case .object(let root) = parameters, case .array(let names)? = root["required"] else { return [] }
        return Set(names.compactMap { if case .string(let name) = $0 { return name }; return nil })
            .subtracting(bound.keys).subtracting(Self.harnessFields)
    }

    var singleTextField: String? {
        guard required.count == 1, let name = required.first,
              Self.types(properties[name]).contains("string") else { return nil }
        return name
    }

    var missingRequired: Set<String> { required.subtracting(draftValues.keys) }

    func withNotice(_ message: String?) -> Self {
        var copy = self
        copy.notice = message.map { String($0.prefix(1000)) }
        return copy
    }

    func showingOptionalFields(_ show: Bool) -> Self {
        var copy = self
        copy.showOptionalFields = show
        copy.focusedField = nil
        return copy
    }

    private func focusing(_ name: String?) -> Self {
        var copy = self
        copy.focusedField = name
        return copy
    }

    func clearing(_ field: String) -> Self {
        var copy = self
        copy.draftValues.removeValue(forKey: field)
        copy.focusedField = nil
        copy.notice = nil
        return copy
    }

    /// A single selected field takes plain text. Choosing this action only edits
    /// the resident draft; submission remains a separate, explicitly selected action.
    func editing(field: String, text: String) throws -> Self {
        try updating(fields: .array([.object(["field": .string(field), "value": .string(text)])]), text: nil)
    }

    /// Preserve incomplete and type-invalid text so correction never requires
    /// rebuilding the rest of the form. Unknown/duplicate/bound fields and
    /// oversized inputs are rejected without changing the original draft.
    func updating(fields: JSONValue?, text: String?) throws -> Self {
        var supplied: [String: JSONValue] = [:]
        if let fields, fields != .null {
            guard case .array(let entries) = fields, entries.count <= 80 else {
                throw Failure(message: "Fill fields with a list of field/value pairs. Your existing draft is still here.")
            }
            for entry in entries {
                guard case .object(let pair) = entry, Set(pair.keys) == ["field", "value"],
                      case .string(let name)? = pair["field"], let value = pair["value"],
                      properties[name] != nil, supplied[name] == nil else {
                    throw Failure(message: "A field is unknown, repeated, or belongs to the selected target. Your existing draft is still here; nothing was run.")
                }
                guard value == .null || Self.isString(value) else {
                    throw Failure(message: "Field values must be text, or JSON null for a nullable field. Your existing draft is still here; nothing was run.")
                }
                supplied[name] = value
            }
        }
        if let text {
            guard let key = singleTextField, supplied[key] == nil else {
                throw Failure(message: "Choose the field to edit, or use named fields. Text on this form is only a shortcut for its single required text field.")
            }
            supplied[key] = .string(text)
        }
        var copy = self
        copy.draftValues.merge(supplied) { _, new in new }
        guard copy.draftValues.values.reduce(0, { total, value in
            if case .string(let text) = value { return total + text.utf8.count }
            return total + ((try? value.serializedData(pretty: false).count) ?? 65_537)
        }) <= 65_536 else {
            throw Failure(message: "Form values are limited to 64 KiB. Your existing draft is still here; nothing was run.")
        }
        copy.focusedField = nil
        copy.notice = nil
        return copy
    }

    /// Workspace forms advertise workspace-relative paths. Freeze that meaning
    /// before saving/submission so Full Mac's legacy repo cwd cannot redirect it.
    /// Explicit selected/absolute targets retain their existing owner semantics.
    func resolvingWorkspacePath(root: URL) throws -> Self {
        guard ["write_file", "read_file", "list_dir"].contains(tool), bound["path"] == nil,
              case .string(let raw)? = draftValues["path"] else { return self }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return self }
        let alias = SwiftToolDispatcher.normalizeWorkspaceAlias(path, workspaceRoot: root)
        let resolved = (alias.hasPrefix("/") ? URL(fileURLWithPath: alias)
            : root.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == base || resolved.path.hasPrefix(base + "/") else {
            throw Failure(message: "A relative path must stay inside the workspace. Choose an explicit absolute path for another location; nothing was run.")
        }
        return try updating(fields: .array([.object(["field": .string("path"), "value": .string(resolved.path)])]), text: nil)
    }

    private func selecting(_ value: JSONValue, field: String) -> Self {
        var copy = self
        copy.draftValues[field] = value
        let bytes = copy.draftValues.values.reduce(0) { total, value in
            if case .string(let text) = value { return total + text.utf8.count }
            return total + ((try? value.serializedData(pretty: false).count) ?? 65_537)
        }
        guard bytes <= 65_536 else {
            return withNotice("That option exceeds the 64 KiB draft limit. Your existing draft is still here; nothing was run.")
        }
        copy.focusedField = nil
        copy.notice = nil
        return copy
    }

    private var orderedFields: [String] {
        properties.keys.sorted {
            if required.contains($0) != required.contains($1) { return required.contains($0) }
            return $0 < $1
        }
    }

    private func fieldContent(_ name: String) -> JSONValue {
        let spec = Self.object(properties[name])
        var field: [String: JSONValue] = ["field": .string(name),
            "label": .string(AgentWorkspaceEnvironment.title(name)), "required": .bool(required.contains(name)),
            "type": spec["type"] ?? (Self.types(properties[name]).isEmpty ? .string("structured") : .array(Self.types(properties[name]).sorted().map(JSONValue.string)))]
        if case .string(let description)? = spec["description"] { field["help"] = .string(String(description.prefix(550))) }
        if let choices = spec["enum"] { field["choices"] = choices }
        if let value = spec["default"] { field["default"] = value }
        if let current = currentValues[name] { field["current_value"] = current }
        if let value = draftValues[name] {
            field["value"] = value
            do { _ = try Self.convert(value, schema: properties[name], name: name) }
            catch { field["needs_correction"] = .string(error.localizedDescription) }
        }
        if Self.types(properties[name]).contains(where: { ["array", "object"].contains($0) }) || spec["oneOf"] != nil || spec["anyOf"] != nil {
            field["shape"] = properties[name]
        }
        return .object(field)
    }

    private func choices(_ name: String) -> [JSONValue]? {
        let spec = Self.object(properties[name])
        if case .array(let values)? = spec["enum"] { return values }
        let allowed = Self.types(properties[name])
        if allowed == ["boolean"] { return [.bool(true), .bool(false)] }
        if allowed == ["boolean", "null"] { return [.bool(true), .bool(false), .null] }
        return nil
    }

    var projection: AgentWorkspaceProjection {
        if let name = focusedField, properties[name] != nil, let values = choices(name) {
            return .init(title: "Choose " + AgentWorkspaceEnvironment.title(name), content: fieldContent(name),
                items: values.map { value in
                    let label: String
                    if case .string(let text) = value { label = text }
                    else { label = (try? value.serialize(pretty: false)) ?? "Unavailable option" }
                    return .init(title: label, content: .object(["value": value]), actions: [
                        .init(label: "Choose " + String(label.prefix(120)), action: .open(.form(selecting(value, field: name))))
                    ])
                }, actions: [.init(label: "Return to draft", action: .open(.form(focusing(nil))))])
        }
        let visible = orderedFields.filter { required.contains($0) || draftValues[$0] != nil || showOptionalFields }
        let corrections = orderedFields.filter { name in
            guard let value = draftValues[name] else { return false }
            do { _ = try Self.convert(value, schema: properties[name], name: name); return false }
            catch { return true }
        }
        var actions: [AgentWorkspaceButton] = [.init(label: "Keep entered fields", action: .saveForm(self))]
        if needsOutcomeReview {
            // Only immutable selected targets identify the previous effect;
            // editable fields may already describe a different intended action.
            if let source = AgentWorkspaceEnvironment.readback(tool: tool, input: bound) {
                actions.insert(.init(label: "Check previous result", action: .open(source)), at: 0)
            }
            actions.append(.init(label: "I checked the outcome — prepare another attempt", action: .reviewDraft(self)))
        } else if schemaIssue == nil {
            actions.insert(.init(label: tool == "write_file" && bound["expected_content_sha256"] != nil ? "Save revision" : "Submit " + title, action: .submit(self),
                needsText: singleTextField.map { draftValues[$0] == nil } ?? false), at: 0)
        }
        for name in corrections.prefix(3).reversed() {
            let label = "Correct " + AgentWorkspaceEnvironment.title(name)
            actions.insert(.init(label: label,
                action: choices(name) == nil ? .editFormField(self, field: name) : .open(.form(focusing(name))),
                needsText: choices(name) == nil), at: 0)
        }
        if schemaIssue != nil {
            actions.insert(.init(label: "Refresh form availability", action: .open(.form(self))), at: 0)
        }
        actions.append(.init(label: "Discard this draft", action: .discardDraft(self)))
        if properties.keys.contains(where: { !required.contains($0) }) {
            actions.append(.init(label: showOptionalFields ? "Hide optional fields" : "More options", action: .open(.form(showingOptionalFields(!showOptionalFields)))))
        }
        var content: [String: JSONValue] = [
            "status": .string(needsOutcomeReview ? "outcome_review_required" : !corrections.isEmpty ? "needs_correction" : missingRequired.isEmpty ? "draft_ready" : "draft_in_progress"),
            "fields": .array(visible.map { name in .object([
                "field": .string(name), "required": .bool(required.contains(name)),
                "has_value": .bool(draftValues[name] != nil)
            ]) }), "selected_target": .object(bound.filter { $0.key != "expected_content_sha256" }),
            "missing_required": .array(missingRequired.sorted().map(JSONValue.string)),
            "needs_correction": .array(corrections.map(JSONValue.string)),
            "optional_fields_hidden": .int(Int64(properties.keys.filter { !visible.contains($0) }.count)),
            "input_help": .string("Edit fields or choose options; your entries stay. Only Submit runs the action. Check an uncertain outcome before preparing another attempt."),
            "restart_storage": .string(canPersist ? "Draft inputs can be saved in this chat; storage status is reported by the desktop. Reopening rechecks the current schema and never submits." : "Temporary draft: this form can contain live targets or authority and is not written to disk. It stays resident until explicitly discarded or completed; restart will not retain it.")
        ]
        if let notice { content["notice"] = .string(notice) }
        if tool == "write_file", bound["expected_content_sha256"] != nil {
            content["input_help"] = .string("Edit the text and choose Save revision. The destination stays attached; saving checks the original file and opens the saved result. Leaving preserves this draft.")
        }
        if let schemaIssue { content["schema_attention"] = .string(schemaIssue) }
        if helperFields != nil {
            content["input_help"] = .string("Edit only the settings you want to change, then Save settings. The selected helper, its conversation and saved replies stay attached. Leaving keeps your edits; nothing runs automatically.")
            actions = actions.map { action in
                var action = action
                if case .submit = action.action { action.label = "Save settings" }
                return action
            }
        }
        let items = visible.map { name -> AgentWorkspaceItem in
            let label = AgentWorkspaceEnvironment.title(name)
            var buttons: [AgentWorkspaceButton] = []
            if choices(name) != nil {
                buttons.append(.init(label: "Choose " + label, action: .open(.form(focusing(name)))))
            } else {
                buttons.append(.init(label: "Edit " + label, action: .editFormField(self, field: name), needsText: true))
            }
            if draftValues[name] != nil { buttons.append(.init(label: "Clear " + label, action: .open(.form(clearing(name))))) }
            return .init(title: label, content: fieldContent(name), actions: buttons)
        }
        return .init(title: title, content: .object(content), items: items, actions: actions)
    }

    func arguments(fields: JSONValue?, text: String?) throws -> [String: JSONValue] {
        guard !needsOutcomeReview else { throw Failure(message: "Check the previous outcome and explicitly prepare another attempt before submitting. Nothing was repeated.") }
        guard schemaIssue == nil else { throw Failure(message: "The current owner schema is unavailable or changed. This draft is preserved; nothing was run.") }
        let draft = try updating(fields: fields, text: text)
        guard draft.missingRequired.isEmpty else {
            throw Failure(message: "Still needed: " + draft.missingRequired.sorted().map(AgentWorkspaceEnvironment.title).joined(separator: ", ") + ". Your draft is still here; nothing was run.")
        }
        var args = bound
        if helperFields != nil {
            guard !draft.draftValues.isEmpty else { throw Failure(message: "Choose a setting to change first. Nothing was submitted.") }
            var fields: [String: JSONValue] = [:]
            for (name, raw) in draft.draftValues { fields[name] = try Self.convert(raw, schema: properties[name], name: name) }
            args["fields"] = .object(fields)
            return args
        }
        for (name, raw) in draft.draftValues { args[name] = try Self.convert(raw, schema: properties[name], name: name) }
        return args
    }

    /// Explicit input owners only. Generic capability forms, browser leases,
    /// credentials and approval/connection payloads deliberately stay resident.
    var canPersist: Bool {
        let allowed: Set<String> = ["write_file", "save_skill", "commit_memory", "recall_memory", "mail_search",
            "desk_note", "desk_update_item", "desk_set_status", "desk_add_ref", "desk_add_item",
            "mail_send", "mail_reply", "messages_send", "chat_reply", "agent_message",
            "mac_calendar_create_event", "mac_reminders_create", "image_generate", "bot_create", "bot_update"]
        let stableTargets: Set<String> = ["path", "expected_content_sha256", "name", "id", "handle", "memory_id", "message_id", "expected_message_id",
            "thread_id", "conversation_session_id", "agent", "conversation"]
        let forbidden = ["token", "secret", "password", "credential", "authorization", "cookie", "header", "lease", "approval", "permission", "trust", "provider", "session_grant"]
        return allowed.contains(tool) && Set(bound.keys).isSubset(of: stableTargets)
            && bound.values.allSatisfy { value in
                if case .string(let text) = value { return text.utf8.count <= 8192 && !text.contains("\0") }
                if case .int(let number) = value { return number >= 0 }
                return false
            }
            && !(Array(bound.keys) + Array(draftValues.keys)).contains { key in
                forbidden.contains { key.lowercased().contains($0) }
            }
    }

    struct Stored: Codable {
        var id: UUID
        var tool: String
        var title: String
        var bound: [String: JSONValue]
        var parameters: JSONValue
        var values: [String: JSONValue]
        var needsOutcomeReview: Bool

        init(_ form: AgentWorkspaceForm) {
            id = form.draftID; tool = form.tool; title = form.title; bound = form.bound
            parameters = form.parameters; values = form.draftValues; needsOutcomeReview = form.needsOutcomeReview
        }

        func restored() throws -> AgentWorkspaceForm {
            guard title.count <= 300, tool.count <= 160,
                  case .object(let root) = parameters, case .object(let properties)? = root["properties"],
                  properties.count <= 80, Set(bound.keys).isSubset(of: Set(properties.keys)),
                  try parameters.serializedData(pretty: false).count <= 131_072,
                  values.values.reduce(0, { total, value in
                      if case .string(let text) = value { return total + text.utf8.count }
                      return total + ((try? value.serializedData(pretty: false).count) ?? 65_537)
                  }) <= 65_536 else {
                throw Failure(message: "The saved draft is invalid. Its bytes were preserved.")
            }
            let form = AgentWorkspaceForm(stored: self)
            guard form.canPersist, Set(values.keys).isSubset(of: Set(form.properties.keys)),
                  Set(values.keys).isDisjoint(with: AgentWorkspaceForm.harnessFields) else {
                throw Failure(message: "The saved draft contains unsupported fields. Its bytes were preserved.")
            }
            return form
        }
    }

    private init(stored: Stored) {
        tool = stored.tool; title = stored.title; bound = stored.bound; parameters = stored.parameters
        draftID = stored.id; draftValues = stored.values; needsOutcomeReview = stored.needsOutcomeReview
        notice = "Restored draft inputs. The current owner schema and permissions are checked before submission; nothing was resumed."
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row)? = value { return row }; return [:]
    }

    private static func isString(_ value: JSONValue) -> Bool {
        if case .string = value { return true }; return false
    }

    private static func types(_ value: JSONValue?, depth: Int = 0) -> Set<String> {
        guard depth < 8 else { return [] }
        let row = object(value)
        var direct: Set<String> = []
        if case .string(let type)? = row["type"] { direct = [type] }
        if case .array(let entries)? = row["type"] { direct = Set(entries.compactMap { if case .string(let type) = $0 { return type }; return nil }) }
        for union in ["anyOf", "oneOf"] {
            guard case .array(let branches)? = row[union], !branches.isEmpty else { continue }
            let branchTypes = branches.map { types($0, depth: depth + 1) }
            // Do not guess a primitive when a union contains an untyped branch.
            guard branchTypes.allSatisfy({ !$0.isEmpty }) else { return direct }
            let combined = branchTypes.reduce(into: Set<String>()) { $0.formUnion($1) }
            direct = direct.isEmpty ? combined : direct.intersection(combined)
        }
        return direct
    }

    private static func permitsNull(_ schema: JSONValue?, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        let row = object(schema)
        if let type = row["type"] {
            guard types(.object(["type": type])).contains("null") else { return false }
        }
        if case .array(let choices)? = row["enum"], !choices.contains(.null) { return false }
        if let constant = row["const"], constant != .null { return false }
        if case .array(let branches)? = row["anyOf"], !branches.contains(where: { permitsNull($0, depth: depth + 1) }) { return false }
        if case .array(let branches)? = row["oneOf"], branches.filter({ permitsNull($0, depth: depth + 1) }).count != 1 { return false }
        if case .array(let branches)? = row["allOf"], !branches.allSatisfy({ permitsNull($0, depth: depth + 1) }) { return false }
        // These less common combinators need an owner's full validator; never
        // assume an explicit null is allowed by an unrecognized restriction.
        if ["not", "if", "then", "else", "$ref"].contains(where: { row[$0] != nil }) { return false }
        return true
    }

    private static func convert(_ rawValue: JSONValue, schema: JSONValue?, name: String) throws -> JSONValue {
        let row = object(schema), allowed = types(schema)
        if rawValue == .null {
            guard allowed.contains("null"), permitsNull(schema) else {
                throw Failure(message: "\(name) does not allow an explicit null. Nothing was run.")
            }
            return .null
        }
        let value: JSONValue
        if case .string(let raw) = rawValue, allowed.contains("string") { value = .string(raw) }
        else {
            let parsed: JSONValue
            if case .string(let raw) = rawValue {
                guard let decoded = try? JSONValue.parse(Data(raw.utf8)) else {
                    if allowed.subtracting(["null"]) == ["boolean"] {
                        throw Failure(message: "Choose true or false for \(name). Nothing was run.")
                    }
                    throw Failure(message: "\(name) needs the number, boolean, list or object shown in its form.")
                }
                parsed = decoded
            } else {
                // Only an owner-advertised choice can populate a typed resident
                // value. Caller-supplied field updates still require text/null.
                parsed = rawValue
            }
            let kind: String
            switch parsed {
            case .null: kind = "null"
            case .string: kind = "string"
            case .int: kind = "integer"
            case .double: kind = "number"
            case .bool: kind = "boolean"
            case .array: kind = "array"
            case .object: kind = "object"
            }
            guard allowed.isEmpty || allowed.contains(kind) || (kind == "integer" && allowed.contains("number")) else {
                throw Failure(message: "\(name) has the wrong value type. Nothing was run.")
            }
            value = parsed
        }
        if value == .null, !(allowed.contains("null") && permitsNull(schema)) {
            throw Failure(message: "\(name) does not allow null. Nothing was run.")
        }
        if case .array(let choices)? = row["enum"], !choices.contains(value) { throw Failure(message: "Choose an offered value for \(name). Nothing was run.") }
        return value
    }
}
