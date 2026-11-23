import SwiftUI
import ConnectOnionKit

struct PendingAttachmentChip: View {
    let attachment: ConnectOnionInputFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.fill")
                .foregroundColor(AppPalette.brand)

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
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Attachment")
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
            // The native control doesn't colour a segment, so Full access says it's on beside it,
            // in the approval card's amber: the agent runs tools without asking.
            if viewModel.desiredExecutionMode == .accept {
                Label("Full access", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppFontSize.footnote, weight: .semibold))
                    .foregroundStyle(OOColor.decisionText)
                    .labelStyle(.titleAndIcon)
                    .help(AgentExecutionMode.accept.helpText)
                    .accessibilityLabel("Full access is on")
            }
            // The system segmented control at regular size (story 162): a full-height target,
            // keyboard focus and VoiceOver come with it. The ⓘ beside it explains each mode.
            Picker("Permission mode", selection: Binding(get: { viewModel.desiredExecutionMode }, set: select)) {
                ForEach(viewModel.offeredExecutionModes, id: \.self) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .fixedSize()
            .disabled(!viewModel.canChangeExecutionMode)
            .help(viewModel.desiredExecutionMode.helpText)

            Button {
                isShowingModeGuide.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: AppFontSize.footnote, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Explain permission modes")
            .help("Explain permission modes")
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
        .alert("Enable Full access?", isPresented: $isConfirmingAcceptMode) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Full access", role: .destructive) {
                hasAcknowledgedAcceptWarning = true
                viewModel.setExecutionMode(.accept)
            }
        } message: {
            Text(
                "Full access lets the agent use enabled tools without "
                    + "approval for the turns the host allows."
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
}

private struct ExecutionModeGuide: View {
    let selectedMode: AgentExecutionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permission mode")
                .font(.headline)

            ForEach(AgentExecutionMode.allCases, id: \.self) { mode in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(mode == .accept ? OOColor.decisionText : .secondary)
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
        case .safe: return "Auto · Recommended"
        case .plan: return "Read only"
        case .accept: return "Full access"
        }
    }
}

/// Takes the composer's place in a chat from a previous identity: the agent no longer knows this
/// Address's old session, so the only way on is a new chat with it.
struct PreviousIdentityComposerBar: View {
    let onStartNewChat: () -> Void

    var body: some View {
        HStack(spacing: OOSpace.medium) {
            Label(PreviousIdentity.label, systemImage: "clock.arrow.circlepath")
                .font(.system(size: AppFontSize.body))
                .foregroundStyle(OOColor.inkSecondary)
            Spacer()
            Button(PreviousIdentity.startNewChat, action: onStartNewChat)
                .buttonStyle(.ooPrimary)
        }
        .padding(OOSpace.medium)
        .background(OOColor.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(OOColor.hairline, lineWidth: 1)
        }
    }
}

/// Renders structured hosted-agent requests such as approvals, plans, and onboarding.
