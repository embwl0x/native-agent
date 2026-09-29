import Foundation

extension JSONDecoder {
    public static var nativeAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension URL {
    public func appendingNativeRelativePath(_ relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(self) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }
}
