import SwiftUI

struct ExecutionFlowView: View {
    let run: ExecutionRun
    let messageFontSize: CGFloat
    let conversationWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if run.isDirectAnswerTrace && run.status == .running {
                DirectAnswerProgressRow(startedAt: run.startedAt)
            } else {
                ForEach(visibleItems) { item in
                    ExecutionItemRow(
                        item: item,
                        messageFontSize: messageFontSize,
                        completionSummary: completionSummary(for: item)
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: conversationWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var visibleItems: [ExecutionItem] {
        ChatViewPresentation.collapsedTraceItems(run.items)
    }

    private func completionSummary(for item: ExecutionItem) -> String? {
        guard run.status != .running,
              item.id == finalMetadataItemID,
              let endedAt = run.endedAt else {
            return nil
        }
        let count = run.items.count
        let duration = max(0, endedAt.timeIntervalSince(run.startedAt))
        return "\(count) step\(count == 1 ? "" : "s") in \(formatDuration(duration))"
    }

    private var finalMetadataItemID: String? {
        run.items.last { item in
            guard case .thinking(let thinking) = item else { return false }
            return thinking.kind == nil
        }?.id
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.05 {
            return "0.0s"
        }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.1fs", seconds)
    }
}

/// Shows elapsed progress while a direct answer has no detailed trace items.

private struct DirectAnswerProgressRow: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))

                Text("\(phase(for: seconds))… (\(seconds)s)")
                    .font(AppTypography.mono(size: AppFontSize.body, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private func phase(for seconds: Int) -> String {
        switch seconds {
        case ..<3:
            return "Thinking"
        case ..<7:
            return "Pondering"
        default:
            return "Synthesizing"
        }
    }
}

/// Maps each execution event into its specialized trace presentation.
