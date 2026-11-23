import ConnectOnionKit
import SwiftUI

/// One drawn step of a run: an execution row, or the Work Room Card standing
/// where a Provider Invocation's outer tool call was.
enum ChatTraceEntry: Identifiable {
    case item(ExecutionItem)
    case workRoom(WorkRoom)
    case finishedSteps(id: String, steps: [ToolCallExecutionItem])

    /// A card keeps its tool call's id, so it holds that place in the run.
    var id: String {
        switch self {
        case .item(let item): item.id
        case .workRoom(let workRoom): workRoom.toolCallID
        case .finishedSteps(let id, _): id
        }
    }
}

enum ChatViewPresentation {
    static func hasStartedConversation(_ messages: [ChatMessage]) -> Bool {
        messages.contains { $0.role != .system }
    }

    static func lastUserMessageID(in messages: [ChatMessage]) -> UUID? {
        messages.last { $0.role == .user }?.id
    }

    static func executionRuns(
        for message: ChatMessage,
        from runs: [ExecutionRun]
    ) -> [ExecutionRun] {
        guard message.role == .user else { return [] }
        return runs.filter { run in
            run.userMessageId == message.id && run.hasUserVisibleTrace
        }
    }

    static func unlinkedExecutionRuns(from runs: [ExecutionRun]) -> [ExecutionRun] {
        runs.filter { run in
            run.userMessageId == nil && run.hasUserVisibleTrace
        }
    }

    static func approvalRequest(
        from interaction: ConnectOnionPendingInteraction?
    ) -> ConnectOnionApprovalRequest? {
        guard case .approval(let request)? = interaction else { return nil }
        return request
    }

    /// Drops the per-step LLM metadata rows (model · tokens · cost) that sit
    /// between tool calls, keeping only the final one. Tool calls then read as a
    /// single grouped trace rather than being interleaved with model info.
    static func collapsedTraceItems(_ items: [ExecutionItem]) -> [ExecutionItem] {
        let finalMetadataID = items.last { item in
            guard case .thinking(let thinking) = item else { return false }
            return thinking.kind == nil
        }?.id

        return items.filter { item in
            guard case .thinking(let thinking) = item, thinking.kind == nil else {
                return true
            }
            return item.id == finalMetadataID
        }
    }

    /// The collapsed trace with each Provider Invocation's outer tool call swapped
    /// for its Work Room Card; continuation tool calls are dropped.
    static func traceEntries(_ items: [ExecutionItem], workRooms: WorkRoomStore) -> [ChatTraceEntry] {
        var entries: [ChatTraceEntry] = []
        var pending: [ToolCallExecutionItem] = []

        func flush() {
            if pending.count >= minimumFinishedStepGroupSize, let first = pending.first {
                // Keyed on the first step so expansion state survives new steps streaming in.
                entries.append(.finishedSteps(id: "steps-\(first.id)", steps: pending))
            } else {
                entries.append(contentsOf: pending.map { .item(.toolCall($0)) })
            }
            pending.removeAll()
        }

        for item in collapsedTraceItems(items) {
            guard case .toolCall(let call) = item else {
                flush()
                entries.append(.item(item))
                continue
            }

            if let workRoom = workRooms.workRoom(forToolCallID: call.id) {
                flush()
                entries.append(.workRoom(workRoom))
                continue
            }

            if workRooms.isProviderToolCall(call.id) {
                continue
            }

            if call.isCleanlyFinished {
                pending.append(call)
            } else {
                flush()
                entries.append(.item(item))
            }
        }
        flush()
        return entries
    }
}

extension ChatViewPresentation {
    /// A single finished step is no shorter as a disclosure, so only runs of
    /// this size or more are grouped.
    static let minimumFinishedStepGroupSize = 2

    static func groupedTraceEntries(_ items: [ExecutionItem]) -> [ChatTraceEntry] {
        var entries: [ChatTraceEntry] = []
        var pending: [ToolCallExecutionItem] = []

        func flush() {
            if pending.count >= minimumFinishedStepGroupSize, let first = pending.first {
                // Keyed on the first step so expansion state survives new steps streaming in.
                entries.append(.finishedSteps(id: "steps-\(first.id)", steps: pending))
            } else {
                entries.append(contentsOf: pending.map { .item(.toolCall($0)) })
            }
            pending.removeAll()
        }

        for item in items {
            if case .toolCall(let call) = item, call.isCleanlyFinished {
                pending.append(call)
            } else {
                flush()
                entries.append(.item(item))
            }
        }
        flush()
        return entries
    }

    /// "Ran 9 steps · 3.6 s". The time is the sum of the steps' own timings and is
    /// omitted when it rounds to zero.
    static func finishedStepsSummary(_ steps: [ToolCallExecutionItem]) -> String {
        var text = "Ran \(steps.count) step\(steps.count == 1 ? "" : "s")"
        let totalMS = steps.compactMap(\.timingMS).reduce(0, +)
        if totalMS >= 50 {
            let seconds = totalMS / 1_000
            if seconds < 10 {
                text += String(format: " · %.1f s", seconds)
            } else if seconds < 60 {
                text += String(format: " · %.0f s", seconds)
            } else {
                text += " · \(Int(seconds) / 60) m \(Int(seconds) % 60) s"
            }
        }
        return text
    }
}
/// Formats token, cost, and context usage for compact status labels.
enum ChatUsageFormatter {
    static func tokenText(for usage: ChatUsageSummary) -> String {
        let tokens = Double(usage.tokenCount)
        if tokens >= 1_000_000 {
            return String(format: "%.1fM tok", tokens / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk tok", tokens / 1_000)
        }
        return "\(usage.tokenCount) tok"
    }

    static func costText(for usage: ChatUsageSummary) -> String {
        if usage.totalCost > 0, usage.totalCost < 0.01 {
            return String(format: "$%.4f", usage.totalCost)
        }
        return String(format: "$%.2f", usage.totalCost)
    }

    static func contextText(for usage: ChatUsageSummary) -> String {
        let percent = min(max(usage.contextPercent, 0), 100)
        return String(format: "%.0f%% ctx", percent)
    }
}

/// Coordinates the conversation timeline, composer, attachments, and live events.

struct ChatUsageSummaryView: View {
    let usage: ChatUsageSummary

    var body: some View {
        Text("\(tokenText) · \(costText)   \(contextText)")
            .font(AppTypography.mono(size: AppFontSize.caption))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .help("Session tokens · session cost · current context usage")
    }

    private var tokenText: String {
        ChatUsageFormatter.tokenText(for: usage)
    }

    private var costText: String {
        ChatUsageFormatter.costText(for: usage)
    }

    private var contextText: String {
        ChatUsageFormatter.contextText(for: usage)
    }
}

/// Renders user, agent, and system messages with role-specific presentation.
