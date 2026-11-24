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
// Blueprint: | `BrowserActions+Web.swift` | web action contracts and execution |

enum BrowserActions {}

struct MapsSearchArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", """
        Kind of business, place name or search terms. If near is absent, include a place after near/in/around, for example 'coffee \
        near Tampa airport'; the result reports the split.
        """, required: true)
    static let nearField = DoorFieldDescriptor.string("near", """
        Optional center address or place name; include city/region to disambiguate. When absent, split query at its first \
        near/in/around.
        """)
    static let radiusMilesField = DoorFieldDescriptor("radius_miles", ActionDescriptor.numSchema("Positive search radius in miles; defaults to 25, capped at 100.", minimum: 0), required: false)
    static let limitField = DoorFieldDescriptor("limit", ToolSchema.intSchema("Maximum places returned; defaults to 8, capped at 20.", minimum: 1), required: false)
    static let doorFields = [queryField, nearField, radiusMilesField, limitField]
    let query: String
    let near: String?
    let radiusMiles: Double?
    let limit: Int

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.requiredString(Self.queryField)
        near = try door.string(Self.nearField)
        radiusMiles = try door.number(Self.radiusMilesField)
        let requestedLimit = try door.number(Self.limitField) ?? 8
        limit = Int(min(requestedLimit, 20))
    }
}

struct MapsRouteArgs: DoorArgs {
    static let originField = DoorFieldDescriptor.string("origin", "Origin address or place name; include city/region to disambiguate.", required: true)
    static let destinationField = DoorFieldDescriptor.string("destination", "Destination address or place name; include city/region to disambiguate.", required: true)
    static let transportField = DoorFieldDescriptor("transport", ToolSchema.enumStringSchema(["automobile", "walking"], "Transport; defaults to automobile."), required: false)
    static let fractionField = DoorFieldDescriptor("fraction", ActionDescriptor.numSchema("Optional point along route distance, from 0 through 1; 0.5 is halfway.", minimum: 0, maximum: 1), required: false)
    static let doorFields = [originField, destinationField, transportField, fractionField]
    let origin: String
    let destination: String
    let transport: String?
    let fraction: DoorNumberLiteral?

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = ["origin": .string(origin), "destination": .string(destination)]
        fields["transport"] = transport.map(JSONValue.string)
        fields["fraction"] = fraction?.wire
        return fields
    }

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        origin = try door.requiredString(Self.originField)
        destination = try door.requiredString(Self.destinationField)
        transport = try door.string(Self.transportField)
        fraction = try door.numberLiteral(Self.fractionField)
    }
}

struct WebSearchArgs: DoorArgs {
    static let queryField = DoorFieldDescriptor.string("query", required: true)
    static let categoriesField = DoorFieldDescriptor.string("categories", "Optional SearXNG category, such as news, it or science.")
    static let timeRangeField = DoorFieldDescriptor("time_range", ToolSchema.enumStringSchema(["day", "week", "month", "year"],
        "Optional recency: pages from the past day, week, month or year."), required: false)
    static let doorFields = [queryField, categoriesField, timeRangeField]
    let query: String
    let categories: String?
    let timeRange: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        query = try door.requiredString(Self.queryField)
        categories = try door.string(Self.categoriesField)
        timeRange = try door.string(Self.timeRangeField)
    }
}

struct ReadPageArgs: DoorArgs {
    static let urlField = DoorFieldDescriptor.string("url", "Public http(s) URL to read.", required: true)
    static let findField = DoorFieldDescriptor.string("find", """
        Words to find, case-insensitively; every word must occur in the matching paragraph. Returns up to eight matching paragraphs \
        and their surroundings, in source order; omissions are stated in selection.
        """)
    static let aroundField = DoorFieldDescriptor("around", ToolSchema.intSchema("Surrounding paragraphs on each side of a find match; default 1, from 0 through 3.", minimum: 0,
        maximum: 3), required: false)
    static let fullField = DoorFieldDescriptor("full", ToolSchema.boolSchema("""
        With find: return the whole extracted text instead of the matching passages. Without find the whole text is returned \
        anyway; large results are paged.
        """), required: false)
    static let rawField = DoorFieldDescriptor("raw", ToolSchema.boolSchema("""
        Read the original fetched-text view instead of its sense, with raw provenance; find/full still control the text selection.
        """), required: false)
    static let wrongField = DoorFieldDescriptor("wrong", ToolSchema.boolSchema("""
        Mark the sense view wrong, read the original view and, after a successful read, offer sense repair guidance. Does not \
        repair it automatically.
        """), required: false)
    static let whyField = DoorFieldDescriptor.string("why", "Optional one-sentence explanation when reporting a wrong sense view.")
    static let doorFields = [urlField, findField, aroundField, fullField, rawField, wrongField, whyField]
    let url: String
    let find: String?
    let around: DoorNumberLiteral?
    let full: Bool?
    let raw: Bool?
    let wrong: Bool?
    let why: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        url = try door.requiredString(Self.urlField)
        find = try door.string(Self.findField)
        around = try door.numberLiteral(Self.aroundField)
        full = try door.bool(Self.fullField)
        raw = try door.bool(Self.rawField)
        wrong = try door.bool(Self.wrongField)
        why = try door.string(Self.whyField)
    }

    var wire: [String: JSONValue] {
        [
            Self.urlField.name: .string(url),
            Self.findField.name: find.map(JSONValue.string),
            Self.aroundField.name: around?.wire,
            Self.fullField.name: full.map(JSONValue.bool),
            Self.rawField.name: raw.map(JSONValue.bool),
            Self.wrongField.name: wrong.map(JSONValue.bool),
            Self.whyField.name: why.map(JSONValue.string),
        ].compactMapValues { $0 }
    }
}

extension BrowserActions {
    static let webActions: [ActionDescriptor] = {
        [
            ActionDescriptor(MapsSearchArgs.self, name: "maps_search",
                run: { context, args in
                    try await context.client.impl_maps_search(args: args)
                },
                toolClass: .read, capabilities: [.networkRead, .safeRead, .toolCall],
                description: """
                    Find businesses or places near an address or place name with MapKit. Returns the resolved center and matching places within the \
                    radius, sorted by straight-line distance in locale miles/km, with name, full address, phone, URL, category and coordinates when \
                    available. Results may not include every place. Does not open Maps or change the screen.
                    """
            ),
            ActionDescriptor(MapsRouteArgs.self, name: "maps_route",
                run: { context, args in
                    try await context.client.impl_maps_route(args: args)
                },
                toolClass: .read, capabilities: [.networkRead, .safeRead, .toolCall],
                description: """
                    Read a MapKit route between two addresses or place names: distance, ideal-conditions expected travel time (traffic: \
                    not_included) and every step in route order. Step distances describe each associated path segment, not the turn/exit manoeuvre \
                    itself. Returns resolved endpoints so you can check locations. Optional fraction names a point along route distance (0.5 is \
                    halfway), reverse-geocoded to a nearby place. Automobile by default; walking is also supported. Does not open Maps or change \
                    the screen.
                    """
            ),
            ActionDescriptor(WebSearchArgs.self, name: "web_search",
                run: { context, args in
                    try await context.client.dispatchWebSearch(args: args)
                }, toolClass: .read,
                description: """
                    Search the web through SearXNG: its results, or its failure with setup or repair guidance. An unconfigured SearXNG returns \
                    search unavailable. categories=news (or it, science) searches that SearXNG category. time_range=day|week|month|year asks for \
                    recent pages. Returns titles, URLs and snippets, the route and its time.
                    """
            ),
            ActionDescriptor(ReadPageArgs.self, name: "read_page",
                run: { context, args in
                    try await context.client.dispatchReadPage(turn: context.turn, invocation: context.invocation, args: args,
                        transportMetadata: context.transportMetadata)
                }, toolClass: .read,
                description: """
                    Read public http(s) text. A thin JavaScript shell is read through Chrome in another NativeAgent background tab under the normal browser \
                    gates, retaining the HTTP receipt separately and saying used_browser:true. text_reader names browser only when it has more readable \
                    content; otherwise HTTP text stays at the top with the browser result and cause attached. \
                    Chrome may use your signed-in session; consent is never \
                    accepted or dismissed. HTTP failures remain failures. In an HTTP read, find returns up to eight matching paragraphs \
                    with surroundings; without find the whole extracted text is returned (paged when large). full:true with find returns the whole \
                    text instead; in Chrome it starts at the first observed matching element (around applies to HTTP passages only). Includes requested/final \
                    URL, extraction outcome and omissions from the 1 MB response bound (32 MB for a PDF). \
                    Other binary formats are unsupported. Every successful fetch writes a limited-retention source receipt: source_receipt.path and \
                    purpose explain the retained text and coverage for inspection/citation without refetching; files.read requires normal \
                    permissions. A missing receipt proves neither an empty source nor a need to refetch. DNS, refused connections and timeouts \
                    return distinct reasons.
                    """
            ),
        ]
    }()
}
