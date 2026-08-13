import SwiftUI

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
