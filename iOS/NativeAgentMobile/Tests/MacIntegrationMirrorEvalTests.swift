import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows closed here:
///   * `ios.macintegration.catalog`  — 11 rows of ids hand-mirrored from
///     `MacIntegrationID`, with a source comment saying they must match
///     byte-for-byte. Nothing checked it.
///   * `ios.macintegration.defaults` / `ios.macintegration.defaultValue` — a
///     SECOND hand-copy of the Mac's `defaultPermission(for:)`, again with a
///     "update both sides" comment and no check.
///   * `ios.macintegration.kvsKey` — a bare string literal shared with the Mac
///     writer; a one-sided rename silently reverts every toggle to defaults.
///   * `ios.macintegration.applyProjection.wholeEntryReplace` — the optimistic
///     projection replaces the WHOLE entry, so the untouched axis is dropped.
///
/// Silent-failure class: WRONG VALUE / cross-vocabulary drift. The Mac's gate
/// is what actually runs; the phone only renders a claim about it. A one-sided
/// edit makes the phone lie about what the agent may do on the Mac, and every
/// screen still looks perfectly healthy.
///
/// These assert against the REAL Mac sources (read off the checkout) rather
/// than a second copy of the table in the test — a copy would only test itself.
@MainActor
final class MacIntegrationMirrorEvalTests: XCTestCase {

    private static let macPermissionsPath =
        "Modules/NativeAgentCore/Sources/MacIntegration/MacIntegrationPermissions.swift"
    private static let macKVSWriterPath =
        "Sources/NativeAgentApp/MacIntegrationICloudBridge.swift"

    // MARK: - Parsed Mac truth

    private struct MacTruth {
        /// identifier -> wire id, e.g. "notifyMac" -> "notify_mac"
        var idsByIdentifier: [String: String]
        /// display order from `MacIntegrationID.all`
        var orderedIDs: [String]
        /// ids with NO read axis
        var readUnsupported: Set<String>
        /// ids with NO write axis
        var writeUnsupported: Set<String>
        /// ids whose write axis defaults ON
        var writeDefaultsOn: Set<String>
    }

    private func parseMacTruth() throws -> MacTruth {
        let source = try MobileEvalSources.repoFile(Self.macPermissionsPath)
        guard let body = MobileEvalSources.blockBody(
            named: "MacIntegrationID", keyword: "public enum", in: source
        ) else {
            throw MobileEvalSources.LocatorError.missing("\(Self.macPermissionsPath) :: enum MacIntegrationID")
        }

        let literal = #"public static let (\w+)\s*=\s*"([a-z_]+)""#
        let identifiers = MobileEvalSources.matches(literal, in: body, group: 1)
        let wireIDs = MobileEvalSources.matches(literal, in: body, group: 2)
        XCTAssertEqual(identifiers.count, wireIDs.count)
        XCTAssertFalse(identifiers.isEmpty, "Parsed zero id literals out of MacIntegrationID — the parser, not the app, is broken.")
        let idsByIdentifier = Dictionary(uniqueKeysWithValues: zip(identifiers, wireIDs))

        // `public static let all: [String] = [ ... ]` — the display order.
        guard let allStart = body.range(of: "public static let all: [String] = ["),
              let allEnd = body.range(of: "]", range: allStart.upperBound..<body.endIndex) else {
            throw MobileEvalSources.LocatorError.missing("MacIntegrationID.all")
        }
        let orderedIDs = body[allStart.upperBound..<allEnd.lowerBound]
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
            .compactMap { idsByIdentifier[$0] }

        func funcSegment(_ name: String) throws -> String {
            let parts = body.components(separatedBy: "public static func ")
            guard let segment = parts.first(where: { $0.hasPrefix(name) }) else {
                throw MobileEvalSources.LocatorError.missing("MacIntegrationID.\(name)")
            }
            return segment
        }

        func caseIDs(followedBy line: String, in segment: String) -> Set<String> {
            let pattern = #"case ([^:\n]+):\s*\n\s*"# + NSRegularExpression.escapedPattern(for: line)
            let clauses = MobileEvalSources.matches(pattern, in: segment, group: 1)
            var out: Set<String> = []
            for clause in clauses {
                for identifier in clause.split(separator: ",") {
                    let trimmed = identifier.trimmingCharacters(in: .whitespaces)
                    if let wire = idsByIdentifier[trimmed] { out.insert(wire) }
                }
            }
            return out
        }

        let readUnsupported = caseIDs(followedBy: "return false", in: try funcSegment("supportsRead"))
        let writeUnsupported = caseIDs(followedBy: "return false", in: try funcSegment("supportsWrite"))
        let writeDefaultsOn = caseIDs(followedBy: "write = true", in: try funcSegment("defaultPermission"))

        XCTAssertFalse(readUnsupported.isEmpty, "Parsed no send-only ids out of supportsRead — parser drift.")
        XCTAssertFalse(writeUnsupported.isEmpty, "Parsed no read-only ids out of supportsWrite — parser drift.")
        XCTAssertFalse(writeDefaultsOn.isEmpty, "Parsed no write-ON ids out of defaultPermission — parser drift.")

        return MacTruth(
            idsByIdentifier: idsByIdentifier,
            orderedIDs: orderedIDs,
            readUnsupported: readUnsupported,
            writeUnsupported: writeUnsupported,
            writeDefaultsOn: writeDefaultsOn
        )
    }

    // MARK: - ios.macintegration.catalog

    func test_iOSCatalogIDsMatchTheMacIntegrationIDVocabularyExactly() throws {
        let mac = try parseMacTruth()
        let phoneIDs = MacIntegrationCatalog.rows.map(\.id)

        XCTAssertEqual(
            phoneIDs, mac.orderedIDs,
            """
            iOS MacIntegrationCatalog drifted from Modules/NativeAgentCore MacIntegrationID.
            The Mac's hot-path gate looks these up BY STRING: an id only the phone knows
            renders a toggle that gates nothing, and an id only the Mac knows is a
            capability with no visible switch. iOS=\(phoneIDs) mac=\(mac.orderedIDs)
            """
        )
    }

    // MARK: - ios.macintegration.defaults (catalog rows vs the Mac rule)

    func test_iOSCatalogAxisSupportAndDefaultsMatchTheMacRule() throws {
        let mac = try parseMacTruth()

        for row in MacIntegrationCatalog.rows {
            let macSupportsRead = !mac.readUnsupported.contains(row.id)
            let macSupportsWrite = !mac.writeUnsupported.contains(row.id)
            XCTAssertEqual(row.supportsRead, macSupportsRead, "supportsRead drifted for \(row.id)")
            XCTAssertEqual(row.supportsWrite, macSupportsWrite, "supportsWrite drifted for \(row.id)")

            // MacIntegrationID.defaultPermission: read defaults to supportsRead,
            // write defaults ON only for the trusted outbound channels, clamped
            // to false on an unsupported axis.
            let macDefaultRead = macSupportsRead
            let macDefaultWrite = macSupportsWrite && mac.writeDefaultsOn.contains(row.id)
            XCTAssertEqual(
                row.defaultRead, macDefaultRead,
                "defaultRead drifted for \(row.id): the phone would show the wrong starting posture"
            )
            XCTAssertEqual(
                row.defaultWrite, macDefaultWrite,
                "defaultWrite drifted for \(row.id): the phone would show the wrong starting posture"
            )
        }
    }

    // MARK: - ios.macintegration.defaultValue (the SECOND iOS mirror)

    func test_projectionGateDefaultsAgreeWithTheCatalogRowForEveryIDAndAxis() throws {
        let sync = MacIntegrationPermissionsSync.shared
        // The gate only falls back to its hand-copied defaults for UNSET keys.
        // If KVS carried a value the check below would be vacuous, so require
        // the unset state explicitly instead of skipping.
        let stored = sync.permissions
        for row in MacIntegrationCatalog.rows {
            // An entry with no axes does not shadow the defaults, so it is not
            // a reason to skip. A POPULATED entry would make the check vacuous.
            try XCTSkipIf(
                !(stored[row.id] ?? [:]).isEmpty,
                "KVS already holds an axis for \(row.id); this eval measures the UNSET default path"
            )
            XCTAssertEqual(
                sync.get(id: row.id, mode: "read"), row.defaultRead,
                "MacIntegrationPermissionsSync.defaultValue drifted from MacIntegrationCatalog for \(row.id).read"
            )
            XCTAssertEqual(
                sync.get(id: row.id, mode: "write"), row.defaultWrite,
                "MacIntegrationPermissionsSync.defaultValue drifted from MacIntegrationCatalog for \(row.id).write"
            )
        }
        // An axis nobody defined is never optimistically true.
        XCTAssertFalse(sync.get(id: "calendar", mode: "delete"))
        XCTAssertFalse(sync.get(id: "not_an_integration", mode: "read"))
    }

    // MARK: - ios.macintegration.applyProjection.wholeEntryReplace

    func test_optimisticProjectionNeverLeavesAStaleValueOnTheAxisItDidNotCarry() throws {
        let sync = MacIntegrationPermissionsSync.shared
        let probeID = "calendar"
        try XCTSkipIf(!(sync.permissions[probeID] ?? [:]).isEmpty, "KVS already holds an axis for \(probeID)")
        defer { sync.applyProjection(id: probeID, read: nil, write: nil) }

        // Calendar defaults read=ON / write=OFF. Project the OPPOSITE of both.
        sync.applyProjection(id: probeID, read: false, write: true)
        XCTAssertFalse(sync.get(id: probeID, mode: "read"))
        XCTAssertTrue(sync.get(id: probeID, mode: "write"))

        // A follow-up projection that carries only ONE axis replaces the whole
        // entry. The contract this pins: the dropped axis falls back to the
        // DEFAULT — it must never keep serving the previous optimistic value,
        // because that value was never confirmed by the Mac.
        sync.applyProjection(id: probeID, read: nil, write: false)
        XCTAssertEqual(
            sync.get(id: probeID, mode: "read"), true,
            "the dropped read axis kept a stale unconfirmed value instead of falling back to the default"
        )
        XCTAssertFalse(sync.get(id: probeID, mode: "write"))

        // Clearing both axes empties the entry entirely — no residue.
        sync.applyProjection(id: probeID, read: nil, write: nil)
        XCTAssertTrue(sync.permissions[probeID]?.isEmpty == true)
        XCTAssertEqual(sync.get(id: probeID, mode: "read"), true)
        XCTAssertEqual(sync.get(id: probeID, mode: "write"), false)
    }

    // MARK: - ios.macintegration.kvsKey

    func test_kvsKeyMatchesTheMacWriterLiteral() throws {
        let macWriter = try MobileEvalSources.repoFile(Self.macKVSWriterPath)
        let literals = MobileEvalSources.matches(
            #"static let kvsKey\s*=\s*"([^"]+)""#, in: macWriter
        )
        XCTAssertEqual(literals.count, 1, "Could not read the Mac writer's kvsKey out of \(Self.macKVSWriterPath)")
        XCTAssertEqual(
            MacIntegrationPermissionsSync.kvsKey, literals.first,
            """
            The iOS reader and the Mac writer disagree on the KVS key. Neither side errors:
            the phone just reads nothing and renders DEFAULTS as if they were the user's
            saved settings.
            """
        )
    }
}
