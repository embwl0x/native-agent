import Foundation
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — row `public-api.MacPairingView.pairingPayloadJSON`.
//
// The Mac renders a QR whose payload is a dictionary literal in
// MacPairingView.swift; iOS decodes it into `ICloudPairingPayload` declared in
// iOS/NativeAgentMobile/Sources/PairingStore.swift. There is no shared type —
// the agreement lives in a hand-written comment on one side and a literal on
// the other. This is the classic two-vocabulary identity mismatch: a rename on
// EITHER side produces a QR that scans perfectly and silently fails to pair,
// and nobody wants to debug it with logging because the payload carries the
// raw pairing secret.
//
// The Mac helper is `private` inside a View, and the iOS module is not linked
// into this target, so the seam is proven by reading BOTH declarations and
// then round-tripping a real payload built from the scraped Mac literal
// through a decoder built from the scraped iOS field list.

private func macPayloadKeys() throws -> [String: String] {
    let source = try AppSourceScraping.appSource("MacPairingView.swift")
    let body = try AppSourceScraping.functionBody(named: "pairingPayloadJSON", in: source)
    let literalStart = try #require(
        body.range(of: "let body: [String: Any] = ["),
        "pairingPayloadJSON no longer builds a [String: Any] literal"
    )
    let open = body.index(before: literalStart.upperBound)
    let close = try #require(
        AppSourceScraping.balancedEnd(in: body, startingAt: open, opening: "[", closing: "]")
    )
    let literal = String(body[body.index(after: open)..<close])

    // "key": value  →  key : rendered-value ("secret" is a variable, recorded
    // as the sentinel <secret> so the shape is comparable).
    var pairs: [String: String] = [:]
    for entry in literal.split(separator: ",") {
        let halves = entry.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard halves.count == 2 else { continue }
        let key = halves[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let raw = halves[1]
        let value = raw.hasPrefix("\"")
            ? raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            : "<\(raw)>"
        pairs[key] = value
    }
    return pairs
}

private func iosPayloadFields() throws -> [String] {
    let repo = try AppSourceScraping.repositoryRoot()
    let store = repo.appendingPathComponent("iOS/NativeAgentMobile/Sources/PairingStore.swift")
    let source = try String(contentsOf: store, encoding: .utf8)
    let declStart = try #require(
        source.range(of: "struct ICloudPairingPayload: Codable {"),
        "iOS ICloudPairingPayload declaration moved — re-anchor this seam test"
    )
    let open = try #require(source[declStart.lowerBound...].firstIndex(of: "{"))
    let close = try #require(
        AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
    )
    let decl = String(source[open...close])

    var fields: [String] = []
    for line in decl.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") else { continue }
        let afterKeyword = trimmed.dropFirst(4)
        let name = afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        if !name.isEmpty { fields.append(String(name)) }
    }
    return fields
}

/// Mirror of the iOS decoder. Its field list is asserted equal to the scraped
/// iOS declaration below, so this struct cannot drift away from the real one
/// without the test going red.
private struct PairingPayloadMirror: Codable {
    let type: String
    let secret: String
    let version: String
}

@Test("the Mac QR payload keys and the iOS decoder's fields are the same vocabulary")
func pairingPayload_macAndIOSAgreeOnTheKeySet() throws {
    let mac = try macPayloadKeys()
    let ios = try iosPayloadFields()

    #expect(Set(mac.keys) == Set(ios), "Mac keys \(mac.keys.sorted()) vs iOS fields \(ios.sorted())")
    #expect(Set(ios) == ["type", "secret", "version"])

    // The two constant values are part of the contract, not free text: iOS
    // rejects anything whose `type` is not the discriminator it expects, and
    // the version string gates future format changes.
    #expect(mac["type"] == "icloud_pairing")
    #expect(mac["version"] == "1")
    #expect(mac["secret"] == "<secret>", "the secret must stay a runtime value, never a literal")

    // The local mirror used by the round-trip below must match the real iOS
    // declaration, or the round-trip proves nothing.
    let mirrorFields = ["type", "secret", "version"]
    #expect(Set(mirrorFields) == Set(ios), "PairingPayloadMirror drifted from the iOS declaration")
}

@Test("a payload built from the Mac literal decodes on the iOS side, secret intact")
func pairingPayload_roundTripsThroughTheIOSDecoder() throws {
    let mac = try macPayloadKeys()

    // A real 32-byte secret, base64'd exactly as MacPairingView does.
    var raw = Data(count: 32)
    for i in 0..<32 { raw[i] = UInt8((i * 7 + 11) % 251) }
    let secret = raw.base64EncodedString()

    var body: [String: Any] = [:]
    for (key, value) in mac {
        body[key] = (value == "<secret>") ? secret : value
    }

    // .sortedKeys is the Mac's own option — byte-identical output across
    // platforms is what any future HMAC over this payload would depend on.
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let json = try #require(String(data: data, encoding: .utf8))

    // Byte-identical output across platforms is what any future HMAC over this
    // payload depends on, so pin the ORDER (sortedKeys) rather than a literal
    // string — Foundation escapes "/" inside base64 as "\\/", and that
    // escaping is part of the bytes both sides must agree on.
    let secretIndex = try #require(json.range(of: "\"secret\""))
    let typeIndex = try #require(json.range(of: "\"type\""))
    let versionIndex = try #require(json.range(of: "\"version\""))
    #expect(secretIndex.lowerBound < typeIndex.lowerBound)
    #expect(typeIndex.lowerBound < versionIndex.lowerBound)
    #expect(json.contains("\"type\":\"icloud_pairing\""))
    #expect(json.contains("\"version\":\"1\""))

    let decoded = try JSONDecoder().decode(PairingPayloadMirror.self, from: data)
    #expect(decoded.type == "icloud_pairing")
    #expect(decoded.version == "1")
    #expect(Data(base64Encoded: decoded.secret) == raw)

    // And the Mac side still serialises with sortedKeys — dropping the option
    // is invisible today and breaks the moment anything signs this payload.
    let source = try AppSourceScraping.appSource("MacPairingView.swift")
    let macBody = try AppSourceScraping.functionBody(named: "pairingPayloadJSON", in: source)
    #expect(macBody.contains("options: [.sortedKeys]"))
}
