import Foundation

actor TelegramProgressMessageState {
    private let maxMessages: Int
    private var sent: Set<String> = []

    init(maxMessages: Int) {
        self.maxMessages = max(0, maxMessages)
    }

    func shouldSend(_ text: String) -> Bool {
        guard sent.count < maxMessages, !sent.contains(text) else { return false }
        sent.insert(text)
        return true
    }
}
