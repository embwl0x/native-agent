import Foundation
import Contacts
import PersistenceCore

/// App-side adapter for the Contacts.framework backend behind the
/// `mac_contacts_search` and `mac_contacts_create_or_update` chat tools.
///
/// Lives in the app target (not Core / not a Module) because
/// `CNContactStore.requestAccess(for: .contacts)` requires an
/// `NSContactsUsageDescription` Info.plist entry the app bundle owns. Core /
/// ChatOrchestration can't see Contacts.framework's auth flow, so the chat
/// tool dispatcher calls into this enum app-side.
///
/// Permission denial returns the standard Mac-Integration denied envelope
/// (status/reason/integration/fix) instead of throwing — Agent renders that
/// envelope as a "grant access in System Settings" nudge.
///
/// All Contacts work runs off the main actor (CNContactStore is thread-safe
/// for reads + execute(saveRequest)).
public enum MacContactsAdapter {
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

    /// Triggers the Contacts TCC prompt if status is not_determined; otherwise
    /// returns the current status without prompting. Returns the post-request
    /// status in the same vocabulary as `currentAuthorizationStatus()`.
    public static func requestAccess() async -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        return currentAuthorizationStatus()
    }

    // MARK: - Public API

    /// Search contacts by name fragment, phone number, or email.
    /// Input keys (any one acceptable): "query" | "name" | "phone" | "email".
    /// Optional: "limit" (int, default 20, clamped 1..100).
    public static func search(input: [String: JSONValue]) async throws -> JSONValue {
        let store = CNContactStore()
        guard try await ensureAuthorized(store: store) else {
            return permissionDeniedEnvelope()
        }

        let query = firstNonEmptyString(input["query"], input["name"], input["phone"], input["email"])
            ?? ""
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = clampedInt(input["limit"], defaultValue: 20, min: 1, max: 100)

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]

        // gpt-5.5 review NEEDS_FIX: wrap real CNContactStore throws in a
        // `failed` envelope so callers get the same shape they do from the
        // AppleScript path (status: completed | denied | failed) instead of a
        // raw NSError bubbling through.
        do {
            var matches: [CNContact] = []
            // 0) One exact card by its identifier (a workspace contacts.N).
            // A saved card that no longer resolves is gone: never another
            // person who happens to share its name.
            if let id = stringValue(input["identifier"]), !id.isEmpty {
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
                    : "No contact matches \"\(trimmed)\"; try part of the name, a phone number, or an email.")
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
        guard try await ensureAuthorized(store: store) else {
            return permissionDeniedEnvelope()
        }

        let givenName = stringValue(input["given_name"] ?? input["givenName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let familyName = stringValue(input["family_name"] ?? input["familyName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let identifier = stringValue(input["identifier"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An update by identifier needs no name; a new contact does.
        guard !givenName.isEmpty || !familyName.isEmpty || !identifier.isEmpty else {
            // gpt-5.5 review NEEDS_FIX: return failed envelope, don't throw raw.
            return failedEnvelope(reason: "Give given_name or family_name for a new contact, or identifier (from contacts_search) to update one.")
        }

        let organization = stringValue(input["organization"] ?? input["organizationName"])?
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

        // gpt-5.5 review NEEDS_FIX: wrap the rest of the body so CNContactStore
        // throws turn into a `failed` envelope, matching the AppleScript path.
        do {
        // 2026-09-24: no identifier but exactly one contact already has this
        // full name ("add a number to Mom") updates it instead of making a twin.
        let sameName = identifier.isEmpty
            ? try exactNameMatches(store: store, name: [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " "), keys: writeKeys)
            : []
        var target = sameName.count == 1 ? sameName[0].identifier : ""
        if !identifier.isEmpty {
            let resolved = try resolveContact(store: store, identifier, keys: writeKeys)
            guard let id = resolved.id else { return failedEnvelope(reason: resolved.problem ?? "No such contact.") }
            target = id
        }
        if !target.isEmpty {
            // UPDATE path: fetch the existing record so the save request mutates
            // it in place (a fresh CNMutableContact would clobber other fields).
            let existing = try store.unifiedContact(withIdentifier: target, keysToFetch: writeKeys)
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
        // Phones and emails are added to what the card already has, never a
        // replacement that silently drops the others (2026-09-24).
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
    /// search result). Phase 3 — gated on contacts/.write. Required: "identifier".
    /// Returns: {status, action: "deleted", identifier}.
    public static func delete(input: [String: JSONValue]) async throws -> JSONValue {
        let store = CNContactStore()
        guard try await ensureAuthorized(store: store) else {
            return permissionDeniedEnvelope()
        }
        guard let identifier = stringValue(input["identifier"])?
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
            guard let id = resolved.id else { return failedEnvelope(reason: resolved.problem ?? "No such contact.") }
            let existing = try store.unifiedContact(withIdentifier: id, keysToFetch: writeKeys)
            guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                return failedEnvelope(reason: "Failed to obtain mutable copy")
            }
            let req = CNSaveRequest()
            req.delete(mutable)
            try store.execute(req)
            return .object([
                "status": .string("completed"),
                "action": .string("deleted"),
                "identifier": .string(id),
                "name": .string([existing.givenName, existing.familyName].filter { !$0.isEmpty }.joined(separator: " ")),
            ])
        } catch {
            return failedEnvelope(reason: error.localizedDescription)
        }
    }

    // MARK: - Names for handles (Messages)

    private static let nameCache = NSLock()
    nonisolated(unsafe) private static var namesByHandle: (built: Date, map: [String: String])?

    /// A phone's last ten digits or a lowercased email: how a Messages handle
    /// and a card's number meet whatever their formatting.
    private static func handleKey(_ raw: String) -> String {
        if raw.contains("@") { return raw.lowercased().trimmingCharacters(in: .whitespaces) }
        let digits = raw.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// Handle → contact name, from one pass over Contacts kept ten minutes.
    /// Only when Contacts access is already granted: this never asks.
    static func contactNames() -> [String: String] {
        nameCache.lock(); defer { nameCache.unlock() }
        if let cached = namesByHandle, Date().timeIntervalSince(cached.built) < 600 { return cached.map }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status.rawValue == 4 else { return [:] }
        var map: [String: String] = [:]
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let shown = name.isEmpty ? contact.organizationName : name
            guard !shown.isEmpty else { return }
            for phone in contact.phoneNumbers { let key = handleKey(phone.value.stringValue); if key.count >= 7 { map[key] = map[key] ?? shown } }
            for email in contact.emailAddresses { map[handleKey(email.value as String)] = map[handleKey(email.value as String)] ?? shown }
        }
        namesByHandle = (Date(), map)
        return map
    }

    /// A Messages read with people named: participants' `name` becomes the
    /// card's name, and each message gets `sender_name`. Handles are untouched.
    static func naming(_ result: [String: JSONValue]) -> [String: JSONValue] {
        let names = contactNames()
        guard !names.isEmpty else { return result }
        func name(_ handle: JSONValue?) -> String? {
            guard case .string(let raw)? = handle else { return nil }
            let key = handleKey(raw)
            return key.isEmpty ? nil : names[key]
        }
        var out = result
        if case .array(let threads)? = result["threads"] {
            out["threads"] = .array(threads.map { thread in
                guard case .object(var row) = thread, case .array(let people)? = row["participants"] else { return thread }
                row["participants"] = .array(people.map { person in
                    guard case .object(var p) = person, let found = name(p["handle"]) else { return person }
                    p["name"] = .string(found)
                    return .object(p)
                })
                return .object(row)
            })
        }
        if case .array(let messages)? = result["messages"] {
            out["messages"] = .array(messages.map { message in
                guard case .object(var row) = message, let found = name(row["sender"]) else { return message }
                row["sender_name"] = .string(found)
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

    /// A CNContact identifier, or a name only one contact has (2026-09-24:
    /// "Mom" is what she has in hand when she asks).
    private static func resolveContact(store: CNContactStore, _ raw: String, keys: [CNKeyDescriptor]) throws -> (id: String?, problem: String?) {
        if let found = try? store.unifiedContact(withIdentifier: raw, keysToFetch: keys) { return (found.identifier, nil) }
        // An identifier that no longer resolves means the card is gone; only
        // a plain name ("Mom") is looked up by name.
        if raw.contains(":AB") || raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil {
            return (nil, "That contact card is gone (deleted or merged); nothing changed. Search again with contacts_search.")
        }
        let named = try exactNameMatches(store: store, name: raw, keys: keys)
        if named.count == 1 { return (named[0].identifier, nil) }
        if named.count > 1 { return (nil, "\(named.count) contacts are named \"\(raw)\"; pass the identifier of one from contacts_search.") }
        return (nil, "No contact has the identifier or full name \"\(raw)\"; find it with contacts_search.")
    }

    // MARK: - Authorization

    private static func ensureAuthorized(store: CNContactStore) async throws -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        // gpt-5.5 review NEEDS_FIX: `.limited` was added in macOS 15.
        // The app target is macOS 14 so referencing the symbol breaks the
        // build. Compare via rawValue (CNAuthorizationStatus.limited.rawValue
        // == 4) so we still accept limited-access users on macOS 15+ without
        // referencing the unavailable symbol on the 14 target.
        if status.rawValue == 4 {
            return true
        }
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func permissionDeniedEnvelope() -> JSONValue {
        .object([
            "status": .string("denied"),
            "reason": .string("os_permission_denied"),
            "integration": .string("contacts"),
            "fix": .string(
                "Grant NativeAgent access to Contacts in System Settings → Privacy & Security → Contacts."
            ),
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

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    private static func firstNonEmptyString(_ values: JSONValue?...) -> String? {
        for value in values {
            if let s = stringValue(value), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func clampedInt(_ value: JSONValue?, defaultValue: Int, min minValue: Int, max maxValue: Int) -> Int {
        guard let value else { return defaultValue }
        let raw: Int
        switch value {
        case .int(let i):
            raw = Int(i)
        case .double(let d):
            raw = Int(exactly: d.rounded(.towardZero)) ?? defaultValue
        case .string(let s):
            raw = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        default:
            return defaultValue
        }
        return min(max(raw, minValue), maxValue)
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
                    let raw = stringValue(dict["value"])?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !raw.isEmpty else { return nil }
                    let label = stringValue(dict["label"])?
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
