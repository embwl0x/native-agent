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
            // 1) Name-fragment lookup ("the user", "Example User", etc.).
            if !trimmed.isEmpty {
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
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(serialized.count)),
                "contacts": .array(serialized),
            ])
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

        guard !givenName.isEmpty || !familyName.isEmpty else {
            // gpt-5.5 review NEEDS_FIX: return failed envelope, don't throw raw.
            return failedEnvelope(reason: "contacts_create_or_update requires given_name or family_name")
        }

        let organization = stringValue(input["organization"] ?? input["organizationName"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phones = parseLabeledValues(input["phones"])
        let emails = parseLabeledValues(input["emails"])
        let identifier = stringValue(input["identifier"])?
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

        // gpt-5.5 review NEEDS_FIX: wrap the rest of the body so CNContactStore
        // throws turn into a `failed` envelope, matching the AppleScript path.
        do {
        if !identifier.isEmpty {
            // UPDATE path: fetch the existing record so the save request mutates
            // it in place (a fresh CNMutableContact would clobber other fields).
            let existing = try store.unifiedContact(withIdentifier: identifier, keysToFetch: writeKeys)
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
        if !phones.isEmpty {
            mutable.phoneNumbers = phones.map { entry in
                CNLabeledValue(
                    label: contactLabel(forPhone: entry.label),
                    value: CNPhoneNumber(stringValue: entry.value)
                )
            }
        }
        if !emails.isEmpty {
            mutable.emailAddresses = emails.map { entry in
                CNLabeledValue(
                    label: contactLabel(forEmail: entry.label),
                    value: entry.value as NSString
                )
            }
        }

        let saveRequest = CNSaveRequest()
        if action == "updated" {
            saveRequest.update(mutable)
        } else {
            saveRequest.add(mutable, toContainerWithIdentifier: nil)
        }
        try store.execute(saveRequest)

        return .object([
            "status": .string("completed"),
            "identifier": .string(mutable.identifier),
            "action": .string(action),
        ])
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
            return failedEnvelope(reason: "contacts_delete requires identifier")
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
                "identifier": .string(identifier),
            ])
        } catch {
            return failedEnvelope(reason: error.localizedDescription)
        }
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
            raw = Int(d)
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
