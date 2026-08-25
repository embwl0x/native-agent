import Foundation
import Testing
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, the inbox wire types the policy surface and
// the cards are built from. All three are decode-side envelopes: the failure
// mode in every case is a schema that shifts under a `try?` and degrades into
// something that still RENDERS.
//
// Ledger rows covered:
//   desk.inboxPolicy.watchedPaths — wrong value: the Watched Paths editor
//                                   round-trips through a [String:String]
//                                   flattening; a lossy decode renders an EMPTY
//                                   editor and Save then clobbers a working
//                                   path list
//   desk.inbox.record.decode      — silent zero: nearly every field is `try?`
//                                   with a default, so a schema change degrades
//                                   a card instead of failing
//   desk.inbox.groupFilter        — the matching half: a group that matches
//                                   everything (or its own card) turns the
//                                   Review Groups panel into noise

private func decodeTrigger(_ json: String) throws -> InboxTriggerConfig {
    try JSONDecoder().decode(InboxTriggerConfig.self, from: Data(json.utf8))
}

// MARK: - the Watched Paths editor round-trip

/// The editor shows `config["paths"]`, newline-joined, and Save writes whatever
/// is in the box back over the live trigger config. So the decode has to be
/// lossless for the shape the server actually sends (a JSON array of strings),
/// and it must not throw away the rest of the config because one value is not a
/// string.
///
/// Mutation proof: changing the decoder's `joined(separator: "\n")` to a comma
/// (or dropping the array branch) fails this test.
@Test("a file_watch trigger's path array survives decode → editor text → encode")
func inboxTriggerConfigRoundTripsWatchedPaths() throws {
    // The live wire shape: paths as an array, alongside values of other types.
    let config = try decodeTrigger("""
    {"name":"file_watch","enabled":true,"kind":"file",
     "config":{"paths":["/Users/j/Projects/a","/Users/j/Projects/b"],
               "debounce_seconds":30,"recursive":true,"label":"repos"},
     "description":"watch some paths"}
    """)

    // 1. The array is what the editor renders: one path per line, in order,
    //    nothing lost.
    let editorText = try #require(config.config?["paths"])
    #expect(editorText.split(separator: "\n").map(String.init)
            == ["/Users/j/Projects/a", "/Users/j/Projects/b"])

    // 2. A non-string value never takes the whole config down with it — the
    //    editor would render empty and Save would clobber the real list.
    #expect(config.config?["debounce_seconds"] == "30")
    #expect(config.config?["recursive"] == "true")
    #expect(config.config?["label"] == "repos")

    // 3. Save round-trip: encode → decode reproduces the same editor text.
    let encoded = try JSONEncoder().encode(config)
    let reloaded = try JSONDecoder().decode(InboxTriggerConfig.self, from: encoded)
    #expect(reloaded.config?["paths"] == editorText,
            "the path list changed shape across a save/reload cycle")
    #expect(reloaded.name == config.name)
    #expect(reloaded.enabled == config.enabled)
    #expect(reloaded.kind == config.kind)

    // 4. A single path (the common case) still round-trips as one line, not as
    //    a bare JSON fragment.
    let single = try decodeTrigger("""
    {"name":"file_watch","enabled":false,"kind":"file","config":{"paths":["/only/one"]}}
    """)
    #expect(single.config?["paths"] == "/only/one")

    // 5. `enabled` FAILS CLOSED: a trigger whose enabled flag is missing or of
    //    the wrong type must never render as ON. A switch showing ON for a
    //    trigger the server never enabled is the worst reading of this panel.
    for body in [
        #"{"name":"t","kind":"time"}"#,
        #"{"name":"t","enabled":"true","kind":"time"}"#,
        #"{"name":"t","enabled":1,"kind":"time"}"#,
    ] {
        #expect(try decodeTrigger(body).enabled == false,
                "a non-boolean `enabled` decoded as ON: \(body)")
    }

    // 6. A config with no string-convertible values at all is nil, not an empty
    //    map — the surface can tell "no paths configured" from "we could not
    //    read the config" only if those two decode differently.
    let opaque = try decodeTrigger("""
    {"name":"file_watch","enabled":true,"kind":"file","config":{"nested":{"a":1}}}
    """)
    #expect(opaque.config == nil)
}

// MARK: - the card decoder never invents a card

/// `InboxItemRecord` decodes almost every field with `try?` + a default so a
/// schema drift degrades rather than throws. The envelope that keeps that
/// honest: the IDENTITY must still be required (a row with no id is a card no
/// action can ever be routed to), and the defaults must be inert — never a
/// severity or a status that changes how the card is treated.
///
/// Mutation proof: changing `id = try c.decode(...)` to a `try?` with a default
/// fails this test.
@Test("an inbox card without an id fails to decode instead of becoming a ghost row")
func inboxRecordRequiresAnIdentity() throws {
    let noID = #"{"created_at":"2026-08-11T00:00:00Z","source":"s","title":"t","actions":[],"status":"unread"}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(InboxItemRecord.self, from: Data(noID.utf8))
    }

    // Everything else degrades to an inert default rather than a lie.
    let bare = try JSONDecoder().decode(
        InboxItemRecord.self, from: Data(#"{"id":"only-an-id"}"#.utf8))
    #expect(bare.id == "only-an-id")
    #expect(bare.title.isEmpty, "a missing title must render empty, never invented")
    #expect(bare.summary.isEmpty)
    #expect(bare.severity == "info", "a missing severity must default to the QUIETEST tier")
    #expect(bare.status == "unread")
    #expect(bare.detail == nil)
    #expect(bare.actions.isEmpty)
    #expect(bare.related_paths == nil)
    #expect(bare.relatedWorkshopExecutionId == nil)
    #expect(!bare.isHiddenFromDefaultInbox,
            "a degraded card must not hide itself from the default inbox")

    // A wrong-typed field degrades the same way — it must not take the record
    // (and therefore the whole feed line) down.
    let wrongTypes = try JSONDecoder().decode(
        InboxItemRecord.self,
        from: Data(#"{"id":"x","severity":7,"title":null,"actions":"nope","status":42}"#.utf8))
    #expect(wrongTypes.id == "x")
    #expect(wrongTypes.severity == "info")
    #expect(wrongTypes.title.isEmpty)
    #expect(wrongTypes.actions.isEmpty)
    #expect(wrongTypes.status == "unread")

    // Status handling is whitespace/case tolerant, so a producer emitting
    // " Unread\n" cannot silently drop a card out of the unread lane.
    let messyStatus = try JSONDecoder().decode(
        InboxItemRecord.self, from: Data(#"{"id":"y","status":" Unread\n"}"#.utf8))
    #expect(messyStatus.isUnread)
    #expect(!messyStatus.isHiddenFromDefaultInbox)
}

// MARK: - a related group can't claim the whole inbox

/// Groups drive the Review Groups filter. `matches` falls back to a TITLE
/// compare when the group carries no item ids — so an empty or whitespace title
/// would match every untitled card in the feed, and a group must never claim
/// the card it was derived from.
///
/// Mutation proof: dropping the `!cleanTitle.isEmpty` guard fails this test.
@Test("a related group matches its members, never itself and never everything")
func inboxRelatedGroupMatchingIsBounded() throws {
    func item(_ id: String, title: String) throws -> InboxItemRecord {
        try JSONDecoder().decode(
            InboxItemRecord.self,
            from: Data(#"{"id":"\#(id)","title":"\#(title)","status":"unread"}"#.utf8))
    }
    func group(id: String, title: String, itemIDs: [String]?) throws -> InboxRelatedGroup {
        let ids = itemIDs.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        return try JSONDecoder().decode(
            InboxRelatedGroup.self,
            from: Data(#"{"id":"\#(id)","title":"\#(title)","count":2,"item_ids":\#(ids)}"#.utf8))
    }

    let a = try item("a", title: "Nightly reflection failed")
    let b = try item("b", title: "Nightly reflection failed")
    let untitled = try item("u", title: "")

    // id-backed: exact membership, and never the group's own card.
    let byIDs = try group(id: "a", title: "Nightly reflection failed", itemIDs: ["a", "b"])
    #expect(!byIDs.matches(a), "a group matched the card it is named after")
    #expect(byIDs.matches(b))
    #expect(!byIDs.matches(untitled))

    // title-backed fallback: matches equal titles only.
    let byTitle = try group(id: "g", title: "Nightly reflection failed", itemIDs: nil)
    #expect(byTitle.matches(a))
    #expect(byTitle.matches(b))
    #expect(!byTitle.matches(untitled), "an untitled card was pulled into a titled group")

    // an empty / whitespace title matches NOTHING — otherwise one malformed
    // group swallows every untitled card in the inbox.
    for blank in ["", " ", "\\n  "] {
        let empty = try group(id: "g2", title: blank, itemIDs: nil)
        #expect(!empty.matches(a))
        #expect(!empty.matches(untitled),
                "a group titled `\(blank)` matched an untitled card — it would claim the whole feed")
    }

    // the count a chip renders is never smaller than the membership it carries.
    let undercounted = try JSONDecoder().decode(
        InboxRelatedGroup.self,
        from: Data(#"{"id":"g3","title":"t","count":1,"item_ids":["a","b","c"]}"#.utf8))
    #expect(undercounted.displayCount == 3,
            "the group chip claims \(undercounted.displayCount) while carrying 3 members")
}
