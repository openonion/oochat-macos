import Combine
import Foundation

nonisolated struct LLMUsageRecord: Codable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let agentAddress: String

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

@MainActor
protocol UsageRecording: AnyObject {
    func record(_ record: LLMUsageRecord)
}

nonisolated enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today:
            return "Today"
        case .last7Days:
            return "Last 7 days"
        case .last30Days:
            return "Last 30 days"
        case .allTime:
            return "All time"
        }
    }

    var precedingDayCount: Int? {
        switch self {
        case .today:
            return 0
        case .last7Days:
            return 6
        case .last30Days:
            return 29
        case .allTime:
            return nil
        }
    }
}

nonisolated struct UsageTotals: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var calls = 0

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    mutating func add(inputTokens: Int, outputTokens: Int, calls: Int) {
        self.inputTokens += inputTokens
        self.outputTokens += outputTokens
        self.calls += calls
    }

    mutating func add(_ other: UsageTotals) {
        add(
            inputTokens: other.inputTokens,
            outputTokens: other.outputTokens,
            calls: other.calls
        )
    }
}

nonisolated struct DailyUsagePoint: Identifiable, Equatable, Sendable {
    let date: Date
    let totals: UsageTotals

    var id: Date { date }
}

nonisolated struct ModelUsageBreakdown: Identifiable, Equatable, Sendable {
    let model: String
    let totals: UsageTotals

    var id: String { model }
}

nonisolated struct UsageSnapshot: Equatable, Sendable {
    let totals: UsageTotals
    let models: [ModelUsageBreakdown]
    let heatmapDays: [DailyUsagePoint]
    let heatmapTotals: UsageTotals
    let recordingSince: Date?

    var activeHeatmapDayCount: Int {
        heatmapDays.count { $0.totals.totalTokens > 0 }
    }
}

@MainActor
final class UsageStore: ObservableObject, UsageRecording {
    @Published private(set) var revision = 0
    @Published private(set) var storageError: String?

    private struct DailyModelBucket: Codable, Equatable {
        let dayKey: String
        let model: String
        var totals: UsageTotals
    }

    private struct PersistenceDocument: Codable {
        let schemaVersion: Int
        var recordingSince: Date?
        var buckets: [DailyModelBucket]
        var seenRecordIDs: Set<String>
    }

    private static let schemaVersion = 1

    private let fileURL: URL
    private let calendar: Calendar
    private let now: () -> Date
    private var recordingSince: Date?
    private var buckets: [String: DailyModelBucket] = [:]
    private var seenRecordIDs: Set<String> = []

    init(
        fileURL: URL = UsageStore.defaultFileURL(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.now = now
        recordingSince = nil

        if FileManager.default.fileExists(atPath: fileURL.path) {
            load()
        } else {
            recordingSince = now()
            persist()
        }
    }

    nonisolated deinit {}

    func record(_ record: LLMUsageRecord) {
        guard !seenRecordIDs.contains(record.id) else { return }

        let model = Self.normalizedModel(record.model)
        let dayKey = Self.dayKey(for: record.timestamp, calendar: calendar)
        let key = Self.bucketKey(dayKey: dayKey, model: model)
        var bucket = buckets[key] ?? DailyModelBucket(
            dayKey: dayKey,
            model: model,
            totals: UsageTotals()
        )
        bucket.totals.add(
            inputTokens: max(0, record.inputTokens),
            outputTokens: max(0, record.outputTokens),
            calls: 1
        )
        buckets[key] = bucket
        seenRecordIDs.insert(record.id)
        if recordingSince == nil {
            recordingSince = record.timestamp
        }
        revision &+= 1
        persist()
    }

    func snapshot(for range: UsageRange) -> UsageSnapshot {
        let today = calendar.startOfDay(for: now())
        let selectedStart = range.precedingDayCount.flatMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let heatmapStart = calendar.date(
            byAdding: .weekOfYear,
            value: -52,
            to: calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        ) ?? today

        var totals = UsageTotals()
        var modelTotals: [String: UsageTotals] = [:]
        var heatmapByDate: [Date: UsageTotals] = [:]
        var heatmapTotals = UsageTotals()

        for bucket in buckets.values {
            guard let date = Self.date(fromDayKey: bucket.dayKey, calendar: calendar) else {
                continue
            }

            let isInSelectedRange = selectedStart.map { date >= $0 } ?? true
            if isInSelectedRange && date <= today {
                totals.add(bucket.totals)
                var modelTotal = modelTotals[bucket.model] ?? UsageTotals()
                modelTotal.add(bucket.totals)
                modelTotals[bucket.model] = modelTotal
            }

            if date >= heatmapStart && date <= today {
                var dayTotal = heatmapByDate[date] ?? UsageTotals()
                dayTotal.add(bucket.totals)
                heatmapByDate[date] = dayTotal
                heatmapTotals.add(bucket.totals)
            }
        }

        let models = modelTotals
            .map { ModelUsageBreakdown(model: $0.key, totals: $0.value) }
            .sorted {
                if $0.totals.totalTokens == $1.totals.totalTokens {
                    return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
                }
                return $0.totals.totalTokens > $1.totals.totalTokens
            }
        let heatmapDays = heatmapByDate
            .map { DailyUsagePoint(date: $0.key, totals: $0.value) }
            .sorted { $0.date < $1.date }

        return UsageSnapshot(
            totals: totals,
            models: models,
            heatmapDays: heatmapDays,
            heatmapTotals: heatmapTotals,
            recordingSince: recordingSince
        )
    }

    func clearHistory() {
        buckets.removeAll()
        recordingSince = nil
        revision &+= 1
        persist()
    }

    nonisolated static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent(
                "ai.openonion.oochat.macos",
                isDirectory: true
            )
            .appendingPathComponent("usage-v1.json")
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(
                PersistenceDocument.self,
                from: data
            )
            guard document.schemaVersion == Self.schemaVersion else {
                throw UsageStoreError.unsupportedSchema
            }
            recordingSince = document.recordingSince
            buckets = Dictionary(
                uniqueKeysWithValues: document.buckets.map {
                    (Self.bucketKey(dayKey: $0.dayKey, model: $0.model), $0)
                }
            )
            seenRecordIDs = document.seenRecordIDs
            storageError = nil
        } catch {
            storageError = "Usage history could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let document = PersistenceDocument(
                schemaVersion: Self.schemaVersion,
                recordingSince: recordingSince,
                buckets: buckets.values.sorted {
                    if $0.dayKey == $1.dayKey {
                        return $0.model < $1.model
                    }
                    return $0.dayKey < $1.dayKey
                },
                seenRecordIDs: seenRecordIDs
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            storageError = nil
        } catch {
            storageError = "Usage history could not be saved: \(error.localizedDescription)"
        }
    }

    private static func normalizedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown model" : trimmed
    }

    private static func bucketKey(dayKey: String, model: String) -> String {
        "\(dayKey)\u{1F}\(model)"
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func date(
        fromDayKey dayKey: String,
        calendar: Calendar
    ) -> Date? {
        let components = dayKey.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(
            from: DateComponents(
                year: components[0],
                month: components[1],
                day: components[2]
            )
        )
    }
}

nonisolated private enum UsageStoreError: LocalizedError {
    case unsupportedSchema

    var errorDescription: String? {
        "This usage history was created by an unsupported app version."
    }
}
