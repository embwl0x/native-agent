import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.turninspector.perTurnMetrics`.
///
/// Every Mac-published turn has the same compact metric contract on iPhone:
/// event count, elapsed wall time, token count, and time-to-first-token.
final class TurnInspectorPerTurnMetricsEvalTests: XCTestCase {
    func test_publishedTurnRendersEveryMetricWithItsUnit() throws {
        let summary = try decode(#"""
        {
          "id": "turn-complete",
          "startedAt": "2026-08-24T12:00:00Z",
          "lastAt": "2026-08-24T12:00:01Z",
          "eventCount": 7,
          "wallMs": 1500,
          "llmTokens": 123,
          "ttftMs": 80
        }
        """#)

        XCTAssertEqual(
            TurnInspectorPresentation.metrics(for: summary).map { "\($0.label)=\($0.value)" },
            ["events=7", "wall=1.5 s", "tok=123", "ttft=80 ms"]
        )
    }

    func test_invalidMeasurementsNeverRenderAsNegativeMetrics() throws {
        let summary = try decode(#"""
        {
          "id": "turn-incomplete",
          "startedAt": "2026-08-24T12:00:00Z",
          "lastAt": "2026-08-24T12:00:01Z",
          "eventCount": -1,
          "wallMs": -1,
          "llmTokens": -2,
          "ttftMs": -3
        }
        """#)

        XCTAssertEqual(
            TurnInspectorPresentation.metrics(for: summary).map { "\($0.label)=\($0.value)" },
            ["events=Unknown", "wall=Unknown", "tok=Unknown", "ttft=Unknown"]
        )
    }

    private func decode(_ record: String) throws -> TurnSummaryRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TurnSummaryRecord.self, from: Data(record.utf8))
    }
}
