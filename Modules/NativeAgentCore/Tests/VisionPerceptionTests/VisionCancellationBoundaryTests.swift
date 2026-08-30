import CoreGraphics
import Foundation
import Testing
@testable import VisionPerception

@Suite("Vision cancellation boundaries")
struct VisionCancellationBoundaryTests {
    @Test func cancelledOCRStopsAtTheCurrentPass() async {
        for mode in [CancellationTextRecognizer.Mode.throwAt(2), .cancelAt(1), .cancelAt(2), .cancelAt(10)] {
            let recognizer = CancellationTextRecognizer(mode: mode)
            let task = Task {
                let image = try #require(Scene.context(width: 400, height: 800).makeImage())
                return try VisionTextLayer.recognize(image: image, using: recognizer)
            }
            switch await task.result {
            case .success: Issue.record("Cancelled OCR must not return a partial successful frame")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(recognizer.callCount == mode.stopCall)
        }
    }

    @Test func cancellationBeforeCompileDoesNoOCRWork() async {
        let recognizer = CancellationTextRecognizer(mode: .ordinaryTileFailure)
        let task = Task {
            let image = try #require(Scene.context(width: 400, height: 800).makeImage())
            withUnsafeCurrentTask { $0?.cancel() }
            return try VisionPerceptionCompiler().compile(image: image, using: recognizer)
        }
        switch await task.result {
        case .success: Issue.record("An already cancelled compile must not publish")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(recognizer.callCount == 0)
    }

    @Test func saliencyCancellationNeverPublishesButOrdinaryFailuresRemainPartial() async throws {
        for mode in [CancellationSalience.Mode.throwCancellation, .cancelAndReturn] {
            let task = Task {
                let image = try #require(Scene.context(width: 400, height: 800).makeImage())
                return try VisionPerceptionCompiler(salience: CancellationSalience(mode: mode)).compile(
                    image: image, using: CancellationTextRecognizer(mode: .ordinaryTileFailure)
                )
            }
            switch await task.result {
            case .success: Issue.record("Cancelled saliency must not publish text/colour as a complete frame")
            case .failure(let error): #expect(error is CancellationError)
            }
        }

        let image = try #require(Scene.context(width: 400, height: 800).makeImage())
        let recognizer = CancellationTextRecognizer(mode: .ordinaryTileFailure)
        let text = try VisionTextLayer.recognize(image: image, using: recognizer)
        #expect(text.tileFailures == 9)
        #expect(text.boxes.count == 1)
        #expect(recognizer.callCount == 10)
        let percept = try VisionPerceptionCompiler(salience: CancellationSalience(mode: .ordinaryFailure)).compile(
            image: image, using: recognizer
        )
        #expect(percept.recognizedStrings == 1)
        #expect(percept.notes.contains { $0.contains("9 OCR tile pass(es) failed") })
    }
}

private final class CancellationTextRecognizer: VisionTextRecognizing, @unchecked Sendable {
    enum Mode: Sendable {
        case throwAt(Int), cancelAt(Int), ordinaryTileFailure
        var stopCall: Int {
            switch self {
            case .throwAt(let call), .cancelAt(let call): call
            case .ordinaryTileFailure: 10
            }
        }
    }
    let mode: Mode
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    init(mode: Mode) { self.mode = mode }

    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        let call = lock.withLock { calls += 1; return calls }
        switch mode {
        case .throwAt(let stop) where call == stop: throw CancellationError()
        case .cancelAt(let stop) where call == stop: withUnsafeCurrentTask { $0?.cancel() }
        case .ordinaryTileFailure where region != nil: throw FixtureFailure()
        default: break
        }
        return region == nil ? [VisionTextBox(
            text: "tiny", rect: VisionRect(x: 10, y: 10, w: 40, h: 5), confidence: 0.9
        )] : []
    }
}

private struct FixtureFailure: Error {}

private struct CancellationSalience: VisionSalienceProviding {
    enum Mode: Sendable { case throwCancellation, cancelAndReturn, ordinaryFailure }
    let mode: Mode
    func salientRegions(in image: CGImage) throws -> [(rect: VisionRect, score: Double)] {
        switch mode {
        case .throwCancellation: throw CancellationError()
        case .cancelAndReturn:
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        case .ordinaryFailure: throw FixtureFailure()
        }
    }
}
