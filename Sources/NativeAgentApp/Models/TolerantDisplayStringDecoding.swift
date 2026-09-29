import Foundation
import EngineRuntime

func decodeTolerantDisplayString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
    EngineRuntime.decodeTolerantDisplayString(container, key)
}
