import CoreGraphics
import Foundation
import NativeAgentCore
import Senses
import CoreMedia
import Experiences
import PersistenceCore
import ScreenCaptureKit
import Synchronization
// Blueprint: | `MacScreenWatch+FrameQueries.swift` | `MacScreenWatch.read`: generation-bound pixel colour, mean, change and redacted text queries; admitted reads publish only while open under the same secret verdict |

extension MacScreenWatch {
    /// Native answers about the newest frame, in its pixels: `{at:[x,y]}` its
    /// exact colour, `{mean:[x,y,w,h]}` the mean colour and luminance,
    /// `{changed:[x,y,w,h]}` the share of pixels that changed against the
    /// frame before, `{text:[x,y,w,h]}` the text there, the whole frame read
    /// on device and redacted as one picture. A frame a newer one replaced, or
    /// of another watch, has expired; it is never answered by a newer one.
    public func read(watch: Int, seq: Int, queries: [JSONValue]) async throws -> JSONValue {
        guard admitOperation() else { throw over ?? CancellationError() }
        defer { finishOperation() }
        func bad() -> SenseFailure {
            SenseFailure(code: "bad_input", message: "frame.read takes 1 to 1024 queries, each {at:[x,y]}, {mean:[x,y,w,h]}, {changed:[x,y,w,h]} or {text:[x,y,w,h]}, in this frame's pixels.")
        }
        guard await allowed() else { throw over ?? bad() }
        guard watch == generation, let (frame, painted) = lock.withLock({ newest.flatMap { $0.seq == seq ? ($0, verdict) : nil } }) else {
            throw SenseFailure(code: "expired", message: "That frame has been replaced; read the frame screen.next() returns.")
        }
        guard (1...1024).contains(queries.count) else { throw bad() }
        var answers: [JSONValue] = [], recognized: [VisionRecognizedText]?
        for query in queries {
            try Task.checkCancellation()
            guard case .object(let fields) = query, fields.count == 1, let (kind, value) = fields.first,
                  case .array(let raw) = value, case let n = raw.compactMap({ Self.number($0).flatMap { abs($0) < 1e9 ? Int($0.rounded(.down)) : nil } }),
                  n.count == raw.count else { throw bad() }
            if kind == "at", n.count == 2 {
                guard (0..<width).contains(n[0]), (0..<height).contains(n[1]) else { throw bad() }
                let at = (n[1] * width + n[0]) * 4
                answers.append(.object(["r": .int(Int64(frame.pixels[at + 2])), "g": .int(Int64(frame.pixels[at + 1])),
                                        "b": .int(Int64(frame.pixels[at]))]))
                continue
            }
            guard ["mean", "changed", "text"].contains(kind), n.count == 4, n[2] > 0, n[3] > 0 else { throw bad() }
            let x0 = max(0, n[0]), y0 = max(0, n[1]), x1 = min(width, n[0] + n[2]), y1 = min(height, n[1] + n[3])
            guard x0 < x1, y0 < y1 else { throw bad() }
            if kind == "text" {
                // Redaction judges a caption and its value together, so the whole
                // frame is recognised once; only the lines inside the region return.
                if recognized == nil {
                    guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData),
                          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw bad() }
                    recognized = try await MacAppWindowText.recognize(image: image)
                }
                let lines = (recognized ?? []).compactMap { row -> String? in
                    guard let text = row.text.display, let box = row.rect else { return nil }
                    let cx = box.x + box.w / 2, cy = box.y + box.h / 2
                    return cx >= Double(x0) && cx < Double(x1) && cy >= Double(y0) && cy < Double(y1) ? text : nil
                }
                answers.append(.object(["text": .string(lines.joined(separator: "\n"))]))
                continue
            }
            if kind == "changed", frame.prior == nil { answers.append(.object(["changed": .null])); continue }
            var sum = (r: 0, g: 0, b: 0), changed = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let at = (y * width + x) * 4
                    if kind == "mean" {
                        sum.b += Int(frame.pixels[at]); sum.g += Int(frame.pixels[at + 1]); sum.r += Int(frame.pixels[at + 2])
                    } else if let prior = frame.prior,
                              // A small threshold leaves encoder noise out.
                              max(abs(Int(frame.pixels[at]) - Int(prior[at])), abs(Int(frame.pixels[at + 1]) - Int(prior[at + 1])),
                                  abs(Int(frame.pixels[at + 2]) - Int(prior[at + 2]))) > 24 { changed += 1 }
                }
            }
            let count = Double((x1 - x0) * (y1 - y0))
            if kind == "changed" {
                answers.append(.object(["changed": .double((Double(changed) / count * 1000).rounded() / 1000)]))
            } else {
                let r = Double(sum.r) / count, g = Double(sum.g) / count, b = Double(sum.b) / count
                answers.append(.object(["r": .int(Int64(r.rounded())), "g": .int(Int64(g.rounded())), "b": .int(Int64(b.rounded())),
                                        "l": .int(Int64((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))]))
            }
        }
        // Answered only while the watch is open and the secret fields it was
        // painted under still stand; a newer frame arriving meanwhile is fine.
        try Task.checkCancellation()
        guard lock.withLock({ () -> Bool in
            guard ended == nil, verdict == painted else { return false }
            self.queries += queries.count
            return true
        }) else { throw SenseFailure(code: "expired", message: "That frame has been replaced; read the frame screen.next() returns.") }
        return .array(answers)
    }

}
