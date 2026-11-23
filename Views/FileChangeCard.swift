import SwiftUI
import AppKit
import ConnectOnionKit

struct FileChangeCard: View {
    let change: FileChangeSummary
    let status: ExecutionStatus
    let timingMS: Double?

    @State private var isExpanded: Bool
    @State private var hasToggledByHand = false
    @State private var copiedLabel: String?

    init(change: FileChangeSummary, status: ExecutionStatus, timingMS: Double?) {
        self.change = change
        self.status = status
        self.timingMS = timingMS
        _isExpanded = State(initialValue: Self.startsOpen(for: status))
    }

    /// A diff stays open while its call runs or has failed, and starts folded once the call is done.
    static func startsOpen(for status: ExecutionStatus) -> Bool {
        status != .done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                hasToggledByHand = true
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(change.operation.displayName) \(displayPath)")
                            .font(AppTypography.mono(size: AppFontSize.body, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(change.path)
                            .font(AppTypography.mono(size: AppFontSize.footnote))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    if change.additions > 0 {
                        Text("+\(change.additions)")
                            .foregroundStyle(AppPalette.success)
                    }
                    if change.deletions > 0 {
                        Text("−\(change.deletions)")
                            .foregroundStyle(AppPalette.error)
                    }
                    if let timingMS {
                        Text(formatDuration(timingMS))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .font(AppTypography.mono(size: AppFontSize.caption, weight: .medium))
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.path)

            if isExpanded {
                Divider()
                if let diff = change.diff, !diff.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(
                                Array(diff.split(
                                    separator: "\n",
                                    omittingEmptySubsequences: false
                                ).enumerated()),
                                id: \.offset
                            ) { index, line in
                                diffLine(number: index + 1, text: String(line))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                } else {
                    Text("The agent did not provide a unified diff for this change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }

                Divider()
                HStack(spacing: 14) {
                    Spacer()
                    if let diff = change.diff, !diff.isEmpty {
                        copyButton(label: "Copy diff", value: diff)
                    }
                    copyButton(label: "Copy path", value: change.path)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(OOColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: OORadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
                .stroke(OOColor.hairline, lineWidth: 1)
        }
        .frame(maxWidth: 920, alignment: .leading)
        .onChange(of: status) { _, newStatus in
            if newStatus == .done, !hasToggledByHand {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded = false
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .running:
            OOToolStatus(.running)
        case .done:
            OOToolStatus(.done)
        case .error:
            OOToolStatus(.failed)
        }
    }

    private var displayPath: String {
        URL(fileURLWithPath: change.path).lastPathComponent
    }

    private func diffLine(number: Int, text: String) -> some View {
        let isAddition = text.hasPrefix("+") && !text.hasPrefix("+++")
        let isDeletion = text.hasPrefix("-") && !text.hasPrefix("---")
        let background: Color = if isAddition {
            AppPalette.success.opacity(0.10)
        } else if isDeletion {
            AppPalette.error.opacity(0.10)
        } else {
            .clear
        }

        return HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .foregroundStyle(.secondary.opacity(0.65))
                .frame(width: 34, alignment: .trailing)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(
                    isAddition
                        ? AppPalette.success
                        : (isDeletion ? AppPalette.error : Color.primary)
                )
                .textSelection(.enabled)
        }
        .font(AppTypography.mono(size: AppFontSize.caption))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func copyButton(label: String, value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedLabel = label
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copiedLabel == label { copiedLabel = nil }
            }
        } label: {
            Text(copiedLabel == label ? "Copied" : label)
                .font(.caption)
                .foregroundStyle(copiedLabel == label ? AppPalette.success : Color.secondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        String(format: milliseconds < 10_000 ? "%.1fs" : "%.0fs", milliseconds / 1_000)
    }
}

/// Shows a queued attachment and allows it to be removed before sending.
