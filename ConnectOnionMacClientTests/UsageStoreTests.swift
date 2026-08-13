import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

final class UsageStoreTests: XCTestCase {
    @MainActor
    func testAggregatesByLocalDayAndModelAcrossEveryRange() throws {
        let fixture = try makeFixture(now: "2026-01-31T12:00:00+11:00")
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        fixture.store.record(
            makeRecord(
                id: "today-a",
                timestamp: fixture.now,
                model: "model-a",
                input: 100,
                output: 20
            )
        )
        fixture.store.record(
            makeRecord(
                id: "six-days-a",
                timestamp: try date(
                    "2026-01-25T09:00:00+11:00"
                ),
                model: "model-a",
                input: 50,
                output: 10
            )
        )
        fixture.store.record(
            makeRecord(
                id: "seven-days-b",
                timestamp: try date(
                    "2026-01-24T09:00:00+11:00"
                ),
                model: "model-b",
                input: 25,
                output: 5
            )
        )
        fixture.store.record(
            makeRecord(
                id: "twenty-nine-days-b",
                timestamp: try date(
                    "2026-01-02T09:00:00+11:00"
                ),
                model: "model-b",
                input: 10,
                output: 2
            )
        )
        fixture.store.record(
            makeRecord(
                id: "previous-year",
                timestamp: try date(
                    "2025-12-31T23:00:00+11:00"
                ),
                model: "model-c",
                input: 4,
                output: 1
            )
        )

        let today = fixture.store.snapshot(for: .today)
        XCTAssertEqual(today.totals, UsageTotals(inputTokens: 100, outputTokens: 20, calls: 1))

        let last7Days = fixture.store.snapshot(for: .last7Days)
        XCTAssertEqual(last7Days.totals, UsageTotals(inputTokens: 150, outputTokens: 30, calls: 2))
        XCTAssertEqual(last7Days.models.map(\.model), ["model-a"])

        let last30Days = fixture.store.snapshot(for: .last30Days)
        XCTAssertEqual(
            last30Days.totals,
            UsageTotals(inputTokens: 185, outputTokens: 37, calls: 4)
        )
        XCTAssertEqual(last30Days.models.map(\.model), ["model-a", "model-b"])

        let allTime = fixture.store.snapshot(for: .allTime)
        XCTAssertEqual(
            allTime.totals,
            UsageTotals(inputTokens: 189, outputTokens: 38, calls: 5)
        )
        XCTAssertEqual(allTime.models.map(\.model), ["model-a", "model-b", "model-c"])
    }

    @MainActor
    func testDeduplicatesPersistsAndClearKeepsReplayBarrier() throws {
        let fixture = try makeFixture(now: "2026-02-01T12:00:00+11:00")
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let record = makeRecord(
            id: "stable-call",
            timestamp: fixture.now,
            model: "model-a",
            input: 10,
            output: 3
        )

        fixture.store.record(record)
        fixture.store.record(record)
        XCTAssertEqual(fixture.store.snapshot(for: .allTime).totals.calls, 1)

        var reloaded = UsageStore(
            fileURL: fixture.fileURL,
            calendar: fixture.calendar,
            now: { fixture.now }
        )
        XCTAssertEqual(reloaded.snapshot(for: .allTime).totals.totalTokens, 13)
        reloaded.record(record)
        XCTAssertEqual(reloaded.snapshot(for: .allTime).totals.calls, 1)

        reloaded.clearHistory()
        XCTAssertEqual(reloaded.snapshot(for: .allTime).totals, UsageTotals())
        XCTAssertNil(reloaded.snapshot(for: .allTime).recordingSince)

        reloaded = UsageStore(
            fileURL: fixture.fileURL,
            calendar: fixture.calendar,
            now: { fixture.now }
        )
        reloaded.record(record)
        XCTAssertEqual(reloaded.snapshot(for: .allTime).totals.calls, 0)

        reloaded.record(
            makeRecord(
                id: "new-call",
                timestamp: fixture.now,
                model: "model-a",
                input: 1,
                output: 1
            )
        )
        XCTAssertEqual(reloaded.snapshot(for: .allTime).totals.calls, 1)
        XCTAssertNotNil(reloaded.snapshot(for: .allTime).recordingSince)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testUsesInjectedCalendarAtLocalMidnightBoundary() throws {
        let fixture = try makeFixture(now: "2026-01-02T12:00:00+11:00")
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        fixture.store.record(
            makeRecord(
                id: "before-midnight",
                timestamp: try date("2026-01-01T12:30:00Z"),
                model: "model-a",
                input: 10,
                output: 0
            )
        )
        fixture.store.record(
            makeRecord(
                id: "after-midnight",
                timestamp: try date("2026-01-01T13:30:00Z"),
                model: "model-a",
                input: 20,
                output: 0
            )
        )

        XCTAssertEqual(
            fixture.store.snapshot(for: .today).totals,
            UsageTotals(inputTokens: 20, outputTokens: 0, calls: 1)
        )
    }

    func testTraceParserSupportsAliasesModelsTimestampsAndZeroTokenCalls() throws {
        let agentAddress = "0x" + String(repeating: "ab", count: 32)
        let now = try date("2026-03-03T10:00:00Z")
        let payload: [String: Any] = [
            "session": [
                "trace": [
                    [
                        "type": "llm_call",
                        "id": "call-a",
                        "model": "model-from-call"
                    ],
                    [
                        "type": "llm_result",
                        "id": "call-a",
                        "timestamp": "2026-03-01T01:02:03.456Z",
                        "usage": [
                            "prompt_tokens": 12,
                            "completion_tokens": 4
                        ]
                    ],
                    [
                        "type": "llm_result",
                        "id": "call-b",
                        "model": "model-from-result",
                        "timestamp": 1_772_500_000_000,
                        "usage": [
                            "input_tokens": 7,
                            "output_tokens": 2
                        ]
                    ],
                    [
                        "type": "llm_result",
                        "usage": [
                            "input_tokens": 0,
                            "output_tokens": 0
                        ]
                    ]
                ]
            ]
        ]

        let records = ConnectOnionRemoteAgentClient.makeUsageRecords(
            from: payload,
            agentAddress: agentAddress,
            remoteSessionID: "session-1",
            fallbackModel: "host-model",
            now: now
        )

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].model, "model-from-call")
        XCTAssertEqual(records[0].inputTokens, 12)
        XCTAssertEqual(records[0].outputTokens, 4)
        XCTAssertEqual(
            records[0].timestamp,
            try date("2026-03-01T01:02:03.456Z")
        )
        XCTAssertEqual(records[1].model, "model-from-result")
        XCTAssertEqual(records[1].inputTokens, 7)
        XCTAssertEqual(records[1].outputTokens, 2)
        XCTAssertEqual(records[2].model, "model-from-call")
        XCTAssertEqual(records[2].totalTokens, 0)
        XCTAssertEqual(Set(records.map(\.id)).count, 3)
    }

    func testLiveAndFinalTraceProduceTheSameStableCallID() throws {
        let agentAddress = "0x" + String(repeating: "cd", count: 32)
        let event: [String: Any] = [
            "type": "llm_result",
            "id": "call-42",
            "usage": ["input_tokens": 8, "output_tokens": 3]
        ]
        let payload: [String: Any] = [
            "session": [
                "trace": [
                    [
                        "type": "llm_call",
                        "id": "call-42",
                        "model": "model-a"
                    ],
                    event
                ]
            ]
        ]

        let live = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeLiveUsageRecord(
                from: event,
                agentAddress: agentAddress,
                remoteSessionID: "session-42",
                fallbackModel: "model-a"
            )
        )
        let final = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeUsageRecords(
                from: payload,
                agentAddress: agentAddress,
                remoteSessionID: "session-42",
                fallbackModel: nil
            ).first
        )

        XCTAssertEqual(live.id, final.id)
        XCTAssertEqual(live.model, final.model)
    }

    func testModelFallbackAndHeatmapIntensityBuckets() throws {
        let event: [String: Any] = [
            "type": "llm_result",
            "id": "call-1",
            "usage": [:]
        ]
        let record = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeLiveUsageRecord(
                from: event,
                agentAddress: "agent",
                remoteSessionID: "session",
                fallbackModel: "  host-model  "
            )
        )
        XCTAssertEqual(record.model, "host-model")

        XCTAssertEqual(UsageHeatmapScale.intensity(tokens: 0, maximumTokens: 100), 0)
        XCTAssertEqual(UsageHeatmapScale.intensity(tokens: 1, maximumTokens: 10_000), 1)
        XCTAssertGreaterThanOrEqual(
            UsageHeatmapScale.intensity(tokens: 100, maximumTokens: 10_000),
            1
        )
        XCTAssertEqual(
            UsageHeatmapScale.intensity(tokens: 10_000, maximumTokens: 10_000),
            4
        )
    }

    @MainActor
    func testRemovingPersistedChatDataDoesNotDeleteUsageHistory() throws {
        let fixture = try makeFixture(now: "2026-04-01T12:00:00+11:00")
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        fixture.store.record(
            makeRecord(
                id: "retained-call",
                timestamp: fixture.now,
                model: "model-a",
                input: 1_000,
                output: 100
            )
        )

        let suiteName = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = ChatSession(
            agentConfigId: UUID(),
            title: "Chat"
        )
        defaults.set(
            try JSONEncoder().encode([session]),
            forKey: "saved_sessions"
        )
        defaults.set(
            try JSONEncoder().encode([ChatSession]()),
            forKey: "saved_sessions"
        )
        let reloadedStore = UsageStore(
            fileURL: fixture.fileURL,
            calendar: fixture.calendar,
            now: { fixture.now }
        )

        XCTAssertEqual(reloadedStore.snapshot(for: .allTime).totals.calls, 1)
    }

    @MainActor
    func testUsageViewRendersAtWideAndNarrowSizes() throws {
        let fixture = try makeFixture(now: "2026-04-01T12:00:00+11:00")
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        fixture.store.record(
            makeRecord(
                id: "call",
                timestamp: fixture.now,
                model: "model-a",
                input: 1_000,
                output: 100
            )
        )

        XCTAssertEqual(fixture.store.snapshot(for: .allTime).totals.calls, 1)

        for (width, scheme) in [
            (920.0, ColorScheme.light),
            (620.0, ColorScheme.dark)
        ] {
            let hostingView = NSHostingView(
                rootView: UsageView(store: fixture.store, onClose: {})
                    .environment(\.colorScheme, scheme)
                    .frame(width: width, height: 760)
            )
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 760)
            hostingView.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
            XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        }
    }

    private struct Fixture {
        let directoryURL: URL
        let fileURL: URL
        let calendar: Calendar
        let now: Date
        let store: UsageStore
    }

    @MainActor
    private func makeFixture(now value: String) throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)")
        let fileURL = directoryURL.appendingPathComponent("usage-v1.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let now = try date(value)
        let store = UsageStore(
            fileURL: fileURL,
            calendar: calendar,
            now: { now }
        )
        return Fixture(
            directoryURL: directoryURL,
            fileURL: fileURL,
            calendar: calendar,
            now: now,
            store: store
        )
    }

    private func makeRecord(
        id: String,
        timestamp: Date,
        model: String,
        input: Int,
        output: Int
    ) -> LLMUsageRecord {
        LLMUsageRecord(
            id: id,
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputTokens: output,
            agentAddress: "agent"
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let result = formatter.date(from: value) {
            return result
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
