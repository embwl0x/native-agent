import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
import ProviderRouting
import DeskCore
import NativeAgentShared
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MacNerves
import SenseCore
// Blueprint: | `PersonalAppActions+PersonalApps.swift` | personalApps action contracts and execution |

enum PersonalAppActions {}

protocol PersonalIntegrationArgs: DoorArgs {
    var wire: [String: JSONValue] { get }
}

extension PersonalIntegrationArgs {
    static func run(_ context: ActionContext, _ args: Self) async throws -> JSONValue {
        try await context.client.dispatchMacIntegrationTool(context: context, args: args)
    }
}

struct EmptyPersonalIntegrationArgs: PersonalIntegrationArgs {
    static let doorFields: [DoorFieldDescriptor] = []
    var wire: [String: JSONValue] { [:] }
    init(door: inout DoorObjectDecoder) {}
}

private protocol PersonalContactsArgs: PersonalIntegrationArgs {
    static var parameters: JSONValue { get }
}

extension PersonalContactsArgs {
    fileprivate static func field(_ name: String, required: Bool = false) -> DoorFieldDescriptor {
        let properties = parameters.objectValue!["properties"]!.objectValue!
        return DoorFieldDescriptor(name, properties[name]!, required: required)
    }

    fileprivate static var rootSchemaConstraints: [String: JSONValue] {
        parameters.objectValue!.filter { !["type", "properties", "required"].contains($0.key) }
    }
}

private struct ContactLabeledEntry: DoorObjectSchema {
    private static let properties = MacContactsExecutor.saveParameters.objectValue!["properties"]!.objectValue!["phones"]!
        .objectValue!["items"]!.objectValue!["properties"]!.objectValue!
    static let labelField = DoorFieldDescriptor("label", properties["label"]!, required: true)
    static let valueField = DoorFieldDescriptor("value", properties["value"]!, required: true)
    static let doorFields = NonEmptyFields(labelField, valueField)
    let label: String
    let value: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        label = try door.requiredString(Self.labelField)
        value = try door.requiredString(Self.valueField)
    }

    var wire: JSONValue {
        .object([Self.labelField.name: .string(label), Self.valueField.name: .string(value)])
    }
}

private struct MacCalendarFreeBusyArgs: PersonalIntegrationArgs {
    static let calendarIDsField = DoorFieldDescriptor("calendar_ids", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.strSchema()), ("minItems", .int(1)), ("maxItems",
        .int(50)), ("description", .string("Optional; omit to check every calendar."))]), required: false)
    static let startField = DoorFieldDescriptor("start", ActionDescriptor.stringOrIntSchema("Window start: ISO-8601 or epoch seconds."), required: true)
    static let endField = DoorFieldDescriptor("end", ActionDescriptor.stringOrIntSchema("Window end after start: ISO-8601 or epoch seconds."), required: true)
    static let doorFields = [calendarIDsField, startField, endField]
    let calendarIDs: [String]?
    let start: DoorStringOrInteger
    let end: DoorStringOrInteger

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        calendarIDs = try door.strings(Self.calendarIDsField)
        start = try door.requiredStringOrInteger(Self.startField)
        end = try door.requiredStringOrInteger(Self.endField)
    }

    var wire: [String: JSONValue] {
        [
            Self.calendarIDsField.name: calendarIDs.map { .array($0.map(JSONValue.string)) },
            Self.startField.name: start.wire,
            Self.endField.name: end.wire,
        ].compactMapValues { $0 }
    }
}

private struct MacCalendarListUpcomingArgs: PersonalIntegrationArgs {
    static let dayField = DoorFieldDescriptor.string("day", "Optional local-day scope: 'today', 'tomorrow', or 'YYYY-MM-DD'.")
    static let rangeField = DoorFieldDescriptor.string("range", """
        Natural local range: today, tomorrow, this week, next week, or next N days (1–30). Takes precedence over day and \
        hours_ahead; this week runs from now to the end of the local calendar week; next week is the whole following calendar \
        week.
        """)
    static let hoursAheadField = DoorFieldDescriptor("hours_ahead", ToolSchema.intSchema("Lookahead window in hours (1-720, default 24)."), required: false)
    static let daysField = DoorFieldDescriptor("days", ToolSchema.intSchema("Optional: the next N days (1–30), same as range 'next N days'."), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Maximum events to return (1-100, default 20)."), required: false)
    static let calendarNameField = DoorFieldDescriptor.string("calendar_name", "Optional filter — return events only from this calendar.")
    static let calendarIDField = DoorFieldDescriptor.string("calendar_id", "Optional exact EventKit calendar ID from calendar.calendars.")
    static let doorFields = [dayField, rangeField, hoursAheadField, daysField, limitField, calendarNameField, calendarIDField]
    let day: String?
    let range: String?
    let hoursAhead: DoorNumberLiteral?
    let days: DoorNumberLiteral?
    let limit: DoorNumberLiteral?
    let calendarName: String?
    let calendarID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        day = try door.string(Self.dayField)
        range = try door.string(Self.rangeField)
        hoursAhead = try door.numberLiteral(Self.hoursAheadField)
        days = try door.numberLiteral(Self.daysField)
        limit = try door.numberLiteral(Self.limitField)
        calendarName = try door.string(Self.calendarNameField)
        calendarID = try door.string(Self.calendarIDField)
    }

    var wire: [String: JSONValue] {
        [
            Self.dayField.name: day.map(JSONValue.string),
            Self.rangeField.name: range.map(JSONValue.string),
            Self.hoursAheadField.name: hoursAhead?.wire,
            Self.daysField.name: days?.wire,
            Self.limitField.name: limit?.wire,
            Self.calendarNameField.name: calendarName.map(JSONValue.string),
            Self.calendarIDField.name: calendarID.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacRemindersQueryArgs: PersonalIntegrationArgs {
    static let queryField = DoorFieldDescriptor.string("query", "Optional text to find in titles or notes (case insensitive).")
    static let listNameField = DoorFieldDescriptor.string("list_name", "Optional list-name filter (case insensitive contains).")
    static let dueStartField = DoorFieldDescriptor("due_start", ActionDescriptor.stringOrIntSchema("Inclusive due-range start: ISO-8601, local YYYY-MM-DD, or epoch seconds."), required: false)
    static let dueEndField = DoorFieldDescriptor("due_end", ActionDescriptor.stringOrIntSchema("Exclusive due-range end; undated tasks are excluded from date ranges."), required: false)
    static let splitDueAtField = DoorFieldDescriptor("split_due_at", ActionDescriptor.stringOrIntSchema("""
        Optional due-date boundary. Adds before and on_or_after pages from the same snapshot, each with its own total and \
        next_offset using the requested offset/limit; undated tasks are excluded from these parts.
        """), required: false)
    static let undatedOnlyField = DoorFieldDescriptor("undated_only", ToolSchema.boolSchema("Return only tasks with no due date; cannot be combined with a due range or split_due_at."), required: false)
    static let includeCompletedField = DoorFieldDescriptor("include_completed", ToolSchema.boolSchema("Include completed reminders (default false)."), required: false)
    static let sortField = DoorFieldDescriptor.string("sort", "due (default: soonest due first, undated last) or changed (most recently made or edited first).")
    static let offsetField = DoorFieldDescriptor("offset", ToolSchema.intSchema("Result offset (default 0); use next_offset from the preceding page."), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("""
        Maximum reminders per page from one native snapshot, independently for split parts (1-200, default 20).
        """), required: false)
    static let doorFields = [
        queryField, listNameField, dueStartField, dueEndField, splitDueAtField, undatedOnlyField,
        includeCompletedField, sortField, offsetField, limitField
    ]
    let query: String?
    let listName: String?
    let dueStart: DoorStringOrInteger?
    let dueEnd: DoorStringOrInteger?
    let splitDueAt: DoorStringOrInteger?
    let undatedOnly: Bool?
    let includeCompleted: Bool?
    let sort: String?
    let offset: DoorNumberLiteral?
    let limit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        listName = try door.string(Self.listNameField)
        dueStart = try door.stringOrInteger(Self.dueStartField)
        dueEnd = try door.stringOrInteger(Self.dueEndField)
        splitDueAt = try door.stringOrInteger(Self.splitDueAtField)
        undatedOnly = try door.bool(Self.undatedOnlyField)
        includeCompleted = try door.bool(Self.includeCompletedField)
        sort = try door.string(Self.sortField)
        offset = try door.numberLiteral(Self.offsetField)
        limit = try door.numberLiteral(Self.limitField)
    }

    var wire: [String: JSONValue] {
        [
            Self.queryField.name: query.map(JSONValue.string),
            Self.listNameField.name: listName.map(JSONValue.string),
            Self.dueStartField.name: dueStart?.wire,
            Self.dueEndField.name: dueEnd?.wire,
            Self.splitDueAtField.name: splitDueAt?.wire,
            Self.undatedOnlyField.name: undatedOnly.map(JSONValue.bool),
            Self.includeCompletedField.name: includeCompleted.map(JSONValue.bool),
            Self.sortField.name: sort.map(JSONValue.string),
            Self.offsetField.name: offset?.wire,
            Self.limitField.name: limit?.wire,
        ].compactMapValues { $0 }
    }
}

private struct MacRemindersReadArgs: PersonalIntegrationArgs {
    static let idField = DoorFieldDescriptor.string("id", "Exact reminder id from a reminder query, read or creation.", required: true)
    static let doorFields = [idField]
    let id: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
    }

    var wire: [String: JSONValue] {
        [
            Self.idField.name: .string(id),
        ]
    }
}

private struct MacRemindersListDueTodayArgs: PersonalIntegrationArgs {
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("""
        Maximum reminders per part, independently (1-200, default 50). Counts and total include unreturned reminders.
        """), required: false)
    static let doorFields = [limitField]
    let limit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        limit = try door.numberLiteral(Self.limitField)
    }

    var wire: [String: JSONValue] {
        [
            Self.limitField.name: limit?.wire,
        ].compactMapValues { $0 }
    }
}

private struct MacNotifyArgs: PersonalIntegrationArgs {
    static let titleField = DoorFieldDescriptor.string("title", "Optional short notification title; omit and it is your name.")
    static let messageField = DoorFieldDescriptor.string("message", "Notification body text (required).", required: true)
    static let subtitleField = DoorFieldDescriptor.string("subtitle", "Optional subtitle shown between title and body.")
    static let doorFields = [titleField, messageField, subtitleField]
    let title: String?
    let message: String
    let subtitle: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.string(Self.titleField)
        message = try door.requiredString(Self.messageField)
        subtitle = try door.string(Self.subtitleField)
    }

    var wire: [String: JSONValue] {
        [
            Self.titleField.name: title.map(JSONValue.string),
            Self.messageField.name: .string(message),
            Self.subtitleField.name: subtitle.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct PhoneRequestArgs: PersonalIntegrationArgs {
    static let kindField = DoorFieldDescriptor("kind", ToolSchema.enumStringSchema(["location.current", "photo.pick", "photo.capture"], "What to ask for."), required: true)
    static let paramsField = DoorFieldDescriptor.emptyObject("params", description: "Leave empty.")
    static let waitSecondsField = DoorFieldDescriptor("wait_seconds", ToolSchema.intSchema("Seconds to wait (1–120; default 60).", minimum: 1, maximum: 120), required: false)
    static let doorFields = [kindField, paramsField, waitSecondsField]
    let kind: String
    let params: [String: JSONValue]?
    let waitSeconds: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        kind = try door.requiredString(Self.kindField)
        params = try door.objectValue(Self.paramsField)
        waitSeconds = try door.numberLiteral(Self.waitSecondsField)
    }

    var wire: [String: JSONValue] {
        [
            Self.kindField.name: .string(kind),
            Self.paramsField.name: params.map(JSONValue.object),
            Self.waitSecondsField.name: waitSeconds?.wire,
        ].compactMapValues { $0 }
    }
}

private struct MobileNotifyArgs: PersonalIntegrationArgs {
    static let titleField = DoorFieldDescriptor.string("title", "Optional short notification title; omit and it is your name.")
    static let messageField = DoorFieldDescriptor.string("message", "Notification body text (required).", required: true)
    static let subtitleField = DoorFieldDescriptor.string("subtitle", "Optional subtitle.")
    static let sourceField = DoorFieldDescriptor.string("source", "Optional source tag for tracking (e.g. 'calendar_reminder').")
    static let doorFields = [titleField, messageField, subtitleField, sourceField]
    let title: String?
    let message: String
    let subtitle: String?
    let source: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.string(Self.titleField)
        message = try door.requiredString(Self.messageField)
        subtitle = try door.string(Self.subtitleField)
        source = try door.string(Self.sourceField)
    }

    var wire: [String: JSONValue] {
        [
            Self.titleField.name: title.map(JSONValue.string),
            Self.messageField.name: .string(message),
            Self.subtitleField.name: subtitle.map(JSONValue.string),
            Self.sourceField.name: source.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacSpotlightSearchArgs: PersonalIntegrationArgs {
    static let queryField = DoorFieldDescriptor.string("query", """
        Spotlight words or predicate. Exact filename: kMDItemFSName == \"hello.txt\". Alias 'q' is also accepted.
        """)
    static let qField = DoorFieldDescriptor.string("q", "Alias for 'query'.")
    static let nameField = DoorFieldDescriptor.string("name", "Filename contains this text, case-insensitive (files named …); use instead of query.")
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Maximum paths (1-200, default 10)."), required: false)
    static let doorFields = [queryField, qField, nameField, limitField]
    let query: String?
    let q: String?
    let name: String?
    let limit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.string(Self.queryField)
        q = try door.string(Self.qField)
        name = try door.string(Self.nameField)
        limit = try door.numberLiteral(Self.limitField)
    }

    var wire: [String: JSONValue] {
        [
            Self.queryField.name: query.map(JSONValue.string),
            Self.qField.name: q.map(JSONValue.string),
            Self.nameField.name: name.map(JSONValue.string),
            Self.limitField.name: limit?.wire,
        ].compactMapValues { $0 }
    }
}

private struct ContactsSearchArgs: PersonalContactsArgs {
    static let parameters = MacContactsExecutor.searchParameters
    static let rootRequired: [String]? = nil
    static let identifierField = field("identifier")
    static let nameField = field("name")
    static let phoneField = field("phone")
    static let emailField = field("email")
    static let queryField = field("query")
    static let limitField = field("limit")
    static let doorFields = [identifierField, nameField, phoneField, emailField, queryField, limitField]
    let identifier: String?
    let name: String?
    let phone: String?
    let email: String?
    let query: String?
    let limit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        identifier = try door.string(Self.identifierField)
        name = try door.string(Self.nameField)
        phone = try door.string(Self.phoneField)
        email = try door.string(Self.emailField)
        query = try door.string(Self.queryField)
        limit = try door.numberLiteral(Self.limitField)
        guard identifier != nil || name != nil || phone != nil || email != nil || query != nil else {
            throw DoorDecodeError(path: door.path, accepted: "an object containing one of identifier, name, phone, email, query")
        }
    }

    var wire: [String: JSONValue] {
        [
            Self.identifierField.name: identifier.map(JSONValue.string),
            Self.nameField.name: name.map(JSONValue.string),
            Self.phoneField.name: phone.map(JSONValue.string),
            Self.emailField.name: email.map(JSONValue.string),
            Self.queryField.name: query.map(JSONValue.string),
            Self.limitField.name: limit?.wire,
        ].compactMapValues { $0 }
    }
}

private struct ContactsCreateOrUpdateArgs: PersonalContactsArgs {
    static let parameters = MacContactsExecutor.saveParameters
    static let rootRequired: [String]? = nil
    static let identifierField = field("identifier")
    static let givenNameField = field("given_name")
    static let familyNameField = field("family_name")
    static let organizationField = field("organization")
    static let phonesField = field("phones")
    static let emailsField = field("emails")
    static let doorFields = [identifierField, givenNameField, familyNameField, organizationField, phonesField, emailsField]
    let identifier: String?
    let givenName: String?
    let familyName: String?
    let organization: String?
    let phones: [ContactLabeledEntry]?
    let emails: [ContactLabeledEntry]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        identifier = try door.string(Self.identifierField)
        givenName = try door.string(Self.givenNameField)
        familyName = try door.string(Self.familyNameField)
        organization = try door.string(Self.organizationField)
        phones = try door.objects(Self.phonesField, as: ContactLabeledEntry.self)
        emails = try door.objects(Self.emailsField, as: ContactLabeledEntry.self)
        guard identifier != nil || givenName != nil || familyName != nil else {
            throw DoorDecodeError(path: door.path, accepted: "an object containing one of identifier, given_name, family_name")
        }
    }

    var wire: [String: JSONValue] {
        [
            Self.identifierField.name: identifier.map(JSONValue.string),
            Self.givenNameField.name: givenName.map(JSONValue.string),
            Self.familyNameField.name: familyName.map(JSONValue.string),
            Self.organizationField.name: organization.map(JSONValue.string),
            Self.phonesField.name: phones.map { .array($0.map(\.wire)) },
            Self.emailsField.name: emails.map { .array($0.map(\.wire)) },
        ].compactMapValues { $0 }
    }
}

private struct MailSaveAttachmentArgs: PersonalIntegrationArgs {
    static let nameField = DoorFieldDescriptor.string("name", "Observed mail.N workspace name; use instead of exact locator fields.")
    static let scopeField = DoorFieldDescriptor("scope", ToolSchema.enumStringSchema(["inbox", "sent"], "Mailbox scope from the same row; default inbox."), required: false)
    static let indexField = DoorFieldDescriptor("index", ToolSchema.intSchema("1-based attachment index from the Mail read; index or filename is required.", minimum: 1), required: false)
    static let filenameField = DoorFieldDescriptor.string("filename", "Exact unique attachment filename; index disambiguates duplicate names.")
    static let destinationField = DoorFieldDescriptor.string("destination", "Destination folder; default ~/Downloads.")
    static let messageIDField = DoorFieldDescriptor("message_id", ToolSchema.intSchema("Exact positive message ID from the Mail read.", minimum: 1), required: false)
    static let expectedMessageIDField = DoorFieldDescriptor.string("expected_message_id", "Exact RFC message identifier paired with message_id.")
    static let expectedAccountField = DoorFieldDescriptor.string("expected_account", "expected_account from the same row, when present.")
    static let positionField = DoorFieldDescriptor("position", ToolSchema.intSchema("position from the same row, when present.", minimum: 1), required: false)
    static let expectedAccountIDField = DoorFieldDescriptor.string("expected_account_id", "expected_account_id from the same row.")
    static let doorFields = [
        nameField, scopeField, indexField, filenameField, destinationField, messageIDField,
        expectedMessageIDField, expectedAccountField, positionField, expectedAccountIDField
    ]
    let name: String?
    let scope: String?
    let index: DoorNumberLiteral?
    let filename: String?
    let destination: String?
    let messageID: DoorNumberLiteral?
    let expectedMessageID: String?
    let expectedAccount: String?
    let position: DoorNumberLiteral?
    let expectedAccountID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        name = try door.string(Self.nameField)
        scope = try door.string(Self.scopeField)
        index = try door.numberLiteral(Self.indexField)
        filename = try door.string(Self.filenameField)
        destination = try door.string(Self.destinationField)
        messageID = try door.numberLiteral(Self.messageIDField)
        expectedMessageID = try door.string(Self.expectedMessageIDField)
        expectedAccount = try door.string(Self.expectedAccountField)
        position = try door.numberLiteral(Self.positionField)
        expectedAccountID = try door.string(Self.expectedAccountIDField)
    }

    var wire: [String: JSONValue] {
        [
            Self.nameField.name: name.map(JSONValue.string),
            Self.scopeField.name: scope.map(JSONValue.string),
            Self.indexField.name: index?.wire,
            Self.filenameField.name: filename.map(JSONValue.string),
            Self.destinationField.name: destination.map(JSONValue.string),
            Self.messageIDField.name: messageID?.wire,
            Self.expectedMessageIDField.name: expectedMessageID.map(JSONValue.string),
            Self.expectedAccountField.name: expectedAccount.map(JSONValue.string),
            Self.positionField.name: position?.wire,
            Self.expectedAccountIDField.name: expectedAccountID.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacCalendarCreateEventArgs: PersonalIntegrationArgs {
    static let titleField = DoorFieldDescriptor.string("title", "Event title (required).", required: true)
    static let startField = DoorFieldDescriptor("start", ActionDescriptor.stringOrIntSchema("Start time — ISO-8601 string (e.g. '2026-06-07T15:00:00Z') or integer epoch seconds (required)."), required: true)
    static let endField = DoorFieldDescriptor("end", ActionDescriptor.stringOrIntSchema("Optional end time — ISO-8601 string or integer epoch seconds. Defaults to start + 1 hour."), required: false)
    static let notesField = DoorFieldDescriptor.string("notes", "Optional notes / description.")
    static let locationField = DoorFieldDescriptor.string("location", "Optional location string.")
    static let calendarNameField = DoorFieldDescriptor.string("calendar_name", "Unique exact calendar name, only when calendar_id is omitted; ambiguous names fail.")
    static let calendarIDField = DoorFieldDescriptor.string("calendar_id", """
        Explicit EventKit calendar ID from calendar.calendars. Required with full access unless a unique exact calendar_name is \
        supplied. With write-only access, omit calendar_id and calendar_name to use the system default.
        """)
    static let doorFields = [titleField, startField, endField, notesField, locationField, calendarNameField, calendarIDField]
    let title: String
    let start: DoorStringOrInteger
    let end: DoorStringOrInteger?
    let notes: String?
    let location: String?
    let calendarName: String?
    let calendarID: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.requiredString(Self.titleField)
        start = try door.requiredStringOrInteger(Self.startField)
        end = try door.stringOrInteger(Self.endField)
        notes = try door.string(Self.notesField)
        location = try door.string(Self.locationField)
        calendarName = try door.string(Self.calendarNameField)
        calendarID = try door.string(Self.calendarIDField)
    }

    var wire: [String: JSONValue] {
        [
            Self.titleField.name: .string(title),
            Self.startField.name: start.wire,
            Self.endField.name: end?.wire,
            Self.notesField.name: notes.map(JSONValue.string),
            Self.locationField.name: location.map(JSONValue.string),
            Self.calendarNameField.name: calendarName.map(JSONValue.string),
            Self.calendarIDField.name: calendarID.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacCalendarModifyEventArgs: PersonalIntegrationArgs {
    static let idField = DoorFieldDescriptor.string("id", "EKEvent identifier from calendar.upcoming (required).", required: true)
    static let expectedStartField = DoorFieldDescriptor("expected_start", ActionDescriptor.stringOrIntSchema("""
        Observed startAt from calendar.upcoming; required for recurring occurrences. ISO-8601 or epoch seconds.
        """), required: false)
    static let titleField = DoorFieldDescriptor.string("title", "New event title.")
    static let startField = DoorFieldDescriptor("start", ActionDescriptor.stringOrIntSchema("New start time — ISO-8601 string or epoch seconds."), required: false)
    static let endField = DoorFieldDescriptor("end", ActionDescriptor.stringOrIntSchema("New end time — ISO-8601 string or epoch seconds."), required: false)
    static let notesField = DoorFieldDescriptor.string("notes", "New notes/body text.")
    static let locationField = DoorFieldDescriptor.string("location", "New location.")
    static let clearFieldsField = DoorFieldDescriptor("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "location"])),
        ("description", .string("Fields to empty on the event. A field also given a value keeps that value."))]), required: false)
    static let doorFields = [idField, expectedStartField, titleField, startField, endField, notesField, locationField, clearFieldsField]
    let id: String
    let expectedStart: DoorStringOrInteger?
    let title: String?
    let start: DoorStringOrInteger?
    let end: DoorStringOrInteger?
    let notes: String?
    let location: String?
    let clearFields: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
        expectedStart = try door.stringOrInteger(Self.expectedStartField)
        title = try door.string(Self.titleField)
        start = try door.stringOrInteger(Self.startField)
        end = try door.stringOrInteger(Self.endField)
        notes = try door.string(Self.notesField)
        location = try door.string(Self.locationField)
        clearFields = try door.strings(Self.clearFieldsField)
    }

    var wire: [String: JSONValue] {
        [
            Self.idField.name: .string(id),
            Self.expectedStartField.name: expectedStart?.wire,
            Self.titleField.name: title.map(JSONValue.string),
            Self.startField.name: start?.wire,
            Self.endField.name: end?.wire,
            Self.notesField.name: notes.map(JSONValue.string),
            Self.locationField.name: location.map(JSONValue.string),
            Self.clearFieldsField.name: clearFields.map { .array($0.map(JSONValue.string)) },
        ].compactMapValues { $0 }
    }
}

private struct MacCalendarDeleteEventArgs: PersonalIntegrationArgs {
    static let idField = DoorFieldDescriptor.string("id", "Exact EKEvent identifier from calendar.upcoming.", required: true)
    static let expectedTitleField = DoorFieldDescriptor.string("expected_title", "Exact title observed for this event.", required: true)
    static let expectedStartField = DoorFieldDescriptor("expected_start", ActionDescriptor.stringOrIntSchema("Observed start time, ISO-8601 or epoch seconds."), required: true)
    static let doorFields = [idField, expectedTitleField, expectedStartField]
    let id: String
    let expectedTitle: String
    let expectedStart: DoorStringOrInteger

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
        expectedTitle = try door.requiredString(Self.expectedTitleField)
        expectedStart = try door.requiredStringOrInteger(Self.expectedStartField)
    }

    var wire: [String: JSONValue] {
        [
            Self.idField.name: .string(id),
            Self.expectedTitleField.name: .string(expectedTitle),
            Self.expectedStartField.name: expectedStart.wire,
        ]
    }
}

private struct MacRemindersCreateArgs: PersonalIntegrationArgs {
    static let titleField = DoorFieldDescriptor.string("title", "Reminder title (required).", required: true)
    static let notesField = DoorFieldDescriptor.string("notes", "Optional notes.")
    static let dueDateField = DoorFieldDescriptor("due_date", ActionDescriptor.stringOrIntSchema("Optional due date — ISO-8601 string or integer epoch seconds."), required: false)
    static let listNameField = DoorFieldDescriptor.string("list_name", "Optional list name — defaults to the default list when omitted.")
    static let doorFields = [titleField, notesField, dueDateField, listNameField]
    let title: String
    let notes: String?
    let dueDate: DoorStringOrInteger?
    let listName: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.requiredString(Self.titleField)
        notes = try door.string(Self.notesField)
        dueDate = try door.stringOrInteger(Self.dueDateField)
        listName = try door.string(Self.listNameField)
    }

    var wire: [String: JSONValue] {
        [
            Self.titleField.name: .string(title),
            Self.notesField.name: notes.map(JSONValue.string),
            Self.dueDateField.name: dueDate?.wire,
            Self.listNameField.name: listName.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacRemindersListRenameArgs: PersonalIntegrationArgs {
    static let listField = DoorFieldDescriptor.string("list", "Exact existing Reminders list name.", required: true)
    static let newNameField = DoorFieldDescriptor.string("new_name", "New nonempty, unique list name.", required: true)
    static let doorFields = [listField, newNameField]
    let list: String
    let newName: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        list = try door.requiredString(Self.listField)
        newName = try door.requiredString(Self.newNameField)
    }

    var wire: [String: JSONValue] {
        [
            Self.listField.name: .string(list),
            Self.newNameField.name: .string(newName),
        ]
    }
}

private struct MacRemindersListCreateArgs: PersonalIntegrationArgs {
    static let nameField = DoorFieldDescriptor.string("name", "Nonempty, unique name for the new Reminders list.", required: true)
    static let doorFields = [nameField]
    let name: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        name = try door.requiredString(Self.nameField)
    }

    var wire: [String: JSONValue] {
        [
            Self.nameField.name: .string(name),
        ]
    }
}

private struct MacRemindersUpdateArgs: PersonalIntegrationArgs {
    static let idField = DoorFieldDescriptor.string("id", "Exact reminder id from a reminder query, read or creation.", required: true)
    static let titleField = DoorFieldDescriptor.string("title", "New nonempty title; omitted leaves it unchanged.")
    static let notesField = DoorFieldDescriptor.string("notes", "New notes; omitted leaves them unchanged. Use clear_fields to remove them.")
    static let dueDateField = DoorFieldDescriptor("due_date", ActionDescriptor.stringOrIntSchema("""
        New due date: ISO-8601, local YYYY-MM-DD, or epoch seconds; omitted leaves it unchanged. Use clear_fields to remove it.
        """), required: false)
    static let clearFieldsField = DoorFieldDescriptor("clear_fields", ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.enumStringSchema(["notes", "due_date"])),
        ("description", .string("Fields to clear: notes or due_date. Do not also supply a value for a cleared field."))]), required: false)
    static let doorFields = [idField, titleField, notesField, dueDateField, clearFieldsField]
    let id: String
    let title: String?
    let notes: String?
    let dueDate: DoorStringOrInteger?
    let clearFields: [String]?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
        title = try door.string(Self.titleField)
        notes = try door.string(Self.notesField)
        dueDate = try door.stringOrInteger(Self.dueDateField)
        clearFields = try door.strings(Self.clearFieldsField)
    }

    var wire: [String: JSONValue] {
        [
            Self.idField.name: .string(id),
            Self.titleField.name: title.map(JSONValue.string),
            Self.notesField.name: notes.map(JSONValue.string),
            Self.dueDateField.name: dueDate?.wire,
            Self.clearFieldsField.name: clearFields.map { .array($0.map(JSONValue.string)) },
        ].compactMapValues { $0 }
    }
}

private struct MacRemindersCompleteArgs: PersonalIntegrationArgs {
    static let titleField = DoorFieldDescriptor.string("title", "The reminder's exact title (case aside).")
    static let idField = DoorFieldDescriptor.string("id", "Reminder id from reminders.due_today, when known.")
    static let doorFields = [titleField, idField]
    let title: String?
    let id: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        title = try door.string(Self.titleField)
        id = try door.string(Self.idField)
    }

    var wire: [String: JSONValue] {
        [
            Self.titleField.name: title.map(JSONValue.string),
            Self.idField.name: id.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

private struct MacRemindersDeleteArgs: PersonalIntegrationArgs {
    static let idField = DoorFieldDescriptor.string("id", "Exact reminder id from reminders.create or reminders.due_today.", required: true)
    static let expectedTitleField = DoorFieldDescriptor.string("expected_title", "Exact title observed for this reminder.", required: true)
    static let doorFields = [idField, expectedTitleField]
    let id: String
    let expectedTitle: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        id = try door.requiredString(Self.idField)
        expectedTitle = try door.requiredString(Self.expectedTitleField)
    }

    var wire: [String: JSONValue] {
        [
            Self.idField.name: .string(id),
            Self.expectedTitleField.name: .string(expectedTitle),
        ]
    }
}

private struct ContactsDeleteArgs: PersonalContactsArgs {
    static let parameters = MacContactsExecutor.deleteParameters
    static let identifierField = field("identifier", required: true)
    static let doorFields = [identifierField]
    let identifier: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        identifier = try door.requiredString(Self.identifierField)
    }

    var wire: [String: JSONValue] {
        [
            Self.identifierField.name: .string(identifier),
        ]
    }
}

extension PersonalAppActions {
    static let personalAppActions: [ActionDescriptor] = {
        let schemas: [ActionDescriptor] = [
            // MacIntegrationPermissionStore owns user-controlled READ/WRITE gates; app-side backends enforce them. PII surfaces default to read-only;
            // notification channels are outbound-only.
            ActionDescriptor(EmptyPersonalIntegrationArgs.self, name: "mac_calendar_calendars",
                run: EmptyPersonalIntegrationArgs.run, toolClass: .read, reach: .person, capabilities: [.toolCall],
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    List local EventKit calendars with stable IDs and write access. Requires Calendar Read and full EventKit access. Choose a \
                    destination explicitly by ID.
                    """
            ),
            ActionDescriptor(MacCalendarFreeBusyArgs.self, name: "mac_calendar_free_busy",
                run: MacCalendarFreeBusyArgs.run, toolClass: .read, reach: .person, capabilities: [.toolCall],
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    Check local free/busy across every calendar (or the exact EventKit calendar IDs given) over at most 31 days. Includes tentative \
                    and unavailable intervals; unsupported availability is unknown, never free. Requires Calendar Read and full EventKit access.
                    """
            ),
            ActionDescriptor(MacCalendarListUpcomingArgs.self, name: "mac_calendar_list_upcoming",
                run: MacCalendarListUpcomingArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.calendar, .read),
                description: """
                    List the user's Mac calendar events from EventKit. Read-only; requires Calendar -> Read permission. Returns event titles, \
                    start/end timestamps, calendar names, and locations. For today/tomorrow/specific-date questions, pass day ('today', 'tomorrow', \
                    or 'YYYY-MM-DD') instead of relying on a broad hours window.
                    """
            ),
            ActionDescriptor(MacRemindersQueryArgs.self, name: "mac_reminders_query",
                run: MacRemindersQueryArgs.run, toolClass: .read, reach: .person, capabilities: [.toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    Find Mac Reminders across all dates, including undated tasks. Searches titles and notes; incomplete reminders by default. \
                    Read-only; requires Reminders → Read permission. Follow next_offset with the same filters for more results.
                    """
            ),
            ActionDescriptor(EmptyPersonalIntegrationArgs.self, name: "mac_reminders_lists",
                run: EmptyPersonalIntegrationArgs.run, toolClass: .read, reach: .person, capabilities: [.toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    List every Mac Reminders list with its id, source, write access and how many reminders are still open in it. Read-only; \
                    requires Reminders → Read permission.
                    """
            ),
            ActionDescriptor(MacRemindersReadArgs.self, name: "mac_reminders_read",
                run: MacRemindersReadArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    Read exactly one Mac Reminder by id, regardless of due date or completion. Returns current title, list, due date, completion \
                    and full notes. Read-only; requires Reminders → Read permission.
                    """
            ),
            ActionDescriptor(MacRemindersListDueTodayArgs.self, name: "mac_reminders_list_due_today",
                run: MacRemindersListDueTodayArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .read),
                description: """
                    List Mac Reminders in two named parts: today (due in the local day, earliest first) and overdue (due before today, oldest \
                    first). Each has its full count, returned_count, reminders and has_more. Returns total and a summary naming both counts. \
                    Read-only; requires Reminders -> Read permission.
                    """
            ),
            ActionDescriptor(MacNotifyArgs.self, name: "mac_notify",
                run: MacNotifyArgs.run,
                toolClass: .write, capabilities: [.externalSend, .notification, .toolCall],
                macIntegration: .init(MacIntegrationID.notifyMac, .write),
                description: """
                    Post a macOS user notification on this Mac. Requires Mac Notifications -> Write permission. Use for short, actionable alerts, \
                    not as a substitute for chat.
                    """
            ),
            ActionDescriptor(PhoneRequestArgs.self, name: "phone_request",
                run: PhoneRequestArgs.run,
                toolClass: .read, capabilities: [.externalSend, .notification, .toolCall],
                macIntegration: .init(MacIntegrationID.notifyMobile, .write),
                description: """
                    Ask your paired iPhone for its current location or a photo chosen or taken by the person. Open NativeAgent on the phone to \
                    respond. Waits for a result; phone permissions apply.
                    """
            ),
            ActionDescriptor(MobileNotifyArgs.self, name: "mobile_notify",
                run: MobileNotifyArgs.run,
                toolClass: .write, capabilities: [.externalSend, .notification, .toolCall],
                macIntegration: .init(MacIntegrationID.notifyMobile, .write),
                description: """
                    Push a notification to the paired iPhone via the NativeAgent mobile bridge. Requires iPhone Notifications -> Write permission. \
                    Use sparingly; these wake the phone.
                    """
            ),
            ActionDescriptor(MacSpotlightSearchArgs.self, name: "mac_spotlight_search",
                run: MacSpotlightSearchArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.spotlight, .read),
                description: """
                    Search the Mac with Spotlight and return file paths plus modified_at and added_at dates in files (null when unavailable). Plain \
                    words can match file contents; use an exact-name predicate for a filename. Read-only; requires Spotlight -> Read permission.
                    """
            ),
            // Sensitive Mac Integration writes default off and require the user's toggle.
            ActionDescriptor(ContactsSearchArgs.self, name: "contacts_search",
                run: ContactsSearchArgs.run, toolClass: .read, reach: .person,
                macIntegration: .init(MacIntegrationID.contacts, .read),
                description: """
                    Search local Mac Contacts once by identifier, name, phone or email. Supply at least one search field; query selects email for \
                    @, phone for phone-shaped text, otherwise name. Returns matching records and the selected lookup. Read-only; requires Contacts \
                    -> Read permission.
                    """
            ),
            ActionDescriptor(ContactsCreateOrUpdateArgs.self, name: "contacts_create_or_update",
                run: ContactsCreateOrUpdateArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.contacts, .write),
                description: """
                    Create a Mac contact, or update one: by identifier, or the single existing contact with the same full name. Phones and emails \
                    are added, never replaced. Requires Contacts -> Write permission.
                    """
            ),
            ActionDescriptor(MailSaveAttachmentArgs.self, name: "mail_save_attachment",
                run: MailSaveAttachmentArgs.run,
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.mail, .read),
                description: """
                    Save one local Apple Mail attachment by index or unique filename using an observed mail.N name or paired message identity from \
                    a Mail read. Defaults to ~/Downloads; destination is a folder within the same writable roots as files.write in the current \
                    mode. Never overwrites: adds a numbered suffix. Returns path and size in bytes. Requires Mail Read access; no Mail UI or \
                    AppleScript is used.
                    """
            ),
            // Sensitive writes default off; scheduler.write defaults on with no read axis.
            ActionDescriptor(MacCalendarCreateEventArgs.self, name: "mac_calendar_create_event",
                run: MacCalendarCreateEventArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.calendar, .write), makes: "eventId",
                description: """
                    Create a local Calendar entry via EventKit; this does not send invitations. With full access, choose an explicit destination; \
                    with write-only access, omit calendar_id and calendar_name to use the system default. Requires Calendar Write permission. \
                    start/end accept ISO-8601 or epoch seconds.
                    """
            ),
            ActionDescriptor(MacCalendarModifyEventArgs.self, name: "mac_calendar_modify_event",
                run: MacCalendarModifyEventArgs.run, toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.calendar, .write),
                description: """
                    Modify one calendar event occurrence. Requires id from calendar.upcoming; recurring events also require its startAt as \
                    expected_start. A moved occurrence is refused. Pass only the fields to change. Requires \
                    Calendar → Write permission.
                    """
            ),
            ActionDescriptor(MacCalendarDeleteEventArgs.self, name: "mac_calendar_delete_event",
                run: MacCalendarDeleteEventArgs.run,
                toolClass: .destructive, reach: .person, capabilities: [.destructive, .filesystemDelete, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.calendar, .write), removes: "id",
                description: """
                    Delete exactly one calendar event occurrence by id from calendar.upcoming. Requires the observed title and start as \
                    preconditions; a changed event is not deleted. Never deletes a recurring series. Requires Calendar → Write and EventKit full \
                    access. Use only for an explicitly requested deletion.
                    """
            ),
            ActionDescriptor(MacRemindersCreateArgs.self, name: "mac_reminders_create",
                run: MacRemindersCreateArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .write), makes: "reminderId",
                description: "Create a new reminder in the user's Mac Reminders via EventKit. Requires Reminders -> Write permission (off by default)."
            ),
            ActionDescriptor(MacRemindersListRenameArgs.self, name: "mac_reminders_list_rename",
                run: MacRemindersListRenameArgs.run,
                toolClass: .write, reach: .person, capabilities: [.safeRead, .toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Rename exactly one Mac Reminders list via EventKit and read back its saved name. Matches names ignoring case and whitespace; \
                    emoji and variation selectors are significant. Refuses ambiguous or read-only lists and duplicate destination names. Requires \
                    Reminders → Write permission.
                    """
            ),
            ActionDescriptor(MacRemindersListCreateArgs.self, name: "mac_reminders_list_create",
                run: MacRemindersListCreateArgs.run,
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .safeRead, .toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Create a Mac Reminders list via EventKit in the default reminder list's account and read back its saved name. Refuses duplicate \
                    names or an unavailable or read-only default list. Requires Reminders → Write permission.
                    """
            ),
            ActionDescriptor(MacRemindersUpdateArgs.self, name: "mac_reminders_update",
                run: MacRemindersUpdateArgs.run, toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: """
                    Update exactly one Mac Reminder by id. Change only supplied title, notes or due_date; preserves its list and completion. \
                    Requires Reminders → Write permission.
                    """
            ),
            ActionDescriptor(MacRemindersCompleteArgs.self, name: "mac_reminders_complete",
                run: MacRemindersCompleteArgs.run, toolClass: .write, reach: .person,
                macIntegration: .init(MacIntegrationID.reminders, .write),
                description: "Mark a Mac Reminder done by its title (or id from reminders.due_today). Requires Reminders → Write permission."
            ),
            ActionDescriptor(MacRemindersDeleteArgs.self, name: "mac_reminders_delete",
                run: MacRemindersDeleteArgs.run,
                toolClass: .destructive, reach: .person, capabilities: [.destructive, .filesystemDelete, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.reminders, .write), removes: "id",
                description: """
                    Delete exactly one Mac Reminder by id from reminders.create or reminders.due_today. Requires its observed title as a \
                    precondition; a changed reminder is not deleted. Requires Reminders → Write permission. Use only for an explicitly requested \
                    deletion.
                    """
            ),
            ActionDescriptor(ContactsDeleteArgs.self, name: "contacts_delete",
                run: ContactsDeleteArgs.run,
                toolClass: .destructive, reach: .person, capabilities: [.destructive, .filesystemDelete, .outsideAppDataWrite, .toolCall],
                macIntegration: .init(MacIntegrationID.contacts, .write),
                description: """
                    Delete a Mac contact by its exact identifier from contacts.search. A name is never an identifier. Requires Contacts -> Write \
                    permission.
                    """
            ),
        ]
        return schemas
    }()
}
