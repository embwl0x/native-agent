import PersistenceCore

package struct ExternalSendPreparedInput: Sendable {
    package let input: [String: JSONValue]
    package let destinationCount: Int
    package let contentByteCount: Int

    package init(input: [String: JSONValue], destinationCount: Int, contentByteCount: Int) {
        self.input = input
        self.destinationCount = destinationCount
        self.contentByteCount = contentByteCount
    }
}
