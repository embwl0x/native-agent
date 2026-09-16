import Foundation
import Testing
@testable import Research

@Suite struct ResearchTextDecodingTests {
    @Test func quotedOtherParameterCannotSupplyCharset() {
        let result = ResearchTextDecoding.decode(Data("Café".utf8),
            contentType: "text/plain; note=\"fake; charset=windows-1252\"; CHARSET=\"UTF-8\"", mime: "text/plain", truncated: false)
        #expect(result.text == "Café")
        #expect(result.declaredCharset == "utf-8")
    }

    @Test func duplicateAliasesAreConsistentButConflictsFail() {
        let data = Data("hello".utf8)
        let same = ResearchTextDecoding.decode(data, contentType: "text/plain; charset=utf8; charset=\"utf-8\"", mime: "text/plain", truncated: false)
        #expect(same.text == "hello")
        let conflict = ResearchTextDecoding.decode(data, contentType: "text/plain; charset=utf-8; charset=latin1", mime: "text/plain", truncated: false)
        #expect(conflict.text == nil)
        #expect(conflict.error == "conflicting_charset_declarations")
    }

    @Test(arguments: ["application/json", "application/problem+json"])
    func jsonDoesNotHonorLegacyCharset(mime: String) {
        let value = "{\"message\":\"Café\"}"
        let decoded = ResearchTextDecoding.decode(Data(value.utf8), contentType: mime + "; charset=latin1", mime: mime, truncated: false)
        #expect(decoded.text == value)
        #expect(decoded.encoding == "utf-8")
        #expect(decoded.source == "json_utf8")
        let invalid = ResearchTextDecoding.decode(Data([0xE9]), contentType: mime + "; charset=latin1", mime: mime, truncated: false)
        #expect(invalid.text == nil)
    }

    @Test func bomIsNotSilentlyReinterpreted() {
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8)
        let valid = ResearchTextDecoding.decode(utf8, contentType: "text/plain", mime: "text/plain", truncated: false)
        #expect(valid.text == "hello")
        #expect(valid.source == "utf8_bom")
        let conflict = ResearchTextDecoding.decode(utf8, contentType: "text/plain; charset=latin1", mime: "text/plain", truncated: false)
        #expect(conflict.error == "charset_bom_conflict")
        let unsupportedBOMs: [[UInt8]] = [[0xFF, 0xFE, 0x61, 0x00], [0xFE, 0xFF, 0x00, 0x61], [0x00, 0x00, 0xFE, 0xFF]]
        for bytes in unsupportedBOMs {
            let unsupported = ResearchTextDecoding.decode(Data(bytes), contentType: "text/plain; charset=latin1", mime: "text/plain", truncated: false)
            #expect(unsupported.text == nil)
            #expect(unsupported.error == "unsupported_utf16_or_utf32_bom")
        }
    }

    @Test func truncatedUTF8RepairsOnlyAnIncompleteTerminalScalar() {
        let valid = ResearchTextDecoding.decode(Data([0x61, 0xE2, 0x82]), contentType: nil, mime: "text/plain", truncated: true)
        #expect(valid.text == "a")
        #expect(valid.discardedTerminalBytes == 2)
        let invalidSuffixes: [[UInt8]] = [[0x61, 0xFF], [0x61, 0xFF, 0x62], [0x61, 0xE0, 0x80], [0xFF, 0xE2, 0x82]]
        for bytes in invalidSuffixes {
            let invalid = ResearchTextDecoding.decode(Data(bytes), contentType: nil, mime: "text/plain", truncated: true)
            #expect(invalid.text == nil)
            #expect(invalid.discardedTerminalBytes == 0)
        }
    }

    @Test func asciiAndSingleByteCapsDoNotDropCharacters() {
        let ascii = ResearchTextDecoding.decode(Data("hello".utf8), contentType: "text/plain; charset=US-ASCII", mime: "text/plain", truncated: false)
        #expect(ascii.text == "hello")
        let invalidASCII = ResearchTextDecoding.decode(Data([0xE9]), contentType: "text/plain; charset=ascii", mime: "text/plain", truncated: false)
        #expect(invalidASCII.text == nil)
        let latin = ResearchTextDecoding.decode(Data([0x63, 0x61, 0x66, 0xE9]), contentType: "text/plain; charset=latin1", mime: "text/plain", truncated: true)
        #expect(latin.text == "café")
        #expect(latin.discardedTerminalBytes == 0)
    }

    @Test func xmlAndUnknownEncodingsAreNotExpanded() {
        let xml = ResearchTextDecoding.decode(Data([0xE9]), contentType: "application/xml; charset=latin1", mime: "application/xml", truncated: false)
        #expect(xml.error == "unsupported_xml_charset")
        let unknown = ResearchTextDecoding.decode(Data("hello".utf8), contentType: "text/plain; charset=made-up", mime: "text/plain", truncated: false)
        #expect(unknown.error == "unsupported_declared_charset")
    }
}
