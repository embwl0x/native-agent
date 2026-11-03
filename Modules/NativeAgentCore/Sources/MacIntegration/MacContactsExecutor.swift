import AuthoredCapabilities
import Foundation
import Contacts
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacContactsExecutor.swift` | concrete `CNContactStore` ownership, raw argument schemas/admission, single-route selection, complete labeled-array mutation validation and projection; Messages handles read as numbers, never contact names |

public enum MacContactsExecutor {
    // MARK: - One caller contract (forms, app door and native dispatch)

    private static func textSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "pattern": .string(#"\S"#), "description": .string(description)])
    }

    private enum SearchKind: String { case identifier, name, phone, email }
    private static let searchKinds: [SearchKind] = [.identifier, .name, .phone, .email]

    public static let searchParameters: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "identifier": textSchema("Exact identifier from contacts.search; never interpreted as a name."),
            "name": textSchema("Name fragment; selects only a name lookup."),
            "phone": textSchema("Phone number; selects only a phone lookup."),
            "email": textSchema("Email address; selects only an email lookup."),
            "query": textSchema("Search text: @ selects email, phone-shaped text selects phone, otherwise name. When several fields are supplied, selection order is identifier, name, phone, email, query; only one lookup runs."),
            "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(100),
                "description": .string("Maximum contacts (1–100; omit for 20).")]),
        ]),
        "anyOf": .array((searchKinds.map(\.rawValue) + ["query"]).map { .object(["required": .array([.string($0)])]) }),
    ])

    private static func labeledArraySchema(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description),
            "items": .object(["type": .string("object"), "additionalProperties": .bool(false),
                "required": .array([.string("label"), .string("value")]),
                "properties": .object([
                    "label": textSchema("Label such as home, work, mobile or other."),
                    "value": textSchema("Nonblank phone number or email address."),
                ])])])
    }

    public static let saveParameters: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "identifier": textSchema("Exact identifier from contacts.search to update; never a name."),
            "given_name": textSchema("First name; omit to preserve it on update."),
            "family_name": textSchema("Last name; omit to preserve it on update."),
            "organization": textSchema("Organization; omit to preserve it on update."),
            "phones": labeledArraySchema("Phone entries [{label,value}], added without replacing existing numbers; [] adds none."),
            "emails": labeledArraySchema("Email entries [{label,value}], added without replacing existing addresses; [] adds none."),
        ]),
        "anyOf": .array(["identifier", "given_name", "family_name"].map {
            .object(["required": .array([.string($0)])])
        }),
    ])

    public static let deleteParameters: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object(["identifier": textSchema("Exact identifier from contacts.search to delete; never a name.")]),
        "required": .array([.string("identifier")]),
    ])

    public static func parameters(for tool: String) -> JSONValue? {
        switch tool {
        case "contacts_search": searchParameters
        case "contacts_create_or_update": saveParameters
        case "contacts_delete": deleteParameters
        default: nil
        }
    }

    /// Runs before protocol normalization and again at the concrete owner.
    /// Internal transport metadata is not a public Contacts argument.
    public static func validateArguments(tool: String, input: [String: JSONValue]) throws {
        guard let schema = parameters(for: tool) else { return }
        let arguments = input.filter { !$0.key.hasPrefix("__") }
        if let problem = JSONValue.object(arguments).schemaProblem(schema: schema, path: "$") {
            throw ToolFailureError("\(problem.path) must be \(problem.expected). No Contacts lookup or save ran.",
                argumentPath: problem.path, effects: .none, code: "invalid_input")
        }
    }

    // MARK: - TCC status (for Mac Integration permission wizard)

    /// Returns the current Contacts authorization status in the wizard
    /// vocabulary: "granted" | "denied" | "restricted" | "limited" | "not_determined".
    /// Does NOT trigger a prompt — pure status query.
    /// `.limited` is macOS 15+ (rawValue == 4); on macOS 14 it's unreachable.
    public static func currentAuthorizationStatus() -> String {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status.rawValue == 4 { return "limited" }
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "not_determined"
        }
    }

    // MARK: - Public API

    /// Select a query once, before reading Contacts. A miss never selects another route.
    public static func search(input: [String: JSONValue]) async throws -> JSONValue {
        try validateArguments(tool: "contacts_search", input: input)
        let selected = try selectedSearch(input)
        let limit = input["limit"]?.exactIntegerValue ?? 20
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]

        do {
            let matches: [CNContact]
            switch selected.kind {
            case .identifier:
                matches = [try store.unifiedContact(withIdentifier: selected.text, keysToFetch: keys)]
            case .phone:
                matches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: selected.text)), keysToFetch: keys)
            case .email:
                matches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: selected.text), keysToFetch: keys)
            case .name:
                matches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: selected.text), keysToFetch: keys)
            }
            let bounded = Array(matches.prefix(limit))
            let serialized: [JSONValue] = bounded.map { contactJSON($0) }
            var result: [String: JSONValue] = [
                "status": .string("completed"),
                "count": .int(Int64(serialized.count)),
                "contacts": .array(serialized),
                "lookup": .string(selected.kind.rawValue),
            ]
            if matches.isEmpty {
                result["message"] = .string("No contact matches \"\(selected.text)\" by \(selected.kind.rawValue).")
            } else if matches.count > bounded.count {
                result["message"] = .string("Showing \(bounded.count) of \(matches.count); narrow the query.")
            }
            return .object(result)
        } catch {
            return failedEnvelope(error: error)
        }
    }

    /// Validate the entire request before reading or saving; arrays contain only labeled entries.
    public static func createOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try validateArguments(tool: "contacts_create_or_update", input: input)
        let phones = try parseLabeledValues(input["phones"], field: "phones")
        let emails = try parseLabeledValues(input["emails"], field: "emails")
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }

        let givenName = input["given_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let familyName = input["family_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let identifier = input["identifier"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An update by identifier needs no name; a new contact does.
        guard !givenName.isEmpty || !familyName.isEmpty || !identifier.isEmpty else {
            return failedEnvelope(reason: "Give given_name or family_name for a new contact, or identifier (from contacts_search) to update one.")
        }

        let organization = input["organization"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let writeKeys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]

        let mutable: CNMutableContact
        let action: String

        do {
        // Without an identifier, one exact full-name match is updated.
        let sameName = identifier.isEmpty
            ? try exactNameMatches(store: store, name: [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " "), keys: writeKeys)
            : []
        var target: CNContact? = sameName.count == 1 ? sameName[0] : nil
        if !identifier.isEmpty {
            target = try store.unifiedContact(withIdentifier: identifier, keysToFetch: writeKeys)
        }
        if let existing = target {
            // Copy the selected card to preserve fields the update does not name.
            guard let copy = existing.mutableCopy() as? CNMutableContact else {
                return failedEnvelope(reason: "Failed to copy existing contact for update")
            }
            mutable = copy
            action = "updated"
        } else {
            mutable = CNMutableContact()
            action = "created"
        }

        if !givenName.isEmpty { mutable.givenName = givenName }
        if !familyName.isEmpty { mutable.familyName = familyName }
        if !organization.isEmpty { mutable.organizationName = organization }
        // Phones and emails extend existing values without replacing them.
        func digits(_ text: String) -> String { text.filter(\.isNumber) }
        let havePhones = Set(mutable.phoneNumbers.map { digits($0.value.stringValue) })
        mutable.phoneNumbers += phones.filter { !havePhones.contains(digits($0.value)) }.map { entry in
            CNLabeledValue(
                label: contactLabel(forPhone: entry.label),
                value: CNPhoneNumber(stringValue: entry.value)
            )
        }
        let haveEmails = Set(mutable.emailAddresses.map { ($0.value as String).lowercased() })
        mutable.emailAddresses += emails.filter { !haveEmails.contains($0.value.lowercased()) }.map { entry in
            CNLabeledValue(
                label: contactLabel(forEmail: entry.label),
                value: entry.value as NSString
            )
        }

        let saveRequest = CNSaveRequest()
        if action == "updated" {
            saveRequest.update(mutable)
        } else {
            saveRequest.add(mutable, toContainerWithIdentifier: nil)
        }
        try store.execute(saveRequest)

        var result: [String: JSONValue] = [
            "status": .string("completed"),
            "identifier": .string(mutable.identifier),
            "action": .string(action),
            "contact": contactJSON(mutable),
        ]
        if identifier.isEmpty, action == "updated" { result["message"] = .string("Updated the one existing contact with this name.") }
        if sameName.count > 1 { result["message"] = .string("\(sameName.count) contacts already had this name, so a new one was made; pass identifier to update one.") }
        return .object(result)
        } catch {
            return failedEnvelope(error: error)
        }
    }

    /// Standard failed-envelope shape, parallel to permissionDeniedEnvelope
    /// and matching the AppleScript bridge's `failedEnvelope(integration:reason:)`.
    private static func failedEnvelope(error: Error) -> JSONValue {
        let failure = error as NSError
        if failure.domain == CNErrorDomain, failure.code == CNError.Code.authorizationDenied.rawValue {
            return permissionDeniedEnvelope()
        }
        return failedEnvelope(reason: error.localizedDescription)
    }

    private static func failedEnvelope(reason: String) -> JSONValue {
        .object([
            "status": .string("failed"),
            "integration": .string("contacts"),
            "reason": .string(reason),
        ])
    }

    /// Delete a contact by identifier (CNContact.identifier from a prior
    /// search result). Gated on contacts/.write. Required: "identifier".
    /// Returns: {status, action: "deleted", identifier}.
    public static func delete(input: [String: JSONValue]) async throws -> JSONValue {
        try validateArguments(tool: "contacts_delete", input: input)
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }
        guard let identifier = input["identifier"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return failedEnvelope(reason: "Supply the exact identifier from contacts.search.")
        }
        let writeKeys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]
        do {
            let existing = try store.unifiedContact(withIdentifier: identifier, keysToFetch: writeKeys)
            guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                return failedEnvelope(reason: "Failed to obtain mutable copy")
            }
            let req = CNSaveRequest()
            req.delete(mutable)
            try store.execute(req)
            return .object([
                "status": .string("completed"),
                "action": .string("deleted"),
                "identifier": .string(existing.identifier),
                "name": .string([existing.givenName, existing.familyName].filter { !$0.isEmpty }.joined(separator: " ")),
            ])
        } catch {
            return failedEnvelope(error: error)
        }
    }

    // MARK: - Numbers for handles (Messages)

    /// Emails and explicit international numbers retain their whole identity.
    /// A local number has no region evidence here, so cannot name a person.
    private static func handleKey(_ raw: String) -> String {
        if raw.contains("@") { return raw.lowercased().trimmingCharacters(in: .whitespaces) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+"), trimmed.dropFirst().allSatisfy({ "0123456789 ()-.".contains($0) }) else { return "" }
        let digits = trimmed.filter { "0123456789".contains($0) }
        guard (7...15).contains(digits.count), digits.first != "0" else { return "" }
        return "+" + digits
    }

    /// A Messages read with each number as a person would write it, so a reply
    /// copies it instead of re-typing raw digits: participants' `name` and each
    /// message's `sender_name` are that number, never a contact's name. The
    /// number is the identity she works with (User 10-28: going by names
    /// drifted to the wrong person). Handles are untouched.
    public static func naming(_ result: [String: JSONValue]) async -> [String: JSONValue] {
        func name(_ handle: JSONValue?) -> String? {
            guard case .string(let raw)? = handle else { return nil }
            let key = handleKey(raw)
            if key.isEmpty { return nil }
            let digits = raw.filter(\.isNumber)
            guard key.hasPrefix("+1"), digits.count == 11 else { return nil }
            let d = Array(digits.suffix(10))
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        var out = result
        for key in ["threads", "messages"] {
            guard case .array(let rows)? = result[key] else { continue }
            out[key] = .array(rows.map { value in
                guard case .object(var row) = value else { return value }
                if case .array(let people)? = row["participants"] {
                    row["participants"] = .array(people.map { person in
                        guard case .object(var p) = person, let found = name(p["handle"]) else { return person }
                        p["name"] = .string(found)
                        return .object(p)
                    })
                }
                if let found = name(row["sender"]) { row["sender_name"] = .string(found) }
                return .object(row)
            })
        }
        return out
    }

    // MARK: - Finding one contact

    /// Contacts whose full name is exactly `name` (case aside).
    private static func exactNameMatches(store: CNContactStore, name: String, keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: wanted), keysToFetch: keys).filter {
            [$0.givenName, $0.familyName].filter { !$0.isEmpty }.joined(separator: " ").caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    // MARK: - Authorization

    private static func permissionDeniedEnvelope() -> JSONValue {
        if SkillRunContext.handsBack { return SkillRunContext.handBack("macOS Contacts permission") }
        return .object([
            "status": .string("denied"),
            "reason": .string("os_permission_denied"),
            "integration": .string("contacts"),
            "remedy": SystemPermissionPreflight.remedy("contacts") ?? .null,
        ])
    }

    // MARK: - Serialization

    private static func contactJSON(_ contact: CNContact) -> JSONValue {
        let phones: [JSONValue] = contact.phoneNumbers.map { labeled in
            .object([
                "label": .string(labelString(labeled.label)),
                "value": .string(labeled.value.stringValue),
            ])
        }
        let emails: [JSONValue] = contact.emailAddresses.map { labeled in
            .object([
                "label": .string(labelString(labeled.label)),
                "value": .string(labeled.value as String),
            ])
        }
        return .object([
            "name": .string([contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")),
            "identifier": .string(contact.identifier),
            "givenName": .string(contact.givenName),
            "familyName": .string(contact.familyName),
            "organizationName": .string(contact.organizationName),
            "phones": .array(phones),
            "emails": .array(emails),
        ])
    }

    // MARK: - Input helpers

    private static func selectedSearch(_ input: [String: JSONValue]) throws -> (kind: SearchKind, text: String) {
        for kind in searchKinds {
            guard case .string(let raw)? = input[kind.rawValue] else { continue }
            return (kind, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if case .string(let raw)? = input["query"] {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (looksLikeEmail(text) ? .email : looksLikePhone(text) ? .phone : .name, text)
        }
        throw ToolFailureError("Supply query, identifier, name, phone or email.", argumentPath: "$", effects: .none, code: "invalid_input")
    }

    /// No item may disappear. Omission/[] add nothing; null and malformed entries fail.
    private static func parseLabeledValues(_ value: JSONValue?, field: String) throws -> [(label: String, value: String)] {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw ToolFailureError("\(field) must be an array of {label,value} entries.", argumentPath: "$." + field, effects: .none, code: "invalid_input")
        }
        return try items.enumerated().map { index, item in
            guard case .object(let entry) = item,
                  case .string(let label)? = entry["label"], case .string(let text)? = entry["value"],
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolFailureError("Each \(field) entry needs nonblank label and value strings.", argumentPath: "$.\(field)[\(index)]", effects: .none, code: "invalid_input")
            }
            return (label.trimmingCharacters(in: .whitespacesAndNewlines), text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Heuristics

    private static func looksLikePhone(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789-+() .")
        let scalars = s.unicodeScalars
        guard !scalars.isEmpty else { return false }
        guard scalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Require at least 3 digits so single dashes / dots don't qualify.
        let digitCount = s.filter { $0.isNumber }.count
        return digitCount >= 3
    }

    private static func looksLikeEmail(_ s: String) -> Bool {
        s.contains("@")
    }

    // MARK: - CN label conversion

    /// Maps a user-supplied or extracted label string to a CN label constant.
    /// Unknown labels fall through verbatim (CN accepts custom labels).
    private static func contactLabel(forPhone label: String) -> String {
        switch label.lowercased() {
        case "mobile", "cell", "cell phone": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other", "": return CNLabelOther
        case "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        default: return label
        }
    }

    private static func contactLabel(forEmail label: String) -> String {
        switch label.lowercased() {
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other", "": return CNLabelOther
        case "icloud": return CNLabelEmailiCloud
        default: return label
        }
    }

    /// Inverse of `contactLabel(forPhone:/forEmail:)` for serialization back to JSON.
    private static func labelString(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}
