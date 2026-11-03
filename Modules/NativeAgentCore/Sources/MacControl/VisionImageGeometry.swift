import CoreGraphics
import Foundation
import ImageIO
import CoreMedia
import Experiences
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Senses
import Synchronization
// Blueprint: | `VisionImageGeometry.swift` | Owned image decoding and geometry-preserving crops; no-region requests keep the whole image, invalid or failed requested crops return unavailable |

/// Decode the fused Mac view into an owned bitmap.
public enum VisionImageDecoder {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let lazy = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Own the bitmap so Vision never reads released ImageIO backing.
        guard let context = CGContext(
            data: nil, width: lazy.width, height: lazy.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(lazy, in: CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
        return context.makeImage()
    }
}

public struct VisionImageCrop {
    public let image: CGImage
    public let origin: (x: Double, y: Double)
    public let logicalSize: (width: Double, height: Double)
}

/// Crop to the AX-located visual surface, preserving global hand coordinates.
public enum VisionImageCropper {
    public static func crop(
        _ image: CGImage,
        to globalFrame: MacAXFrame?,
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double)
    ) -> VisionImageCrop? {
        guard let globalFrame else {
            return VisionImageCrop(image: image, origin: origin, logicalSize: logicalSize)
        }
        guard [origin.x, origin.y, logicalSize.width, logicalSize.height,
               globalFrame.x, globalFrame.y, globalFrame.w, globalFrame.h].allSatisfy(\.isFinite),
              logicalSize.width > 0, logicalSize.height > 0,
              globalFrame.w > 0, globalFrame.h > 0 else { return nil }
        let geometry = MacScreenViewGeometry(bounds: MacAXFrame(x: origin.x, y: origin.y,
            w: logicalSize.width, h: logicalSize.height), pixelWidth: image.width, pixelHeight: image.height)
        let rect = geometry.imageRect(globalFrame)
        guard [rect.x, rect.y, rect.w, rect.h].allSatisfy(\.isFinite), rect.w > 0, rect.h > 0 else { return nil }
        let requested = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h).integral
        let available = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = requested.intersection(available)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = image.cropping(to: clipped) else {
            return nil
        }
        let frame = geometry.screenRect(VisionRect(x: clipped.minX, y: clipped.minY, w: clipped.width, h: clipped.height))
        return VisionImageCrop(image: cropped, origin: (frame.x, frame.y), logicalSize: (frame.w, frame.h))
    }
}
