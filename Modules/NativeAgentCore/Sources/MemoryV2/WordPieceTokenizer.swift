// WordPieceTokenizer.swift
//
// Pure-Swift WordPiece tokenizer compatible with BERT/MiniLM vocabularies.
//
// NOTE: The bundled `Resources/minilm_vocab.txt` is a STUB (~200 tokens) for
// unit tests. Production deployment requires the full 30522-line vocab:
//   curl -fsSL https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt \
//     -o Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm_vocab.txt

import Foundation

public final class WordPieceTokenizer: @unchecked Sendable {
    public let vocab: [String: Int]
    public let unkToken: String
    public let clsToken: String
    public let sepToken: String
    public let padToken: String
    public let maxInputCharsPerWord: Int
    public let doLowerCase: Bool

    public init(
        vocabURL: URL,
        unkToken: String = "[UNK]",
        clsToken: String = "[CLS]",
        sepToken: String = "[SEP]",
        padToken: String = "[PAD]",
        maxInputCharsPerWord: Int = 100,
        doLowerCase: Bool = true
    ) throws {
        let raw = try String(contentsOf: vocabURL, encoding: .utf8)
        var dict: [String: Int] = [:]
        var idx = 0
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let tok = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if tok.isEmpty { continue }
            if dict[tok] == nil {
                dict[tok] = idx
            }
            idx += 1
        }
        self.vocab = dict
        self.unkToken = unkToken
        self.clsToken = clsToken
        self.sepToken = sepToken
        self.padToken = padToken
        self.maxInputCharsPerWord = maxInputCharsPerWord
        self.doLowerCase = doLowerCase
    }

    public func tokenize(_ text: String) -> [String] {
        var s = text
        if doLowerCase { s = s.lowercased() }
        s = (s as NSString).precomposedStringWithCanonicalMapping
        s = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })

        let words = splitOnWhitespaceAndPunctuation(s)
        var output: [String] = []
        for word in words {
            if word.isEmpty { continue }
            if word.count > maxInputCharsPerWord {
                output.append(unkToken)
                continue
            }
            output.append(contentsOf: wordpieceGreedy(word))
        }
        return output
    }

    public func convertTokensToIds(_ tokens: [String]) -> [Int] {
        let unkId = vocab[unkToken] ?? 1
        return tokens.map { vocab[$0] ?? unkId }
    }

    public func encode(_ text: String, maxLength: Int) -> (inputIds: [Int], attentionMask: [Int]) {
        let cls = vocab[clsToken] ?? 2
        let sep = vocab[sepToken] ?? 3
        let pad = vocab[padToken] ?? 0

        let tokens = tokenize(text)
        var ids = convertTokensToIds(tokens)
        let bodyMax = max(0, maxLength - 2)
        if ids.count > bodyMax { ids = Array(ids.prefix(bodyMax)) }

        var inputIds: [Int] = [cls] + ids + [sep]
        var mask = [Int](repeating: 1, count: inputIds.count)
        while inputIds.count < maxLength {
            inputIds.append(pad)
            mask.append(0)
        }
        if inputIds.count > maxLength {
            inputIds = Array(inputIds.prefix(maxLength))
            mask = Array(mask.prefix(maxLength))
        }
        return (inputIds, mask)
    }

    private func splitOnWhitespaceAndPunctuation(_ s: String) -> [String] {
        var result: [String] = []
        var cur = ""
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !cur.isEmpty { result.append(cur); cur = "" }
            } else if isPunctuation(scalar) {
                if !cur.isEmpty { result.append(cur); cur = "" }
                result.append(String(scalar))
            } else {
                cur.unicodeScalars.append(scalar)
            }
        }
        if !cur.isEmpty { result.append(cur) }
        return result
    }

    private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true
        }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }

    private func wordpieceGreedy(_ word: String) -> [String] {
        let chars = Array(word)
        var subTokens: [String] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var match: String? = nil
            while start < end {
                var piece = String(chars[start..<end])
                if start > 0 { piece = "##" + piece }
                if vocab[piece] != nil {
                    match = piece
                    break
                }
                end -= 1
            }
            guard let m = match else {
                return [unkToken]
            }
            subTokens.append(m)
            start = end
        }
        return subTokens
    }
}
