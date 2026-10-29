import AuthoredCapabilities
import Foundation
import Contacts
import PersistenceCore
// Blueprint: | `MacContactsExecutor.swift` | concrete `CNContactStore` ownership, authorization, selection, mutation validation, name cache and projection |

public enum MacContactsExecutor {
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

    /// Search contacts by name fragment, phone number, or email.
    /// Input keys (any one acceptable): "query" | "name" | "phone" | "email".
    /// Optional: "limit" (int, default 20, clamped 1..100).
    public static func search(input: [String: JSONValue]) async throws -> JSONValue {
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }

        let query = firstNonEmptyString(input["query"], input["name"], input["phone"], input["email"])
            ?? ""
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = MacAppleScriptBridge.clampedInt(input["limit"], defaultValue: 20, min: 1, max: 100)

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]

        do {
            var matches: [CNContact] = []
            // 0) One exact card by its identifier (a workspace contacts.N).
            // A saved card that no longer resolves is gone: never another
            // person who happens to share its name.
            if let id = input["identifier"]?.stringValue, !id.isEmpty {
                guard let found = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else {
                    return failedEnvelope(reason: "That contact card is gone (deleted or merged); search again with contacts_search.")
                }
                matches = [found]
            }
            // 1) Name-fragment lookup ("the user", "Example User", etc.).
            if matches.isEmpty, !trimmed.isEmpty {
                let namePredicate = CNContact.predicateForContacts(matchingName: trimmed)
                matches = try store.unifiedContacts(matching: namePredicate, keysToFetch: keys)
            }
            // 2) If name search empty AND query looks like a phone, fall back.
            if matches.isEmpty, !trimmed.isEmpty, looksLikePhone(trimmed) {
                let phonePredicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: trimmed))
                matches = try store.unifiedContacts(matching: phonePredicate, keysToFetch: keys)
            }
            // 3) If still empty AND query looks like an email, fall back.
            if matches.isEmpty, !trimmed.isEmpty, looksLikeEmail(trimmed) {
                let emailPredicate = CNContact.predicateForContacts(matchingEmailAddress: trimmed)
                matches = try store.unifiedContacts(matching: emailPredicate, keysToFetch: keys)
            }
            let bounded = Array(matches.prefix(limit))
            let serialized: [JSONValue] = bounded.map { contactJSON($0) }
            var result: [String: JSONValue] = [
                "status": .string("completed"),
                "count": .int(Int64(serialized.count)),
                "contacts": .array(serialized),
            ]
            if matches.isEmpty {
                result["message"] = .string(trimmed.isEmpty ? "Nothing to search for: give part of a name, a phone number, or an email in query."
                    : "No contact matches \"\(trimmed)\"; try part of the name, a phone number, or an email. Someone who emails you often has their number and address in their mail signature.")
                // A person missing from Contacts is often in Mail.
                if !trimmed.isEmpty, !looksLikePhone(trimmed) {
                    result["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string("mail.search"),
                        "args": .object(["from": .string(trimmed), "limit": .int(3), "sort": .string("newest")])])])
                }
            } else if matches.count > bounded.count {
                result["message"] = .string("Showing \(bounded.count) of \(matches.count); narrow the query.")
            }
            return .object(result)
        } catch {
            return failedEnvelope(reason: error.localizedDescription)
        }
    }

    /// Create or update a contact. Requires `given_name` OR `family_name`.
    /// Optional: `organization`, `phones` (string or {label,value}), `emails` (same).
    /// If `identifier` is provided, the matching contact is updated; else new.
    public static func createOrUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }

        let givenName = (input["given_name"] ?? input["givenName"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let familyName = (input["family_name"] ?? input["familyName"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let identifier = input["identifier"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An update by identifier needs no name; a new contact does.
        guard !givenName.isEmpty || !familyName.isEmpty || !identifier.isEmpty else {
            return failedEnvelope(reason: "Give given_name or family_name for a new contact, or identifier (from contacts_search) to update one.")
        }

        let organization = (input["organization"] ?? input["organizationName"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phones = parseLabeledValues(input["phones"])
        let emails = parseLabeledValues(input["emails"])

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
            let resolved = try resolveContact(store: store, identifier, keys: writeKeys)
            guard let contact = resolved.contact else { return failedEnvelope(reason: resolved.problem ?? "No such contact.") }
            target = contact
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
        invalidateNameCache()

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
            return failedEnvelope(reason: error.localizedDescription)
        }
    }

    /// Standard failed-envelope shape, parallel to permissionDeniedEnvelope
    /// and matching the AppleScript bridge's `failedEnvelope(integration:reason:)`.
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
        let store = CNContactStore()
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            return permissionDeniedEnvelope()
        }
        guard let identifier = input["identifier"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return failedEnvelope(reason: "Say which contact: its identifier from contacts_search, or its exact full name.")
        }
        let writeKeys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]
        do {
            let resolved = try resolveContact(store: store, identifier, keys: writeKeys)
            guard let existing = resolved.contact else { return failedEnvelope(reason: resolved.problem ?? "No such contact.") }
            guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                return failedEnvelope(reason: "Failed to obtain mutable copy")
            }
            let req = CNSaveRequest()
            req.delete(mutable)
            try store.execute(req)
            invalidateNameCache()
            return .object([
                "status": .string("completed"),
                "action": .string("deleted"),
                "identifier": .string(existing.identifier),
                "name": .string([existing.givenName, existing.familyName].filter { !$0.isEmpty }.joined(separator: " ")),
            ])
        } catch {
            return failedEnvelope(reason: error.localizedDescription)
        }
    }

    // MARK: - Names for handles (Messages)

    private static let nameCache = NSLock()
    nonisolated(unsafe) private static var namesByHandle: [String: String]?
    nonisolated(unsafe) private static let contactChanges = NotificationCenter.default.addObserver(
        forName: .CNContactStoreDidChange, object: nil, queue: nil
    ) { _ in invalidateNameCache() }

    private static func invalidateNameCache() {
        nameCache.lock(); defer { nameCache.unlock() }
        namesByHandle = nil
    }

    /// Emails and explicit international numbers retain their whole identity.
    /// A local number has no region evidence here, so cannot name a person.
    /// Names map keys for cards whose number has no country: the ten digits.
    private static let tailKeyPrefix = "tail:"

    private static func handleKey(_ raw: String) -> String {
        if raw.contains("@") { return raw.lowercased().trimmingCharacters(in: .whitespaces) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+"), trimmed.dropFirst().allSatisfy({ "0123456789 ()-.".contains($0) }) else { return "" }
        let digits = trimmed.filter { "0123456789".contains($0) }
        guard (7...15).contains(digits.count), digits.first != "0" else { return "" }
        return "+" + digits
    }

    /// Handle → contact name, invalidated by the Contacts store's change signal.
    /// Only when Contacts access is already granted: this never asks.
    private static func contactNames() -> [String: String] {
        _ = contactChanges
        nameCache.lock(); defer { nameCache.unlock() }
        guard SystemPermissionPreflight.status(.contacts) == .granted else {
            namesByHandle = nil
            return [:]
        }
        if let cached = namesByHandle { return cached }
        let store = CNContactStore()
        var map: [String: String] = [:]
        var owners: [String: String] = [:]
        var ambiguous: Set<String> = []
        // A card's number written locally ("(555) 123-4567") has no country
        // to make a "+" key. Its ten digits still name the card: a handle
        // whose digits end in them is matched by that tail, inferring nothing.
        var tails: [String: String] = [:], tailOwners: [String: String] = [:], ambiguousTails: Set<String> = []
        let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        do {
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let shown = name.isEmpty ? contact.organizationName : name
                guard !shown.isEmpty else { return }
                func include(_ raw: String) {
                    let key = handleKey(raw)
                    if key.isEmpty, !raw.contains("@") {
                        let digits = raw.filter(\.isNumber)
                        guard digits.count == 10, !ambiguousTails.contains(digits) else { return }
                        if let owner = tailOwners[digits], owner != contact.identifier {
                            ambiguousTails.insert(digits); tails.removeValue(forKey: digits); return
                        }
                        tailOwners[digits] = contact.identifier; tails[digits] = shown
                        return
                    }
                    guard !key.isEmpty, !ambiguous.contains(key) else { return }
                    if let owner = owners[key], owner != contact.identifier {
                        ambiguous.insert(key)
                        map.removeValue(forKey: key)
                        return
                    }
                    owners[key] = contact.identifier
                    map[key] = shown
                }
                for phone in contact.phoneNumbers { include(phone.value.stringValue) }
                for email in contact.emailAddresses { include(email.value as String) }
            }
        } catch {
            NSLog("Contacts name enumeration failed: %@", error.localizedDescription)
            return [:]
        }
        for (tail, name) in tails where map[tailKeyPrefix + tail] == nil { map[tailKeyPrefix + tail] = name }
        namesByHandle = map
        return map
    }

    /// A Messages read with people named: participants' `name` becomes the
    /// card's name, and each message gets `sender_name`. Handles are untouched.
    public static func naming(_ result: [String: JSONValue]) async -> [String: JSONValue] {
        let names = await MacIntegrationPermissionStore.shared.allows(MacIntegrationID.contacts, mode: .read) ? contactNames() : [:]
        // A number with no card reads as a person would write it, so a reply
        // copies it instead of re-typing raw digits.
        func name(_ handle: JSONValue?) -> String? {
            guard case .string(let raw)? = handle else { return nil }
            let key = handleKey(raw)
            if key.isEmpty { return nil }
            if let found = names[key] { return found }
            let digits = raw.filter(\.isNumber)
            if digits.count >= 10, let found = names[tailKeyPrefix + String(digits.suffix(10))] { return found }
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

    /// Resolves a CNContact identifier or a name unique to one contact.
    private static func resolveContact(store: CNContactStore, _ raw: String, keys: [CNKeyDescriptor]) throws -> (contact: CNContact?, problem: String?) {
        if let found = try? store.unifiedContact(withIdentifier: raw, keysToFetch: keys) { return (found, nil) }
        // An identifier that no longer resolves means the card is gone; only
        // a plain name ("Mom") is looked up by name.
        if raw.contains(":AB") || raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil {
            return (nil, "That contact card is gone (deleted or merged); nothing changed. Search again with contacts_search.")
        }
        let named = try exactNameMatches(store: store, name: raw, keys: keys)
        if named.count == 1 { return (named[0], nil) }
        if named.count > 1 { return (nil, "\(named.count) contacts are named \"\(raw)\"; pass the identifier of one from contacts_search.") }
        return (nil, "No contact has the identifier or full name \"\(raw)\"; find it with contacts_search.")
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

    private static func firstNonEmptyString(_ values: JSONValue?...) -> String? {
        for value in values {
            if let s = value?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    /// Parses a `phones`/`emails` input that may be:
    /// - an array of strings (label defaults to "other")
    /// - an array of {label, value} objects
    /// - a single string
    private static func parseLabeledValues(_ value: JSONValue?) -> [(label: String, value: String)] {
        guard let value else { return [] }
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [("other", trimmed)]
        case .array(let items):
            return items.compactMap { item -> (label: String, value: String)? in
                switch item {
                case .string(let s):
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : ("other", trimmed)
                case .object(let dict):
                    let raw = dict["value"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !raw.isEmpty else { return nil }
                    let label = dict["label"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (label.isEmpty ? "other" : label, raw)
                default:
                    return nil
                }
            }
        default:
            return []
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
