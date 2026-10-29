// Pure-Swift WordPiece tokenizer for bge's BERT vocabulary.
//
// The vocabulary is resolved beside bge's embedding.json as vocab.txt.

import Foundation

// Blueprint: | `WordPieceTokenizer.swift` | `WordPieceTokenizer`: bge BERT vocabulary tokenization, greedy subwords and encoded token IDs |

public final class WordPieceTokenizer: Sendable {
    public let vocab: [String: Int]
    private let unkID: Int
    private let clsID: Int
    private let sepID: Int
    private let padID: Int

    public init(vocabURL: URL) throws {
        let raw = try String(contentsOf: vocabURL, encoding: .utf8)
        var dict: [String: Int] = [:]
        var idx = 0
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let tok = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if tok.isEmpty { continue }
            guard Int32(exactly: idx) != nil else {
                throw EmbeddingError.modelNotLoaded(reason: "WordPiece vocabulary ID exceeds Int32 range")
            }
            if dict[tok] == nil {
                dict[tok] = idx
            }
            let (next, overflow) = idx.addingReportingOverflow(1)
            guard !overflow else { throw EmbeddingError.modelNotLoaded(reason: "WordPiece vocabulary is too large") }
            idx = next
        }
        guard let unk = dict["[UNK]"], let cls = dict["[CLS]"],
              let sep = dict["[SEP]"], let pad = dict["[PAD]"] else {
            throw EmbeddingError.modelNotLoaded(reason: "WordPiece vocabulary lacks required [UNK], [CLS], [SEP] or [PAD] token")
        }
        self.unkID = unk
        self.clsID = cls
        self.sepID = sep
        self.padID = pad
        self.vocab = dict
    }

    public func encode(_ text: String, maxLength: Int) -> (inputIds: [Int], attentionMask: [Int], isComplete: Bool) {
        let maxLength = max(0, maxLength)
        let bodyMax = max(0, maxLength - 2)
        var s = text.lowercased()
        s = (s as NSString).precomposedStringWithCanonicalMapping
        s = String(String.UnicodeScalarView(s.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark
        }))
        s = String(String.UnicodeScalarView(s.unicodeScalars.compactMap { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return UnicodeScalar(0x20) }
            return scalar.value >= 0x20 && scalar.value != 0x7F ? scalar : nil
        }))

        var ids: [Int] = []
        func appendWord(_ word: String) {
            guard !word.isEmpty else { return }
            // Finish the word: an unmatched suffix replaces all its pieces with UNK.
            let pieces = word.count > 100 ? [unkID] : wordpieceGreedy(word)
            ids.append(contentsOf: pieces.prefix(bodyMax + 1 - ids.count))
        }
        var word = ""
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || isPunctuation(scalar) || isChineseCharacter(scalar) {
                appendWord(word)
                word = ""
                if ids.count > bodyMax { break }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { appendWord(String(scalar)) }
                if ids.count > bodyMax { break }
            } else {
                word.unicodeScalars.append(scalar)
            }
        }
        if ids.count <= bodyMax { appendWord(word) }
        let isComplete = ids.count <= bodyMax
        var inputIds: [Int] = [clsID] + ids.prefix(bodyMax) + [sepID]
        var mask = [Int](repeating: 1, count: inputIds.count)
        while inputIds.count < maxLength {
            inputIds.append(padID)
            mask.append(0)
        }
        if inputIds.count > maxLength {
            inputIds = Array(inputIds.prefix(maxLength))
            mask = Array(mask.prefix(maxLength))
        }
        return (inputIds, mask, isComplete)
    }

    private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true
        }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }

    private func isChineseCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
             0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
             0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private func wordpieceGreedy(_ word: String) -> [Int] {
        let chars = Array(word)
        var subTokens: [Int] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var match: Int? = nil
            while start < end {
                var piece = String(chars[start..<end])
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] {
                    match = id
                    break
                }
                end -= 1
            }
            guard let m = match else {
                return [unkID]
            }
            subTokens.append(m)
            start = end
        }
        return subTokens
    }
}
