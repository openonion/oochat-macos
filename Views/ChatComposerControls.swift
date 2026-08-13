import SwiftUI

struct PendingAttachmentChip: View {
    let attachment: ConnectOnionInputFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.fill")
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(AppTypography.mono(size: AppFontSize.caption, weight: .medium))
                    .lineLimit(1)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(attachment.byteCount),
                        countStyle: .file
                    )
                )
                .font(AppTypography.mono(size: AppFontSize.footnote))
                .foregroundColor(.secondary)
            }

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Switches the agent between safe, plan, and accept execution modes.

struct ExecutionModeSelector: View {
    @ObservedObject var viewModel: ChatViewModel

    @AppStorage("executionModeAcceptWarningAcknowledged")
    private var hasAcknowledgedAcceptWarning = false
    @State private var isShowingModeGuide = false
    @State private var isConfirmingAcceptMode = false
    @State private var confirmationMessage: String?
    @State private var confirmationID = UUID()

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(AgentExecutionMode.allCases, id: \.self) { mode in
                    Button {
                        select(mode)
                    } label: {
                        Text(mode.displayName)
                            .font(.system(
                                size: AppFontSize.footnote,
                                weight: selected(mode) ? .semibold : .regular
                            ))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .foregroundColor(
                                selected(mode)
                                    ? AppPalette.primaryActionForeground
                                    : .secondary
                            )
                            .background(selectionColor(mode))
                            .clipShape(RoundedRectangle(
                                cornerRadius: 6,
                                style: .continuous
                            ))
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canChangeExecutionMode)
                    .accessibilityLabel(mode.displayName)
                    .accessibilityHint(mode.helpText)
                    .help(mode.helpText)
                }
            }
            .padding(2)
            .background(AppPalette.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            }

            Button {
                isShowingModeGuide.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Explain execution modes")
            .help("Explain execution modes")
            .popover(isPresented: $isShowingModeGuide, arrowEdge: .bottom) {
                ExecutionModeGuide(selectedMode: viewModel.desiredExecutionMode)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let confirmationMessage {
                Label(confirmationMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppFontSize.caption, weight: .medium))
                    .foregroundStyle(AppPalette.success)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AppPalette.divider, lineWidth: 1)
                    }
                    .offset(y: -34)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: confirmationMessage)
        .alert("Enable Accept mode?", isPresented: $isConfirmingAcceptMode) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Accept", role: .destructive) {
                hasAcknowledgedAcceptWarning = true
                viewModel.setExecutionMode(.accept)
            }
        } message: {
            Text(
                "Accept mode allows the agent to use enabled tools without "
                    + "approval for up to 10 turns."
            )
        }
        .onChange(of: viewModel.confirmedExecutionMode) { _, mode in
            showConfirmation(for: mode)
        }
    }

    private func select(_ mode: AgentExecutionMode) {
        guard mode != viewModel.desiredExecutionMode else { return }
        if mode == .accept && !hasAcknowledgedAcceptWarning {
            isConfirmingAcceptMode = true
            return
        }
        viewModel.setExecutionMode(mode)
    }

    private func showConfirmation(for mode: AgentExecutionMode) {
        let messageID = UUID()
        confirmationID = messageID
        withAnimation {
            confirmationMessage = mode.confirmationText
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard confirmationID == messageID else { return }
            withAnimation {
                confirmationMessage = nil
            }
        }
    }

    private func selected(_ mode: AgentExecutionMode) -> Bool {
        viewModel.desiredExecutionMode == mode
    }

    private func selectionColor(_ mode: AgentExecutionMode) -> Color {
        guard selected(mode) else { return .clear }
        return mode == .accept ? AppPalette.error : AppPalette.primaryAction
    }
}

private struct ExecutionModeGuide: View {
    let selectedMode: AgentExecutionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Execution modes")
                .font(.headline)

            ForEach(AgentExecutionMode.allCases, id: \.self) { mode in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(mode == .accept ? AppPalette.error : .secondary)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(for: mode))
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                        Text(mode.helpText)
                            .font(.system(size: AppFontSize.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if mode == selectedMode {
                        Image(systemName: "checkmark")
                            .font(.system(size: AppFontSize.caption, weight: .bold))
                            .foregroundStyle(AppPalette.success)
                            .accessibilityLabel("Selected")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func title(for mode: AgentExecutionMode) -> String {
        switch mode {
        case .safe: return "Safe · Recommended"
        case .plan: return "Plan"
        case .accept: return "Accept · Up to 10 turns"
        }
    }
}

/// Renders structured hosted-agent requests such as approvals, plans, and onboarding.
