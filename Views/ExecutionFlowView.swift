import ConnectOnionKit
import SwiftUI

struct ExecutionFlowView: View {
    let run: ExecutionRun
    let messageFontSize: CGFloat
    let conversationWidth: CGFloat
    let workRooms: WorkRoomStore
    let onOpenWorkRoom: (String) -> Void
    let agentName: String
    /// The request in flight. Only it waits: a run saved mid-reply stays "running" in history.
    let isActive: Bool
    /// Nil when the agent can't be stopped right now, for example once Stop was already asked for.
    let onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isActive && run.isWaitingForFirstStep {
                WaitingForAgentRow(startedAt: run.startedAt, agentName: agentName, onStop: onStop)
            } else {
                ForEach(traceEntries) { entry in
                    switch entry {
                    case .item(let item):
                        ExecutionItemRow(
                            item: item,
                            messageFontSize: messageFontSize,
                            completionSummary: completionSummary(for: item),
                            isExpanded: startsExpanded(item)
                        )
                    case .workRoom(let workRoom):
                        OOWorkRoomCard(
                            workRoom: workRoom,
                            onOpen: { onOpenWorkRoom(workRoom.id) },
                            onDecide: { workRooms.decide($0, in: workRoom.id) }
                        )
                    case .finishedSteps(_, let steps):
                        FinishedStepsGroupRow(steps: steps, messageFontSize: messageFontSize)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: conversationWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var traceEntries: [ChatTraceEntry] {
            ChatViewPresentation.traceEntries(run.items, workRooms: workRooms)
    }

    /// Failed tool calls open by default so the error is on screen.
    private func startsExpanded(_ item: ExecutionItem) -> Bool {
        if case .toolCall(let call) = item { return call.needsAttention }
        return false
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

/// Shown while the agent works on a reply with no trace yet: how long you've waited, and Stop after a while.
private struct WaitingForAgentRow: View {
    /// Stop only appears after this long, so a quick reply doesn't flash a button.
    static let stopDelay = 10

    let startedAt: Date
    let agentName: String
    let onStop: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 9) {
                // macOS draws ProgressView's spinner itself and ignores tint, so the symbol carries the accent.
                Image(systemName: "progress.indicator")
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(OOColor.primary)
                    .symbolEffect(.variableColor.iterative)
                    .accessibilityHidden(true)

                Text("Waiting for \(agentName) · \(seconds) s")
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(OOColor.inkSecondary)
                    .contentTransition(.numericText())

                if seconds >= Self.stopDelay, let onStop {
                    Button("Stop", action: onStop)
                        .buttonStyle(.plain)
                        .font(.system(size: AppFontSize.body))
                        .foregroundStyle(OOColor.inkSecondary)
                        .underline()
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .help("Stop \(agentName)")
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
        }
    }
}

/// Maps each execution event into its specialized trace presentation.
