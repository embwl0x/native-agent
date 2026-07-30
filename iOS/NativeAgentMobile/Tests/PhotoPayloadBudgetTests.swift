import XCTest
import UIKit
@testable import NativeAgentMobile

@MainActor
final class PhotoPayloadBudgetTests: XCTestCase {
    func testAggregateBudgetIsSharedAcrossRemainingPhotos() {
        let total = ChatView.cloudKitPhotoPayloadBudgetBytes
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: total, remainingCount: 4), total / 4)
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: 0, remainingCount: 1), 0)
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: total, remainingCount: 0), 0)
    }

    func testJPEGPreparationHonorsEncodedTransportBudget() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
            UIColor.systemPink.setFill()
            for index in 0..<80 {
                let offset = CGFloat(index * 29)
                context.cgContext.fill(CGRect(x: offset, y: offset / 2, width: 160, height: 90))
            }
        }
        let budget = ChatView.cloudKitPhotoPayloadBudgetBytes / 4
        let data = ChatView.preparedJPEGData(from: image, maxBytes: budget)
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? .max, budget)
    }

    func testJPEGPreparationRejectsImpossibleBudget() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
            .image { context in
                UIColor.black.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
            }
        XCTAssertNil(ChatView.preparedJPEGData(from: image, maxBytes: 1))
    }
}
