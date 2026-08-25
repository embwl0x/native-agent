import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / api.ChatView.attachments (UNCOVERED → COVERED, for
// the accepted-type half).
//
// Silent-failure mode being pinned: the main window resolves attachment types
// through `ChatAttachmentTypeResolver`, and the DETACHED panel carries its own
// private copy of the same table (DetachedChatPanelView.swift
// `detachedChatAttachmentTypeAndMime`). When the two drift, the same file is
// accepted in one window and refused in the other with "Unsupported file type" —
// a dead control with no error anywhere.
//
// The envelope asserted: the two tables are the same mapping. The parsed
// canonical table is cross-checked against LIVE calls into the resolver, so the
// parse cannot pass by testing itself.

private struct AttachmentTypeTableParser {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// extension → (type, mime) parsed out of a `switch ext` table.
    static func table(inFunctionNamed name: String, source: String) throws -> [String: String] {
        let body = try AppSourceScraping.functionBody(named: name, in: source)
        let pattern = #"case\s+((?:"[a-z0-9]+"\s*,?\s*)+):\s*(?:\n\s*)?return\s+\(\s*"([a-z]+)"\s*,\s*"([^"]+)"\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var table: [String: String] = [:]
        for match in regex.matches(in: body, range: range) {
            guard let extensionsRange = Range(match.range(at: 1), in: body),
                  let typeRange = Range(match.range(at: 2), in: body),
                  let mimeRange = Range(match.range(at: 3), in: body) else { continue }
            let value = "\(body[typeRange])|\(body[mimeRange])"
            for token in body[extensionsRange].split(separator: ",") {
                let ext = token.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t"))
                guard !ext.isEmpty else { continue }
                table[ext] = value
            }
        }
        guard !table.isEmpty else {
            throw ParseError(description: "no attachment cases parsed out of \(name)")
        }
        return table
    }
}

@Suite("Chat attachment type table parity")
struct ChatAttachmentTypeTableParityTests {

    private func parsedTables() throws -> (canonical: [String: String], detached: [String: String]) {
        let canonicalSource = try AppSourceScraping.appSource("ChatClipboardAndAttachmentSupport.swift")
        let detachedSource = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        return (
            try AttachmentTypeTableParser.table(
                inFunctionNamed: "typeAndMime", source: canonicalSource
            ),
            try AttachmentTypeTableParser.table(
                inFunctionNamed: "detachedChatAttachmentTypeAndMime", source: detachedSource
            )
        )
    }

    /// Anti-vacuity: the parsed canonical table must agree with the LIVE
    /// resolver for every extension it claims, and the resolver must refuse
    /// everything the table does not list.
    @Test func theParsedCanonicalTableMatchesTheLiveResolver() throws {
        let (canonical, _) = try parsedTables()
        #expect(canonical.count >= 8, "canonical attachment table looks under-parsed: \(canonical)")
        for (ext, expected) in canonical {
            let resolved = ChatAttachmentTypeResolver.typeAndMime(forExtension: ext)
            #expect(resolved != nil, "resolver refused \(ext), which its own table lists")
            if let resolved {
                #expect("\(resolved.type)|\(resolved.mime)" == expected,
                        "resolver disagrees with its own table for .\(ext)")
                #expect(["image", "file"].contains(resolved.type),
                        "unknown attachment kind \(resolved.type) for .\(ext)")
                if resolved.type == "image" {
                    #expect(resolved.mime.hasPrefix("image/"),
                            "image attachment .\(ext) carries a non-image mime")
                }
            }
        }
        for unknown in ["exe", "", "PNG.bak", "swift", "zip"] {
            #expect(ChatAttachmentTypeResolver.typeAndMime(forExtension: unknown) == nil,
                    "resolver accepted an unlisted extension: \(unknown)")
        }
        // Case is normalized by the CALLERS (`url.pathExtension.lowercased()`),
        // so the resolver itself must stay case-sensitive — an accidental
        // case-insensitive rewrite would silently change what both windows
        // accept.
        #expect(ChatAttachmentTypeResolver.typeAndMime(forExtension: "PNG") == nil)
    }

    /// The main window and the detached panel must accept exactly the same
    /// files, with the same mime. A drift here is invisible until a user drops
    /// a file on the wrong window.
    @Test func theDetachedPanelTableEqualsTheMainWindowTable() throws {
        let (canonical, detached) = try parsedTables()
        let onlyInMain = Set(canonical.keys).subtracting(detached.keys).sorted()
        let onlyInDetached = Set(detached.keys).subtracting(canonical.keys).sorted()
        #expect(onlyInMain.isEmpty,
                "the detached panel refuses file types the main window accepts: \(onlyInMain)")
        #expect(onlyInDetached.isEmpty,
                "the detached panel accepts file types the main window refuses: \(onlyInDetached)")
        for ext in Set(canonical.keys).intersection(detached.keys).sorted() {
            let mainValue = canonical[ext] ?? "-"
            let detachedValue = detached[ext] ?? "-"
            #expect(mainValue == detachedValue,
                    ".\(ext) maps to \(mainValue) in the main window and \(detachedValue) in the detached panel")
        }
    }

    /// The 10 MB attachment cap is duplicated across every attach path (picker,
    /// drag-drop, raw image drop, detached panel). One site drifting means a
    /// file the composer accepts is silently refused elsewhere.
    @Test func everyAttachPathEnforcesTheSameSizeCap() throws {
        let files = [
            "ChatView+Attachments.swift",
            "DetachedChatPanelView.swift",
        ]
        for file in files {
            let source = try AppSourceScraping.appSource(file)
            let capSites = AppSourceScraping.occurrences(of: "10_000_000", in: source)
            #expect(capSites > 0, "\(file) no longer enforces the 10 MB attachment cap")
            // Any OTHER byte-cap literal in an attachment path is a drift tell.
            #expect(!source.contains("5_000_000"), "\(file) introduced a second, different cap")
            #expect(!source.contains("20_000_000"), "\(file) introduced a second, different cap")
        }
    }
}
