import SwiftUI

struct ExecutionItemRow: View {
    let item: ExecutionItem
    let messageFontSize: CGFloat
    let completionSummary: String?
    @State private var isExpanded: Bool

    init(
        item: ExecutionItem,
        messageFontSize: CGFloat,
        completionSummary: String?,
        isExpanded: Bool = false
    ) {
        self.item = item
        self.messageFontSize = messageFontSize
        self.completionSummary = completionSummary
        _isExpanded = State(initialValue: isExpanded)
    }

    @ViewBuilder
    var body: some View {
        switch item {
        case .intent(let intent):
            acknowledgementRow(intent.ack)

        case .thinking(let thinking):
            if thinking.kind == "intent" {
                acknowledgementRow(thinking.content)
            } else if thinking.kind == "reflect" {
                reflectionRow(thinking)
            } else if thinking.kind == "plan" {
                reasoningSummaryRow(
                    thinking,
                    title: "Planning",
                    detailTitle: "PLAN",
                    accent: AppPalette.primaryAction
                )
            } else {
                thinkingMetadataRow(thinking)
            }

        case .toolCall(let toolCall):
            toolRow(toolCall)

        case .approval(let approval):
            approvalRow(approval)

        case .eval(let eval):
            verificationRow(eval)
        }
    }

    private func acknowledgementRow(_ content: String?) -> some View {
        Group {
            if let content, !content.isEmpty {
                Text(content)
                    .font(AppTypography.mono(size: messageFontSize))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    private func thinkingMetadataRow(_ thinking: ThinkingExecutionItem) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(thinking.status == .error ? AppPalette.error : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            if thinking.status == .running {
                ProgressView()
                    .controlSize(.mini)
            }

            Text(thinkingMetadata(thinking))
                .font(AppTypography.mono(size: AppFontSize.body))
                .foregroundStyle(.secondary.opacity(0.85))
                .textSelection(.enabled)

            if let completionSummary {
                Spacer(minLength: 16)
                Text(completionSummary)
                    .font(AppTypography.mono(size: AppFontSize.body))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    @ViewBuilder
    private func toolRow(_ toolCall: ToolCallExecutionItem) -> some View {
        // Show the rich diff card only when there is an actual diff to render;
        // diff-less mutations (e.g. creating an empty file) use the compact row
        // to match the reference chat, which renders "Write <file> · DONE".
        if let change = toolCall.fileChangeSummary,
           let diff = change.diff, !diff.isEmpty {
            FileChangeCard(
                change: change,
                status: toolCall.status,
                timingMS: toolCall.timingMS
            )
        } else {
            let category = toolCall.category
            VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppFontSize.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    toolStatusIcon(toolCall.status)

                    Image(systemName: category.icon)
                        .font(.system(size: AppFontSize.body))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(toolCall.displayName)
                        .font(AppTypography.mono(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(toolCall.status == .error ? AppPalette.error : .primary)
                        .fixedSize()

                    if let subtitle = toolCall.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppTypography.mono(size: AppFontSize.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 16)

                    Text(toolCall.statusLabel(timing: toolCall.timingMS.map(formatDuration)))
                        .font(AppTypography.mono(size: AppFontSize.footnote, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                toolBody(toolCall, category: category)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 920, alignment: .leading)
        }
    }

    /// Leading indicator for in-progress and failed tool calls. Completed calls
    /// show no marker — the tool icon alone carries a clean, un-noisy done state.
    @ViewBuilder
    private func toolStatusIcon(_ status: ExecutionStatus) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            EmptyView()
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: AppFontSize.subheadline))
                .foregroundStyle(AppPalette.error)
        }
    }

    /// Category-aware expanded body: a terminal panel for shell tools; clean
    /// key/value argument rows plus a diff-aware result for every other tool.
    @ViewBuilder
    private func toolBody(
        _ toolCall: ToolCallExecutionItem,
        category: ToolCategory
    ) -> some View {
        if category == .shell {
            terminalBlock(command: toolCall.shellCommand, output: toolCall.result)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(secondaryArguments(toolCall), id: \.key) { argument in
                    argumentRow(key: argument.key, value: argument.value)
                }
                if let result = toolCall.result, !result.isEmpty {
                    if isUnifiedDiff(result) {
                        diffPreview(result)
                    } else {
                        detailBlock("RESULT", result)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }

    /// Arguments worth showing in the body: everything except the value already
    /// surfaced as the header subtitle, rendered as compact key/value pairs.
    private func secondaryArguments(
        _ toolCall: ToolCallExecutionItem
    ) -> [(key: String, value: String)] {
        let subtitle = toolCall.subtitle
        var rows: [(key: String, value: String)] = []
        for key in toolCall.args.keys.sorted() {
            guard let value = toolCall.args[key] else { continue }
            let text = argumentDisplayString(value)
            if text.isEmpty || text == subtitle { continue }
            rows.append((key: key, value: text))
        }
        return rows
    }

    private func argumentDisplayString(_ value: JSONValue) -> String {
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            return number == number.rounded()
                ? String(Int(number))
                : String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return ""
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    private func argumentRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(AppTypography.mono(size: AppFontSize.footnote, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppTypography.mono(size: AppFontSize.caption))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func isUnifiedDiff(_ text: String) -> Bool {
        if text.hasPrefix("--- "), text.contains("\n+++ ") { return true }
        return text.hasPrefix("@@") || text.contains("\n@@")
    }

    /// Colored unified-diff preview shared by diff-producing tools (edits,
    /// diff_writer.diff). Additions are green, deletions red, hunks accented.
    private func diffPreview(_ diff: String) -> some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                Text(line.isEmpty ? " " : line)
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .foregroundStyle(diffLineColor(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(diffLineBackground(line))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return AppPalette.success }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return AppPalette.error }
        if line.hasPrefix("@@") { return AppPalette.primaryAction.opacity(0.75) }
        return .secondary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return AppPalette.success.opacity(0.10)
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return AppPalette.error.opacity(0.10)
        }
        return .clear
    }

    /// Dark terminal-style panel for shell command traces.
    private func terminalBlock(command: String?, output: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command, !command.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("$")
                        .foregroundStyle(AppPalette.success)
                    Text(command)
                        .foregroundStyle(Color(white: 0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AppTypography.mono(size: AppFontSize.caption))
            }

            if let output, !output.isEmpty {
                if command?.isEmpty == false {
                    Divider().overlay(Color.white.opacity(0.12))
                }
                Text(output)
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .foregroundStyle(Color(white: 0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    private func approvalRow(_ approval: ApprovalExecutionItem) -> some View {
        let approved = approval.decision.isApproved
        return statusTrace(accent: approved ? AppPalette.success : AppPalette.error) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: approved ? "checkmark" : "xmark")
                    .foregroundStyle(approved ? AppPalette.success : AppPalette.error)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approval.decision.displayName)
                        .font(AppTypography.mono(size: AppFontSize.body, weight: .semibold))
                    Text(
                        [approval.tool, approval.target]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(approval.risk.displayName) risk")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(approved ? Color.secondary : AppPalette.error)
            }
        }
    }

    @ViewBuilder
    private func reflectionRow(_ thinking: ThinkingExecutionItem) -> some View {
        reasoningSummaryRow(
            thinking,
            title: "Reflecting",
            detailTitle: "REFLECTION",
            accent: AppPalette.success
        )
    }

    private func reasoningSummaryRow(
        _ thinking: ThinkingExecutionItem,
        title: String,
        detailTitle: String,
        accent: Color
    ) -> some View {
        statusTrace(accent: thinking.status == .error ? AppPalette.error : accent) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusSymbol(isRunning: thinking.status == .running,
                                     isError: thinking.status == .error)
                        Text(title)
                            .font(AppTypography.mono(size: AppFontSize.body, weight: .semibold))
                        if let content = thinking.content, !content.isEmpty {
                            Text(content)
                                .font(AppTypography.mono(size: AppFontSize.body))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if thinking.content?.isEmpty == false {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded, let content = thinking.content, !content.isEmpty {
                    detailBlock(detailTitle, content)
                        .transition(.opacity)
                }
            }
        }
    }

    private func verificationRow(_ eval: EvalExecutionItem) -> some View {
        let hasExpected = eval.expected?.isEmpty == false

        return statusTrace(accent: eval.passed == false ? AppPalette.error : AppPalette.success) {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    guard hasExpected else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if eval.status == .evaluating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: eval.passed == false ? "xmark" : "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(eval.passed == false ? AppPalette.error : AppPalette.success)
                        }

                        Text(eval.summary ?? (eval.status == .evaluating ? "Verifying…" : "Verification completed"))
                            .font(AppTypography.mono(size: AppFontSize.body))
                            .foregroundStyle(eval.passed == false ? AppPalette.error : .secondary)

                        Spacer(minLength: 8)

                        if hasExpected {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded, let expected = eval.expected, !expected.isEmpty {
                    Text("expected: \(expected)")
                        .font(AppTypography.mono(size: AppFontSize.body))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.leading, 32)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func statusTrace<Content: View>(
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(width: 2)

            content()
                .frame(maxWidth: 900, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func statusSymbol(isRunning: Bool, isError: Bool) -> some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: isError ? "xmark" : "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(isError ? AppPalette.error : AppPalette.success)
        }
    }

    private func detailBlock(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(AppTypography.mono(size: AppFontSize.footnote, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(AppTypography.mono(size: AppFontSize.caption))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.top, 4)
    }

    private func thinkingMetadata(_ thinking: ThinkingExecutionItem) -> String {
        var parts: [String] = []
        if let model = thinking.model, !model.isEmpty {
            parts.append(model)
        } else {
            parts.append(thinking.status == .running ? "Thinking…" : "Thinking")
        }
        if let usage = thinking.usage {
            parts.append(formatTokens(usage.tokenCount))
            parts.append(formatCost(usage.totalCost))
        }
        if let duration = thinking.durationMS, duration >= 1 {
            parts.append(formatDuration(duration))
        }
        return parts.joined(separator: " · ")
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM tok", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk tok", Double(tokens) / 1_000)
        }
        return "\(tokens) tok"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost > 0, cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 0.05 {
            return "0.0s"
        }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    private func jsonText(_ value: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return "{}"
        }
        return String(data: prettyData, encoding: .utf8) ?? "{}"
    }
}

/// Presents a structured file mutation with status, diff, and copy actions.
