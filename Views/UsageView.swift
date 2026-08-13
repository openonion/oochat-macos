import SwiftUI

enum UsageHeatmapScale {
    static func intensity(tokens: Int, maximumTokens: Int) -> Int {
        guard tokens > 0, maximumTokens > 0 else { return 0 }
        let normalized = log1p(Double(tokens)) / log1p(Double(maximumTokens))
        return min(4, max(1, Int(ceil(normalized * 4))))
    }
}

enum UsageValueFormatter {
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        if value >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return value.formatted()
    }

    static func exactTokens(_ value: Int) -> String {
        "\(value.formatted()) tokens"
    }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    let onClose: () -> Void

    @State private var selectedRange: UsageRange = .last7Days
    @State private var isConfirmingClear = false

    var body: some View {
        let snapshot = store.snapshot(for: selectedRange)
        let allTimeSnapshot = store.snapshot(for: .allTime)

        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    introduction

                    if let storageError = store.storageError {
                        storageErrorBanner(storageError)
                    }

                    UsageHeatmapView(snapshot: snapshot)
                    rangePicker
                    summaryCard(snapshot.totals)
                    modelCard(snapshot.models)
                    footer(
                        recordingSince: allTimeSnapshot.recordingSince,
                        canClear: allTimeSnapshot.totals.calls > 0
                            || allTimeSnapshot.recordingSince != nil
                    )
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("usage-view")
        .alert("Clear usage history?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                store.clearHistory()
            }
        } message: {
            Text(
                "This removes the usage totals stored on this device. "
                    + "Chats, agents, Wallet, and identity data are not affected."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Usage")
                .font(.system(size: AppFontSize.pageTitle, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Usage")
            .help("Close Usage")
        }
    }

    private var introduction: some View {
        Text(
            "Token usage recorded on this device, grouped by model. "
                + "Usage is kept after you delete a conversation or agent because "
                + "the tokens were already spent, and it never leaves your Mac."
        )
        .font(.system(size: AppFontSize.body))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func storageErrorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: AppFontSize.caption, weight: .medium))
            .foregroundStyle(AppPalette.error)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.error.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rangePicker: some View {
        HStack(spacing: 30) {
            ForEach(UsageRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: selectedRange == range
                                ? "largecircle.fill.circle"
                                : "circle"
                        )
                        .font(.system(size: 16))

                        Text(range.displayName)
                            .font(.system(size: AppFontSize.body))
                    }
                    .foregroundStyle(
                        selectedRange == range ? .primary : .secondary
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage period")
    }

    @ViewBuilder
    private func summaryCard(_ totals: UsageTotals) -> some View {
        let values = [
            ("Total tokens", totals.totalTokens),
            ("Input", totals.inputTokens),
            ("Output", totals.outputTokens),
            ("LLM calls", totals.calls)
        ]

        Group {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(values, id: \.0) { value in
                        summaryMetric(title: value.0, value: value.1)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(values, id: \.0) { value in
                        summaryMetric(title: value.0, value: value.1)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(CardBackground(cornerRadius: 14))
    }

    private func summaryMetric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(UsageValueFormatter.compact(value))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Text(title)
                .font(.system(size: AppFontSize.caption))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func modelCard(
        _ models: [ModelUsageBreakdown]
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("By model")
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))

            if models.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)

                    Text("No usage recorded for this period")
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("Model calls received from a connected Host will appear here.")
                        .font(.system(size: AppFontSize.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                let maximumTokens = models.first?.totals.totalTokens ?? 0
                ForEach(models) { model in
                    modelRow(model, maximumTokens: maximumTokens)
                }
            }
        }
        .padding(24)
        .background(CardBackground(cornerRadius: 14))
    }

    private func modelRow(
        _ model: ModelUsageBreakdown,
        maximumTokens: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.model)
                    .font(AppTypography.mono(
                        size: AppFontSize.body,
                        weight: .medium
                    ))
                    .lineLimit(1)

                Spacer()

                Text(UsageValueFormatter.compact(model.totals.totalTokens))
                    .font(.system(size: AppFontSize.body, weight: .semibold))
            }

            GeometryReader { geometry in
                let ratio = maximumTokens > 0
                    ? Double(model.totals.totalTokens) / Double(maximumTokens)
                    : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.divider)

                    Capsule()
                        .fill(Color.primary.opacity(0.82))
                        .frame(width: geometry.size.width * ratio)
                }
            }
            .frame(height: 4)

            Text(
                "\(model.totals.calls.formatted()) calls   "
                    + "\(UsageValueFormatter.compact(model.totals.inputTokens)) in   "
                    + "\(UsageValueFormatter.compact(model.totals.outputTokens)) out"
            )
            .font(.system(size: AppFontSize.footnote))
            .foregroundStyle(.secondary)
        }
    }

    private func footer(
        recordingSince: Date?,
        canClear: Bool
    ) -> some View {
        HStack {
            if let recordingSince {
                let dateText = recordingSince.formatted(
                    .dateTime.day().month(.abbreviated).year()
                )
                Text("Recording since \(dateText)")
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(.secondary)
            } else {
                Text("Usage recording will resume with the next model call.")
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Clear usage history") {
                isConfirmingClear = true
            }
            .buttonStyle(.bordered)
            .disabled(!canClear)
        }
    }
}

private struct UsageHeatmapView: View {
    @Environment(\.colorScheme) private var colorScheme

    let snapshot: UsageSnapshot

    private let calendar = Calendar.current
    private let columnCount = 53
    private let cellSpacing: CGFloat = 3
    private let weekdayLabelWidth: CGFloat = 32

    var body: some View {
        let grid = heatmapGrid()
        let maximumTokens = snapshot.heatmapDays
            .map(\.totals.totalTokens)
            .max() ?? 0
        let tokensByDay = Dictionary(
            uniqueKeysWithValues: snapshot.heatmapDays.map {
                (calendar.startOfDay(for: $0.date), $0.totals.totalTokens)
            }
        )

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "\(UsageValueFormatter.compact(snapshot.heatmapTotals.totalTokens)) "
                        + "tokens over \(snapshot.activeHeatmapDayCount) active "
                        + (snapshot.activeHeatmapDayCount == 1 ? "day" : "days")
                )
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))

                Text(dateRangeText(grid: grid))
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let availableWidth = geometry.size.width
                    - weekdayLabelWidth
                    - CGFloat(columnCount - 1) * cellSpacing
                let cellSize = max(6, min(12, availableWidth / CGFloat(columnCount)))

                VStack(alignment: .leading, spacing: 6) {
                    monthLabels(grid: grid, cellSize: cellSize)
                        .padding(.leading, weekdayLabelWidth)

                    HStack(alignment: .top, spacing: 0) {
                        weekdayLabels(cellSize: cellSize)
                            .frame(width: weekdayLabelWidth, alignment: .leading)

                        HStack(spacing: cellSpacing) {
                            ForEach(0..<columnCount, id: \.self) { weekIndex in
                                VStack(spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { weekdayIndex in
                                        let date = grid[weekIndex][weekdayIndex]
                                        let tokens = tokensByDay[
                                            calendar.startOfDay(for: date)
                                        ] ?? 0
                                        heatmapCell(
                                            date: date,
                                            tokens: tokens,
                                            maximumTokens: maximumTokens,
                                            cellSize: cellSize
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 128)

            HStack(spacing: 5) {
                Spacer()
                Text("Less")
                ForEach(0...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: level))
                        .frame(width: 12, height: 12)
                }
                Text("More")
            }
            .font(.system(size: AppFontSize.footnote))
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(CardBackground(cornerRadius: 14))
    }

    private func heatmapGrid() -> [[Date]] {
        let today = calendar.startOfDay(for: Date())
        let currentWeekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: today
        )?.start ?? today
        let firstDate = calendar.date(
            byAdding: .weekOfYear,
            value: -(columnCount - 1),
            to: currentWeekStart
        ) ?? currentWeekStart

        return (0..<columnCount).map { weekIndex in
            (0..<7).compactMap { weekdayIndex in
                calendar.date(
                    byAdding: .day,
                    value: weekIndex * 7 + weekdayIndex,
                    to: firstDate
                )
            }
        }
    }

    private func monthLabels(
        grid: [[Date]],
        cellSize: CGFloat
    ) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 14)

            ForEach(monthLabelEntries(grid: grid), id: \.weekIndex) { entry in
                Text(entry.date.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(.secondary)
                    .offset(
                        x: CGFloat(entry.weekIndex) * (cellSize + cellSpacing)
                    )
            }
        }
    }

    private func monthLabelEntries(
        grid: [[Date]]
    ) -> [(weekIndex: Int, date: Date)] {
        var previousMonth: Int?
        return grid.enumerated().compactMap { weekIndex, week in
            guard let date = week.first else { return nil }
            let month = calendar.component(.month, from: date)
            defer { previousMonth = month }
            guard month != previousMonth else { return nil }
            return (weekIndex, date)
        }
    }

    private func weekdayLabels(cellSize: CGFloat) -> some View {
        let symbols = orderedWeekdaySymbols()
        return VStack(alignment: .leading, spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { index in
                Text(index.isMultiple(of: 2) ? "" : symbols[index])
                    .font(.system(size: AppFontSize.footnote))
                    .foregroundStyle(.secondary)
                    .frame(height: cellSize)
            }
        }
    }

    private func orderedWeekdaySymbols() -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        let startIndex = max(0, calendar.firstWeekday - 1)
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }

    private func heatmapCell(
        date: Date,
        tokens: Int,
        maximumTokens: Int,
        cellSize: CGFloat
    ) -> some View {
        let today = calendar.startOfDay(for: Date())
        let isFuture = date > today
        let level = UsageHeatmapScale.intensity(
            tokens: tokens,
            maximumTokens: maximumTokens
        )
        let dateText = date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year()
        )

        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(isFuture ? Color.clear : color(for: level))
            .frame(width: cellSize, height: cellSize)
            .help(
                isFuture
                    ? ""
                    : "\(dateText): \(UsageValueFormatter.exactTokens(tokens))"
            )
            .accessibilityLabel(
                "\(date.formatted(date: .complete, time: .omitted)), "
                    + UsageValueFormatter.exactTokens(tokens)
            )
            .accessibilityHidden(isFuture)
    }

    private func color(for level: Int) -> Color {
        guard level > 0 else { return AppPalette.surfaceMuted }
        let opacity: Double
        switch level {
        case 1:
            opacity = colorScheme == .dark ? 0.28 : 0.20
        case 2:
            opacity = colorScheme == .dark ? 0.46 : 0.40
        case 3:
            opacity = colorScheme == .dark ? 0.68 : 0.62
        default:
            opacity = colorScheme == .dark ? 0.92 : 0.86
        }
        return Color.primary.opacity(opacity)
    }

    private func dateRangeText(grid: [[Date]]) -> String {
        guard let firstDate = grid.first?.first else { return "" }
        let today = Date()
        let startText = firstDate.formatted(
            .dateTime.day().month(.abbreviated).year()
        )
        let endText = today.formatted(
            .dateTime.day().month(.abbreviated).year()
        )
        return "\(startText) – \(endText)"
    }
}
