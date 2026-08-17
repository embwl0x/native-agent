import Testing
import Foundation
import CoreML
@testable import MemoryV2

@Suite("CoreML MiniLM embedder parity")
struct CoreMLEmbedderTests {

    private struct RefPayload: Decodable {
        struct Sample: Decodable {
            let text: String
            let embedding: [Float]
        }
        let samples: [Sample]
    }

    @Test("minilm_mlpackage_matches_reference_for_hello")
    func minilm_mlpackage_matches_reference_for_hello() async throws {
        // Resolve the .mlpackage from the MemoryV2 resource bundle.
        guard let pkgURL = Bundle.module.url(
            forResource: "minilm", withExtension: "mlpackage"
        ) else {
            Issue.record("minilm.mlpackage not present in Bundle.module — convert step did not run")
            return
        }

        // .mlpackage must be compiled to .mlmodelc before MLModel can load it.
        let compiledURL = try await MLModel.compileModel(at: pkgURL)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: compiledURL, configuration: config)

        // Tokenize "hello" with the in-tree WordPiece tokenizer (must match
        // the HF MiniLM vocab convention: [CLS] hello [SEP] padded to 128).
        guard let vocabURL = Bundle.module.url(
            forResource: "minilm_vocab", withExtension: "txt"
        ) else {
            Issue.record("minilm_vocab.txt missing from Bundle.module")
            return
        }
        let tok = try WordPieceTokenizer(vocabURL: vocabURL)
        let (ids, mask) = tok.encode("hello", maxLength: 128)
        #expect(ids.count == 128)
        #expect(mask.count == 128)

        let idsArr = try MLMultiArray(shape: [1, 128], dataType: .int32)
        let maskArr = try MLMultiArray(shape: [1, 128], dataType: .int32)
        for i in 0..<128 {
            idsArr[i] = NSNumber(value: Int32(ids[i]))
            maskArr[i] = NSNumber(value: Int32(mask[i]))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": idsArr,
            "attention_mask": maskArr,
        ])

        let output = try await model.prediction(from: input)
        guard let firstName = output.featureNames.first,
              let outArr = output.featureValue(for: firstName)?.multiArrayValue
        else {
            Issue.record("model produced no multi-array output")
            return
        }
        let count = outArr.count
        var vec = [Float](repeating: 0, count: count)
        for i in 0..<count { vec[i] = outArr[i].floatValue }
        #expect(count == 384)

        // Load the first reference vector ("hello") from tests/replay/.
        let refURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // MemoryV2Tests
            .deletingLastPathComponent()       // Tests
            .deletingLastPathComponent()       // NativeAgentCore
            .deletingLastPathComponent()       // Modules
            .deletingLastPathComponent()       // NativeAgent (project root)
            .appendingPathComponent("tests/replay/minilm_reference_vectors.json")
        let data = try Data(contentsOf: refURL)
        let ref = try JSONDecoder().decode(RefPayload.self, from: data)
        guard let sample = ref.samples.first, sample.text == "hello" else {
            Issue.record("reference file missing 'hello' as first sample")
            return
        }

        // Cosine: both vectors are already L2-normalized → dot product.
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<min(vec.count, sample.embedding.count) {
            dot += vec[i] * sample.embedding[i]
            na += vec[i] * vec[i]
            nb += sample.embedding[i] * sample.embedding[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        let cos = denom > 0 ? dot / denom : 0
        #expect(cos >= 0.9999, "cosine drift too high: \(cos)")
    }
}

// MARK: - A2.4: model floor must not outrun the app floor

@Suite("CoreML MiniLM deployment floor")
struct CoreMLEmbedderDeploymentFloorTests {
    @Test("bundled mlmodel spec version stays loadable on the app's minimum macOS")
    func bundledSpecVersionMatchesAppFloor() throws {
        // The app ships with LSMinimumSystemVersion 26.0 and CoreML spec
        // version 8 is the newest macOS 14 can load. A regenerated model
        // built with newer coremltools defaults (spec 9+ → macOS 15) would
        // pass every test on a current dev Mac and then fail to load for
        // every user still on the app's declared floor — exactly the
        // "red Doctor item on some macOS versions" class this pins away.
        guard let pkgURL = Bundle.module.url(
            forResource: "minilm", withExtension: "mlpackage"
        ) else {
            Issue.record("minilm.mlpackage not present in Bundle.module")
            return
        }
        let modelURL = pkgURL
            .appendingPathComponent("Data")
            .appendingPathComponent("com.apple.CoreML")
            .appendingPathComponent("model.mlmodel")
        let data = try Data(contentsOf: modelURL)
        // Protobuf: field 1 (specificationVersion) as a varint — tag byte
        // 0x08 followed by the version. Spec versions are single-digit, so
        // one varint byte is sufficient and unambiguous here.
        try #require(data.count >= 2)
        try #require(data[0] == 0x08)
        let specificationVersion = Int(data[1])
        #expect(specificationVersion <= 8)
    }
}
