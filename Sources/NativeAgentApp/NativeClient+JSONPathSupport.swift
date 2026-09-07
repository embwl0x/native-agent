import Foundation
import PersistenceCore


extension NativeClient {
    static func foundationDictionary(_ value: JSONValue) throws -> [String: Any] {
        let data = try value.serializedData(pretty: false)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

}
