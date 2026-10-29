import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+WebSchemas.swift` | `BuiltInToolSchemaFactory`: `webSchemas`: maps, routes, web search and page reads |

extension BuiltInToolSchemaFactory {
    func webSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "maps_search",
                toolClass: .read, capabilities: ["network_read", "safe_read", "tool_call"],
                description: "Find businesses or places near an address or place name with MapKit. Returns the resolved center and matching places within the radius, sorted by straight-line distance in locale miles/km, with name, full address, phone, URL, category and coordinates when available. Results may not include every place. Does not open Maps or change the screen.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema("Kind of business, place name or search terms. If near is absent, include a place after near/in/around, for example 'coffee near Tampa airport'; the result reports the split.")),
                    ("near", ToolSchema.strSchema("Optional center address or place name; include city/region to disambiguate. When absent, split query at its first near/in/around.")),
                    ("radius_miles", numSchema("Positive search radius in miles; defaults to 25, capped at 100.", minimum: 0)),
                    ("limit", ToolSchema.intSchema("Maximum places returned; defaults to 8, capped at 20.", minimum: 1)),
                ], required: ["query"])
            ),
            requestedSchema(name: "maps_route",
                toolClass: .read, capabilities: ["network_read", "safe_read", "tool_call"],
                description: "Read a MapKit route between two addresses or place names: distance, ideal-conditions expected travel time (traffic: not_included) and every step in route order. Step distances describe each associated path segment, not the turn/exit manoeuvre itself. Returns resolved endpoints so you can check locations. Optional fraction names a point along route distance (0.5 is halfway), reverse-geocoded to a nearby place. Automobile by default; walking is also supported. Does not open Maps or change the screen.",
                parametersJSON: ToolSchema.params(properties: [
                    ("origin", ToolSchema.strSchema("Origin address or place name; include city/region to disambiguate.")),
                    ("destination", ToolSchema.strSchema("Destination address or place name; include city/region to disambiguate.")),
                    ("transport", ToolSchema.enumStringSchema(["automobile", "walking"], "Transport; defaults to automobile.")),
                    ("fraction", numSchema("Optional point along route distance, from 0 through 1; 0.5 is halfway.", minimum: 0, maximum: 1)),
                ], required: ["origin", "destination"])
            ),
            requestedSchema(name: "web_search", toolClass: .read,
                description: "Search the web through SearXNG: its results, or its failure said plainly. On a Mac without SearXNG the result hands you browser_search, the same search in Chrome (or your own browser), to run and read. categories=news (or it, science) searches that SearXNG category. time_range=day|week|month|year asks for recent pages. Returns titles, URLs and snippets, the route and its time.",
                parametersJSON: ToolSchema.params(properties: [
                    ("query", ToolSchema.strSchema()),
                    ("categories", ToolSchema.strSchema("Optional SearXNG category, such as news, it or science.")),
                    ("time_range", ToolSchema.enumStringSchema(["day", "week", "month", "year"], "Optional recency: pages from the past day, week, month or year.")),
                ], required: ["query"])
            ),
            requestedSchema(name: "read_page", toolClass: .read,
                description: "Read public http(s) privately, without a browser, signed-in session or consent. find returns up to eight matching paragraphs with surroundings; without find the whole extracted text is returned (paged when large). full:true with find returns the whole text instead. Includes requested/final URL, extraction outcome and omissions from the 1 MB response bound (32 MB for a PDF). Other binary formats are unsupported. Every successful fetch writes a limited-retention source receipt: source_receipt.path and purpose explain the retained text and coverage for inspection/citation without refetching; files.read requires normal permissions. A missing receipt proves neither an empty source nor a need to refetch. DNS, refused connections and timeouts return distinct reasons.",
                parametersJSON: ToolSchema.params(properties: [
                    ("url", ToolSchema.strSchema("Public http(s) URL to read.")),
                    ("find", ToolSchema.strSchema("Words to find, case-insensitively; every word must occur in the matching paragraph. Returns up to eight matching paragraphs and their surroundings, in source order; omissions are stated in selection.")),
                    ("around", ToolSchema.intSchema("Surrounding paragraphs on each side of a find match; default 1, from 0 through 3.", minimum: 0, maximum: 3)),
                    ("full", ToolSchema.boolSchema("With find: return the whole extracted text instead of the matching passages. Without find the whole text is returned anyway; large results use tool-output paging.")),
                    ("raw", ToolSchema.boolSchema("Read the original fetched-text view instead of its sense, with raw provenance; find/full still control the text selection.")),
                    ("wrong", ToolSchema.boolSchema("Mark the sense view wrong, read the original view and, after a successful read, offer sense repair guidance. Does not repair it automatically.")),
                    ("why", ToolSchema.strSchema("Optional one-sentence explanation when reporting a wrong sense view.")),
                ], required: ["url"])
            ),
        ]
    }
}
