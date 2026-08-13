import SwiftUI
import AppKit

struct FileChangeCard: View {
    let change: FileChangeSummary
    let status: ExecutionStatus
    let timingMS: Double?

    @State private var isExpanded = true
    @State private var copiedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
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
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppPalette.divider, lineWidth: 1)
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if status == .running {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: status == .error ? "xmark" : "checkmark")
                .font(.system(size: AppFontSize.body, weight: .semibold))
                .foregroundStyle(status == .error ? AppPalette.error : AppPalette.success)
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
        Button(copiedLabel == label ? "Copied" : label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedLabel = label
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copiedLabel == label {
                    copiedLabel = nil
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(copiedLabel == label ? AppPalette.success : Color.secondary)
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        String(format: milliseconds < 10_000 ? "%.1fs" : "%.0fs", milliseconds / 1_000)
    }
}

/// Shows a queued attachment and allows it to be removed before sending.
