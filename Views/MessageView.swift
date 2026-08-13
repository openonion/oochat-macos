import SwiftUI
import AppKit

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

    @State private var isHovered = false
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

                        Text(message.content)
                            .font(AppTypography.mono(size: fontSize))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(AppPalette.surfaceMuted)
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    if message.status != .sent {
                        Text(messageStatusText)
                            .font(.caption2)
                            .foregroundColor(message.status == .error ? AppPalette.error : .secondary)
                    }

                    if !message.content.isEmpty {
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
                .foregroundStyle(didCopy ? AppPalette.success : Color.secondary)
                .frame(height: 20)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied" : "Copy message")
            .help(didCopy ? "Copied" : "Copy message")

            if message.role == .agent {
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
                    .foregroundStyle(Color.secondary)
                    .frame(height: 20)
                    .padding(.horizontal, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRetry)
                .opacity(canRetry ? 1 : 0.35)
                .accessibilityLabel("Retry message")
                .help(canRetry ? "Retry" : "Retry unavailable")
            }
        }
        .frame(height: 20)
        .opacity(isHovered || didCopy ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover(perform: updateHover)
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
            return "Not delivered"
        }
    }
}

/// Presents an Agent-generated file without granting the container host access.
