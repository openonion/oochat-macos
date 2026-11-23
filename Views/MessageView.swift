import SwiftUI
import AppKit
import ConnectOnionKit

struct MessageView: View {
    private let messageSpacing: CGFloat = 10
    private let agentAvatarSize: CGFloat = 32

    let message: ChatMessage
    let fontSize: CGFloat
    let agentConfiguration: GeneralAgentConfiguration
    let conversationWidth: CGFloat
    let canRetry: Bool
    let artifactStore: GeneratedArtifactStore
    let onRetry: () -> Void
    /// Why this message wasn't sent, when the app still knows.
    var failure: ChatFailure?
    var canRetryFailedMessage = false
    var onRetryFailedMessage: () -> Void = {}
    /// Your latest sent message can be edited in place; Send has the agent answer it again.
    var canEdit = false
    var onEdit: (String) -> Void = { _ in }

    @State private var isHovered = false
    // The text being edited in place; nil while the bubble shows the sent message.
    @State private var editDraft: String?
    @FocusState private var isEditorFocused: Bool
    @State private var didCopy = false
    @State private var copyResetToken = UUID()
    @State private var hoverLingerToken = UUID()

    var body: some View {
        HStack(alignment: .top, spacing: messageSpacing) {
            if message.role == .user {
                // Together with the HStack spacing, this matches the agent
                // avatar inset so a long bubble cannot extend past the reply.
                Spacer(minLength: agentAvatarSize)

                VStack(alignment: .trailing, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let attachments = message.attachments,
                           !attachments.isEmpty {
                            ForEach(attachments, id: \.self) { attachment in
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.fill")
                                    Text(attachment.name)
                                        .lineLimit(1)
                                    Text(
                                        ByteCountFormatter.string(
                                            fromByteCount: Int64(attachment.byteCount),
                                            countStyle: .file
                                        )
                                    )
                                    .opacity(0.75)
                                }
                                .font(.caption)
                            }
                        }

                        if editDraft != nil {
                            messageEditor
                        } else {
                            Text(message.content)
                                .font(.system(size: fontSize))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AppPalette.surfaceMuted)
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            if editDraft != nil {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(OOColor.primary, lineWidth: 1.5)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if message.status == .error {
                        failedStatus
                    } else if message.status != .sent {
                        Text(messageStatusText)
                            .font(.caption2)
                            .foregroundColor(message.status == .error ? AppPalette.error : .secondary)
                    }

                    if editDraft != nil {
                        editorButtons
                    } else if !message.content.isEmpty {
                        messageActions
                    }
                }
                .containerRelativeFrame(.horizontal, alignment: .trailing) { availableWidth, _ in
                    min(availableWidth, conversationWidth) * 0.8
                }
            } else if message.role == .agent {
                AgentAvatarView(
                    name: agentConfiguration.name,
                    textColorHex: agentConfiguration.avatarTextColorHex,
                    backgroundColorHex: agentConfiguration.avatarBackgroundColorHex,
                    size: agentAvatarSize
                )

                VStack(alignment: .leading, spacing: 10) {
                    if let imageURL = message.imageURL,
                       let url = URL(string: imageURL) {
                        AgentRemoteImage(url: url)
                    }

                    if !message.content.isEmpty {
                        MarkdownMessageView(
                            content: message.content,
                            fontSize: fontSize
                        )
                        messageActions
                    }

                    if let artifacts = message.artifacts {
                        ForEach(artifacts) { artifact in
                            GeneratedArtifactCard(
                                reference: artifact,
                                store: artifactStore
                            )
                        }
                    }

                    if let warnings = message.artifactWarnings {
                        // Identify by position, not by value: a message that
                        // exceeds the export budget appends the same warning
                        // string once per dropped artifact, and duplicate
                        // ForEach ids are undefined behaviour in SwiftUI.
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.system(size: AppFontSize.footnote))
                                .foregroundStyle(AppPalette.error)
                        }
                    }
                }
                    .padding(.top, 4)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            } else {
                Spacer()
                Text(message.content)
                    .font(.system(size: fontSize - 2))

                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                Spacer()
            }
        }
        .frame(width: conversationWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .onHover(perform: updateHover)
    }

    /// Hover-revealed action row, reserved at a fixed height so messages
    /// never shift when it appears.
    private var messageActions: some View {
        HStack(spacing: 4) {
            Button(action: copyMessage) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: AppFontSize.footnote, weight: .medium))

                    if didCopy {
                        Text("Copied")
                            .font(.system(size: AppFontSize.footnote, weight: .medium))
                    }
                }
                // editing the size of copy button based on UI feedback
                .foregroundStyle(didCopy ? AppPalette.success : Color.secondary)
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied" : "Copy message")
            .help(didCopy ? "Copied" : "Copy message")

            if message.role == .user && canEdit {
                Button {
                    editDraft = message.content
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: AppFontSize.footnote, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit message")
                .help("Edit and send again")
            }

            // Only the latest reply can be retried, so the button only shows there.
            if message.role == .agent && canRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(
                                .system(
                                    size: AppFontSize.footnote,
                                    weight: .medium
                                )
                            )
                    }
                    // edit retry button based on UI feedback.
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry message")
                .help("Retry: the agent answers your message again")
            }
        }
        // adjust row container to account for larger UI buttons.
        .frame(height: 28)
        .opacity(isHovered || didCopy ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover(perform: updateHover)
    }

    /// Your message, editable where it sits. Return sends, Escape cancels.
    private var messageEditor: some View {
        TextField(
            "Message",
            text: Binding(get: { editDraft ?? "" }, set: { editDraft = $0 }),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: fontSize))
        .lineSpacing(3)
        .lineLimit(1...12)
        .focused($isEditorFocused)
        .onSubmit(sendEdit)
        .onExitCommand { editDraft = nil }
        .onAppear { isEditorFocused = true }
    }

    private var editorButtons: some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                editDraft = nil
            }
            .buttonStyle(InlineEditButtonStyle(isPrimary: false))
            Button("Send", action: sendEdit)
                .buttonStyle(InlineEditButtonStyle(isPrimary: true))
                .disabled(!canSendEdit)
        }
        .fixedSize()
    }

    private var trimmedEdit: String {
        (editDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSendEdit: Bool {
        !trimmedEdit.isEmpty && trimmedEdit != message.content
    }

    private func sendEdit() {
        guard canSendEdit else { return }
        onEdit(trimmedEdit)
        editDraft = nil
    }

    /// macOS hover tracking flickers when the cursor crosses child views
    /// (selectable text, buttons), so hiding is delayed: the actions row
    /// fades out only after the cursor has been away for a moment.
    private func updateHover(_ hovering: Bool) {
        let token = UUID()
        hoverLingerToken = token

        if hovering {
            isHovered = true
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard hoverLingerToken == token else { return }
            isHovered = false
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)

        let token = UUID()
        copyResetToken = token

        withAnimation(.easeInOut(duration: 0.12)) {
            didCopy = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard copyResetToken == token else { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                didCopy = false
            }
        }
    }

    private var messageStatusText: String {
        switch message.status {
        case .sending:
            return "Sending…"
        case .queued:
            return "Queued while agent is running"
        case .sent:
            return ""
        case .error:
            return "Not sent"
        }
    }

    /// "Not sent · Retry", then why. Hover the reason for the original error text.
    private var failedStatus: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Label("Not sent", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(AppPalette.error)
                if canRetryFailedMessage {
                    Button("Retry", action: onRetryFailedMessage)
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OOColor.primary)
                        .accessibilityLabel("Retry sending message")
                }
            }
            if let failure {
                let reason = failure.sentence(agentName: agentConfiguration.name)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(OOColor.inkSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(failure.details ?? reason)
            }
        }
    }
}

/// Presents an Agent-generated file without granting the container host access.

/// Cancel and Send under a message being edited. The Kit's OO styles keep a 44pt touch height;
/// a pointer control inline with a message reads better at 28pt, the same as the hover actions.
private struct InlineEditButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
        let fill = isPrimary ? OOColor.primary : OOColor.paper
        let ink = isPrimary ? OOColor.onPrimary : OOColor.ink
        configuration.label
            .font(.subheadline.weight(isPrimary ? .semibold : .medium))
            .foregroundStyle(isEnabled ? ink : OOColor.inkTertiary)
            .padding(.horizontal, OOSpace.medium)
            .frame(height: 28)
            .background(isEnabled ? fill : OOColor.hover, in: shape)
            .overlay {
                if !isPrimary {
                    shape.stroke(OOColor.hairline, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}
