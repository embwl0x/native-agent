import XCTest
@testable import MemoryV2

final class WordPieceTokenizerTests: XCTestCase {

    private func vocabURL() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let pkgRoot = here
            .deletingLastPathComponent() // MemoryV2Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeAgentCore
        let candidate = pkgRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MemoryV2")
            .appendingPathComponent("Resources")
            .appendingPathComponent("minilm_vocab.txt")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("vocab file not found")
    }

    private func makeTokenizer() throws -> WordPieceTokenizer {
        return try WordPieceTokenizer(vocabURL: try vocabURL())
    }

    func test_vocab_loads_from_file() throws {
        let t = try makeTokenizer()
        XCTAssertGreaterThan(t.vocab.count, 100)
        XCTAssertNotNil(t.vocab["[CLS]"])
        XCTAssertNotNil(t.vocab["[SEP]"])
    }

    func test_tokenize_lowercases_when_enabled() throws {
        let t = try makeTokenizer()
        let toks = t.tokenize("THE")
        XCTAssertEqual(toks, ["the"])
    }

    func test_tokenize_splits_on_whitespace_and_punctuation() throws {
        let t = try makeTokenizer()
        let toks = t.tokenize("the,of")
        XCTAssertEqual(toks, ["the", ",", "of"])
    }

    func test_tokenize_wordpiece_subword_splitting() throws {
        let t = try makeTokenizer()
        // "aq" is not present as a whole token in the stub vocab, but "a"
        // and "##q" are, so greedy WordPiece must split it.
        let toks = t.tokenize("aq")
        XCTAssertEqual(toks, ["a", "##q"])
    }

    func test_tokenize_word_longer_than_100_chars_emits_UNK() throws {
        let t = try makeTokenizer()
        let long = String(repeating: "a", count: 101)
        let toks = t.tokenize(long)
        XCTAssertEqual(toks, ["[UNK]"])
    }

    func test_tokenize_unknown_first_char_emits_UNK() throws {
        let t = try makeTokenizer()
        // U+2603 SNOWMAN — not in vocab, no single-char fallback present.
        let toks = t.tokenize("\u{2603}")
        XCTAssertEqual(toks, ["[UNK]"])
    }

    func test_convertTokensToIds_maps_with_UNK_fallback() throws {
        let t = try makeTokenizer()
        let ids = t.convertTokensToIds(["the", "totallybogustoken_xyz"])
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], t.vocab["the"])
        XCTAssertEqual(ids[1], t.vocab["[UNK]"])
    }

    func test_encode_prepends_CLS_appends_SEP() throws {
        let t = try makeTokenizer()
        let (ids, _) = t.encode("the", maxLength: 8)
        XCTAssertEqual(ids.first, t.vocab["[CLS]"])
        XCTAssertEqual(ids[1], t.vocab["the"])
        XCTAssertEqual(ids[2], t.vocab["[SEP]"])
    }

    func test_encode_truncates_to_maxLength_keeping_SEP() throws {
        let t = try makeTokenizer()
        let (ids, mask) = t.encode("the of and to in a is", maxLength: 5)
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(mask.count, 5)
        XCTAssertEqual(ids.first, t.vocab["[CLS]"])
        XCTAssertEqual(ids.last, t.vocab["[SEP]"])
    }

    func test_encode_pads_to_maxLength_with_PAD_id() throws {
        let t = try makeTokenizer()
        let (ids, _) = t.encode("the", maxLength: 8)
        XCTAssertEqual(ids.count, 8)
        let pad = t.vocab["[PAD]"]!
        XCTAssertEqual(ids[3], pad)
        XCTAssertEqual(ids[7], pad)
    }

    func test_encode_attention_mask_correct() throws {
        let t = try makeTokenizer()
        let (_, mask) = t.encode("the", maxLength: 8)
        XCTAssertEqual(mask.count, 8)
        XCTAssertEqual(Array(mask.prefix(3)), [1, 1, 1])
        XCTAssertEqual(Array(mask.suffix(5)), [0, 0, 0, 0, 0])
    }

    func test_encode_empty_string_returns_CLS_SEP_padded_to_maxLength() throws {
        let t = try makeTokenizer()
        let (ids, mask) = t.encode("", maxLength: 6)
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(ids[0], t.vocab["[CLS]"])
        XCTAssertEqual(ids[1], t.vocab["[SEP]"])
        XCTAssertEqual(Array(mask.prefix(2)), [1, 1])
        XCTAssertEqual(Array(mask.suffix(4)), [0, 0, 0, 0])
    }

    func test_tokenize_strips_control_chars() throws {
        let t = try makeTokenizer()
        let toks = t.tokenize("the\u{0007}")
        XCTAssertEqual(toks, ["the"])
    }
}
