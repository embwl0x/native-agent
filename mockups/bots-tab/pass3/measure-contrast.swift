import AppKit

// Sample an interior rectangle of the rendered selected segment, in PNG pixels.
// Exclude the rounded edge. The modal non-ink color is the composited fill.
// The darkest (dark appearance) or brightest (light appearance) pixel is
// the lettering core. The lamp gradient means core pixels need not repeat.
let args = CommandLine.arguments
guard args.count == 6,
      let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let bitmap = NSBitmapImageRep(data: data),
      let x = Int(args[2]), let y = Int(args[3]),
      let width = Int(args[4]), let height = Int(args[5]) else {
    fatalError("Usage: swift measure-contrast.swift image.png x y width height")
}
var counts: [Int: Int] = [:]
for row in y..<(y + height) {
    for column in x..<(x + width) {
        let color = bitmap.colorAt(x: column, y: row)!.usingColorSpace(.sRGB)!
        precondition(color.alphaComponent > 0.999, "Expected opaque composited pixels")
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
            .map { Int(($0 * 255).rounded()) }
        counts[(rgb[0] << 16) | (rgb[1] << 8) | rgb[2], default: 0] += 1
    }
}
func luminance(_ rgb: Int) -> Double {
    let linear = [16, 8, 0].map { shift -> Double in
        let channel = Double((rgb >> shift) & 255) / 255
        return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
}
let dark = args[1].contains("-dark.png")
let ink = counts.max {
    dark ? luminance($0.key) > luminance($1.key) : luminance($0.key) < luminance($1.key)
}!.key
let fill = counts.filter { $0.key != ink }.max { $0.value < $1.value }!.key
let ratio = (max(luminance(ink), luminance(fill)) + 0.05)
    / (min(luminance(ink), luminance(fill)) + 0.05)
print(String(format: "fill #%06X (%d pixels), ink #%06X (%d pixels), contrast %.2f:1",
             fill, counts[fill]!, ink, counts[ink]!, ratio))
