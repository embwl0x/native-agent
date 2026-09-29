import UIKit

enum MobileChatAttachmentPreparation {
    static let payloadBudgetBytes = 520 * 1024

    @MainActor
    static func preparedJPEGData(from image: UIImage, maxDimension: CGFloat = 1400,
                                 maxBytes: Int = payloadBudgetBytes) -> Data? {
        guard maxBytes > 0 else { return nil }
        let sourceSize = image.size
        let sourceLongest = max(sourceSize.width, sourceSize.height)
        var dimension = min(maxDimension, sourceLongest)
        // Small shared icons should also be encodable without upscaling.
        while dimension > 0 {
            let scale = sourceLongest > dimension ? dimension / sourceLongest : 1
            let targetSize = CGSize(width: max(1, sourceSize.width * scale),
                                    height: max(1, sourceSize.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let normalized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            for quality in [0.78, 0.66, 0.54, 0.42, 0.32, 0.24] {
                if let data = normalized.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
            }
            guard dimension > 320 else { return nil }
            dimension = max(320, dimension * 0.78)
        }
        return nil
    }
}
