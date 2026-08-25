import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`, rows `ios.settings.pushReceiptCapacity`
/// and `ios.settings.pushDeliveriesSection`.
///
/// Silent-failure class: DROPPED ROW. The receipt ledger is the ONLY evidence
/// that splits "APNS delivered it and the phone silenced it" from "it never
/// arrived". The store keeps a bounded window and the Settings section renders
/// a smaller prefix of that window; if eviction ever runs from the wrong end,
/// the debugging surface quietly shows the WRONG pushes and still looks healthy.
final class PushReceiptLedgerEvalTests: XCTestCase {

    private let key = "NativeAgentMobile.pushReceipts"
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    @discardableResult
    private func record(_ index: Int) -> PushReceiptEntry {
        PushReceiptLedger.record(userInfo: [
            "source": "inbox",
            "screen": "activity",
            "itemId": "card-\(index)",
        ])
    }

    func test_theLedgerIsBoundedAndEvictsTheOLDESTReceiptsFirst() {
        for index in 0..<40 { record(index) }

        let entries = PushReceiptLedger.load()
        XCTAssertLessThan(entries.count, 40, "the ledger is unbounded — it would grow without limit in UserDefaults")
        XCTAssertGreaterThan(entries.count, 1, "the ledger kept almost nothing; a burst would erase its own evidence")

        let ids = entries.map(\.itemId)
        XCTAssertEqual(ids.first, "card-39", "the newest push is not at the head — the section would show stale receipts")
        XCTAssertEqual(
            ids, (0..<entries.count).map { "card-\(39 - $0)" },
            "the retained window is not the contiguous NEWEST run; eviction ran from the wrong end"
        )
    }

    func test_theSettingsSectionRendersFewerReceiptsThanTheLedgerRetains() throws {
        for index in 0..<40 { record(index) }
        let capacity = PushReceiptLedger.load().count

        let settings = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let prefixes = MobileEvalSources.matches(
            #"ForEach\(pushReceipts\.prefix\((\d+)\)"#,
            in: settings
        ).compactMap(Int.init)
        guard let rendered = prefixes.first else {
            return XCTFail("SettingsViewFull no longer renders its observable push receipt state")
        }

        XCTAssertLessThanOrEqual(
            rendered, capacity,
            "the section claims to render \(rendered) receipts but the ledger only retains \(capacity)"
        )
        XCTAssertGreaterThan(rendered, 0)
    }

    func test_aRecordedReceiptNotifiesTheVisibleSettingsState() throws {
        let updated = expectation(description: "receipt change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: PushReceiptLedger.didChange,
            object: nil,
            queue: .main
        ) { _ in
            XCTAssertEqual(PushReceiptLedger.load().map(\.itemId), ["card-7"])
            updated.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        record(7)
        wait(for: [updated], timeout: 1)

        let settings = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        XCTAssertTrue(settings.contains("@State private var pushReceipts = PushReceiptLedger.load()"))
        XCTAssertTrue(settings.contains("NotificationCenter.default.publisher(for: PushReceiptLedger.didChange)"))
        XCTAssertTrue(settings.contains("pushReceipts = PushReceiptLedger.load()"))
        XCTAssertTrue(settings.contains("ForEach(pushReceipts.prefix(8))"))
    }

    func test_aReceiptWithNoUsefulFieldsStillRecordsRatherThanBeingDropped() {
        // Absence of a receipt is the load-bearing signal ("APNS never reached
        // the app"). A malformed payload must NOT be able to fake that absence.
        let entry = PushReceiptLedger.record(userInfo: [:])
        XCTAssertEqual(entry.source, "unknown")
        XCTAssertEqual(entry.screen, "")
        XCTAssertEqual(entry.itemId, "")
        XCTAssertFalse(entry.id.isEmpty, "a fieldless receipt produced an empty Identifiable id — the row would collide in the List")
        XCTAssertEqual(PushReceiptLedger.load().count, 1)
    }

    func test_aCorruptLedgerBlobReadsAsEmptyAndTheNextPushRepairsIt() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        XCTAssertTrue(PushReceiptLedger.load().isEmpty)

        record(1)
        XCTAssertEqual(PushReceiptLedger.load().map(\.itemId), ["card-1"])
    }
}
