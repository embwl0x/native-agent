import AppKit
import Foundation
import Testing

@Test func staticMacSystemSymbolNamesResolve() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceRoot = repoRoot.appendingPathComponent("Sources/NativeAgentApp", isDirectory: true)
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    )
    let regex = try NSRegularExpression(
        pattern: #"(?:systemName|systemImage):\s*"([^"]+)""#
    )
    var invalid: [String] = []

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange])
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                invalid.append("\(fileURL.lastPathComponent): \(name)")
            }
        }
    }

    #expect(invalid.sorted().isEmpty, "Invalid static SF Symbols: \(invalid.sorted())")
}
