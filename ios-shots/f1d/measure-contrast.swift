import Foundation
import CoreGraphics
import ImageIO

// Read captured, composited pixels through an explicit sRGB context.
// Arguments: PNG, x0 y0 x1 y1, expected ink hex, adjacent background x y.
let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1])
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}
func rgb(_ x: Int, _ y: Int) -> Int {
    let i = (y * w + x) * 4
    return Int(pixels[i]) << 16 | Int(pixels[i + 1]) << 8 | Int(pixels[i + 2])
}
func channels(_ c: Int) -> [Double] { [16, 8, 0].map { Double((c >> $0) & 255) } }
let expected = Int(a[6], radix: 16)
var counts: [Int: Int] = [:]
for y in Int(Double(a[3])! * Double(h))..<Int(Double(a[5])! * Double(h)) {
    for x in Int(Double(a[2])! * Double(w))..<Int(Double(a[4])! * Double(w)) {
        let c = rgb(x, y)
        let rgb = channels(c)
        let matches = expected.map { target in
            zip(rgb, channels(target)).allSatisfy { abs($0 - $1) <= 5 }
        } ?? (rgb[1] - rgb[0] > 25 && rgb[2] - rgb[0] > 25)
        if matches {
            counts[c, default: 0] += 1
        }
    }
}
guard let ink = counts.max(by: { $0.value < $1.value }) else {
    print("No solid ink pixels in selected region")
    exit(1)
}
let bx = Int(Double(a[7])! * Double(w)), by = Int(Double(a[8])! * Double(h))
let background = rgb(bx, by)
func luminance(_ c: Int) -> Double {
    let linear = channels(c).map { v -> Double in
        let s = v / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
}
let l1 = luminance(ink.key), l2 = luminance(background)
print(String(format: "%@ ink #%06X (%d pixels), background #%06X at (%d,%d), %.2f:1",
             url.lastPathComponent, ink.key, ink.value, background, bx, by,
             (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)))
