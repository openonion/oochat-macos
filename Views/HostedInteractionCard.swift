import SwiftUI
import ConnectOnionKit

/// The frame around a hosted request. An approval draws its own amber frame (`OONotice`);
/// so only the other requests get the kit's flat card.
private struct InteractionFrame: ViewModifier {
    let isApproval: Bool

    func body(content: Content) -> some View {
        if isApproval {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .ooCard()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HostedInteractionCard: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversationWidth: CGFloat

    @State private var answer = ""
    @State private var selectedOptions: Set<String> = []
    @State private var fieldValues: [String: String] = [:]
    @State private var feedback = ""
    @State private var inviteCode = ""
    @State private var isConfirmingTrust = false
    // Trust and Stop sit behind More, so the card leads with Allow once and Skip.
    @State private var showsMoreActions = false
    @State private var hoveredAskOption: String?

    init(
        viewModel: ChatViewModel,
        conversationWidth: CGFloat,
        confirmsTrust: Bool = false
    ) {
        self.viewModel = viewModel
        self.conversationWidth = conversationWidth
        _isConfirmingTrust = State(initialValue: confirmsTrust)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                if let pending = viewModel.pendingInteraction {
                    switch pending {
                    case .askUser(let request):
                        askUserContent(request)
                    case .approval(let request):
                        approvalContent(request)
                    case .onboarding(let request):
                        onboardingContent(request)
                    case .planReview(let request):
                        planReviewContent(request)
                    case .ulwCheckpoint(let request):
                        ulwCheckpointContent(request)
                    }
                }

                if let error = viewModel.interactionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(AppPalette.error)
                        .textSelection(.enabled)
                }
            }
            .modifier(InteractionFrame(isApproval: isApproval))
        }
        .frame(width: conversationWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: viewModel.pendingInteraction) {
            clearDraftInput()
        }
    }

    /// Discards every draft input when the host replaces the pending
    /// interaction.
    ///
    /// The card is identified by the constant `"hostedInteraction"` in
    /// `ChatView`, because that identity doubles as the scroll anchor, so
    /// SwiftUI treats consecutive questions as the same view and carries this
    /// `@State` across them. Without this reset an answer typed for one
    /// question arrives pre-filled on the next, with its submit button
    /// already enabled.
    private func clearDraftInput() {
        answer = ""
        selectedOptions = []
        fieldValues = [:]
        feedback = ""
        inviteCode = ""
        isConfirmingTrust = false
        showsMoreActions = false
    }

    private var isApproval: Bool {
        guard case .approval? = viewModel.pendingInteraction else { return false }
        return true
    }

    @ViewBuilder
    private func askUserContent(_ request: ConnectOnionAskUserRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Agent needs your input")
                .font(.system(size: AppFontSize.body, weight: .semibold))
                .foregroundStyle(.secondary)
        }

        Text(request.question)
            .font(.system(size: AppFontSize.sectionTitle, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

        if !request.options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.options, id: \.self) { option in
                    askOptionRow(option, multiSelect: request.multiSelect)
                }
            }
            .padding(.top, 2)
        }

        ForEach(request.fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if field.type.lowercased() == "password" {
                    SecureField(
                        field.label,
                        text: Binding(
                            get: { fieldValues[field.name, default: ""] },
                            set: { fieldValues[field.name] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    TextField(
                        field.label,
                        text: Binding(
                            get: { fieldValues[field.name, default: ""] },
                            set: { fieldValues[field.name] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }

        if request.fields.isEmpty {
            TextField("Your answer", text: $answer)
                .textFieldStyle(.roundedBorder)
        }

        Button("Submit") {
            viewModel.submitAskUser(
                answer: composedAnswer(for: request),
                displayAnswer: composedAnswer(for: request, redactPasswords: true)
            )
            answer = ""
            selectedOptions.removeAll()
            fieldValues.removeAll()
        }
        .buttonStyle(.appPrimary)
        .disabled(composedAnswer(for: request).isEmpty)
    }

    /// A single selectable choice with a radio/checkbox marker, hover feedback,
    /// and top-aligned wrapping for long option text.
    private func askOptionRow(_ option: String, multiSelect: Bool) -> some View {
        let isSelected = selectedOptions.contains(option)
        let isHovered = hoveredAskOption == option
        return Button {
            if multiSelect {
                if isSelected {
                    selectedOptions.remove(option)
                } else {
                    selectedOptions.insert(option)
                }
            } else {
                selectedOptions = [option]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: optionMarker(isSelected: isSelected, multiSelect: multiSelect))
                    .font(.system(size: AppFontSize.subheadline))
                    .foregroundStyle(isSelected ? AppPalette.primaryAction : Color.secondary)
                    .padding(.top, 1)

                Text(option)
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? AppPalette.hoverSurface
                            : (isHovered ? AppPalette.surfaceMuted : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? AppPalette.primaryAction.opacity(0.28) : AppPalette.divider,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredAskOption = option
            } else if hoveredAskOption == option {
                hoveredAskOption = nil
            }
        }
    }

    private func optionMarker(isSelected: Bool, multiSelect: Bool) -> String {
        if multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    @ViewBuilder
    private func approvalContent(_ request: ConnectOnionApprovalRequest) -> some View {
        let arguments = request.arguments.objectValue ?? [:]

        OONotice(
            .decision,
            title: OOApprovalDisclosure.summary(tool: request.tool, arguments: arguments),
            message: OOApprovalDisclosure.consequence(tool: request.tool, arguments: arguments)
        ) {
            VStack(alignment: .leading, spacing: OOSpace.medium) {
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(OOColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // What is being approved, shown in full rather than behind a disclosure.
                if let command = request.commandText {
                    approvalValueBlock(label: "COMMAND", value: command)
                }
                if let details = Self.argumentLines(arguments, hidingCommand: request.commandText != nil) {
                    approvalArguments(details)
                }

                if !request.batchRemaining.isEmpty {
                    Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                        .font(.caption)
                        .foregroundStyle(OOColor.inkSecondary)
                }

                approvalButtons
                // Kept open while the trust question is showing, so closing More can't hide it.
                if showsMoreActions || isConfirmingTrust {
                    TextField("Optional feedback", text: $feedback)
                        .textFieldStyle(.roundedBorder)
                    approvalTrust(tool: request.tool)
                    stopButton
                }
            }
        }
    }

    private static let commandArgumentKeys: Set<String> = ["command", "cmd", "script"]

    /// One `key: value` line per argument, sorted. The command keys are left out when the
    /// command already has its own block.
    static func argumentLines(_ arguments: [String: JSONValue], hidingCommand: Bool) -> String? {
        let lines = arguments
            .filter { !hidingCommand || !commandArgumentKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.stringValue ?? $0.value.displayText)" }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The arguments in the same well as the command; long content scrolls.
    private func approvalArguments(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(AppTypography.mono(size: AppFontSize.caption))
                .foregroundStyle(OOColor.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OOSpace.medium)
        }
        .frame(maxHeight: 200)
        .background(approvalWell)
    }

    /// Allow once is the one green button. Skip tool and More sit beside it.
    private var approvalButtons: some View {
        HStack(spacing: OOSpace.small) {
            Button {
                viewModel.submitApproval(.approveOnce)
            } label: {
                Text("Allow once")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ooPrimary)

            Button {
                viewModel.submitApproval(.rejectSoft(feedback: feedback))
                feedback = ""
            } label: {
                Text("Skip tool")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ooSecondary)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsMoreActions.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("More")
                    Image(systemName: showsMoreActions ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ooSecondary)
            .accessibilityValue(showsMoreActions ? "expanded" : "collapsed")
        }
    }

    /// The host trusts a whole tool for the session, not one command, so the first click only asks
    /// and names the tool. The grant is sent from the second click.
    @ViewBuilder
    private func approvalTrust(tool: String) -> some View {
        let title = OOApprovalDisclosure.trustTitle(tool: tool)

        if isConfirmingTrust {
            VStack(alignment: .leading, spacing: OOSpace.small) {
                Text("\(title) for this session?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(OOApprovalDisclosure.trustScope(tool: tool))
                    .font(.footnote)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: OOSpace.small) {
                    Button(role: .cancel) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isConfirmingTrust = false
                        }
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ooSecondary)
                    // Esc backs out; no button here takes Return, so the keyboard never grants trust.
                    .keyboardShortcut(.cancelAction)

                    Button {
                        isConfirmingTrust = false
                        viewModel.submitApproval(.approveSession)
                    } label: {
                        // The question above names what is trusted; the button only repeats the verb.
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text("Trust")
                        }
                        .foregroundStyle(OOColor.failureText)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ooSecondary)
                    .accessibilityLabel("Confirm: \(title) for this session")
                }
            }
            .padding(OOSpace.medium)
            .background(approvalWell)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isConfirmingTrust = true
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("For this session")
                        .font(.footnote)
                        .foregroundStyle(OOColor.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.ooSecondary)
        }
    }

    /// Rejects the call and stops the response.
    private var stopButton: some View {
        Button {
            viewModel.submitApproval(.rejectHard(feedback: feedback))
            feedback = ""
        } label: {
            Text("Stop response")
                .foregroundStyle(OOColor.failureText)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.ooSecondary)
        // Outlined in red so it reads as a button without competing with Allow once.
        .overlay(
            RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
                .stroke(OOColor.failureText, lineWidth: 1)
        )
    }

    /// The white, thin-bordered box the command, the raw values and the trust question sit in.
    private var approvalWell: some View {
        RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
            .fill(OOColor.paper)
            .overlay(
                RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                    .stroke(OOColor.hairline, lineWidth: 1)
            )
    }

    private func approvalValueBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AppTypography.mono(size: AppFontSize.footnote, weight: .semibold))
                .foregroundStyle(OOColor.inkSecondary)
            Text(value)
                .font(AppTypography.mono(size: AppFontSize.caption))
                .foregroundStyle(OOColor.ink)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OOSpace.medium)
        .background(approvalWell)
        .help(value)
    }

    @ViewBuilder
    private func planReviewContent(_ request: ConnectOnionPlanReviewRequest) -> some View {
        Label("Implementation plan", systemImage: "doc.text.magnifyingglass")
            .font(.headline)

        ScrollView(.vertical) {
            MarkdownMessageView(content: request.content, fontSize: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 320)

        TextField("Changes requested (optional)", text: $feedback)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("Approve & Implement") {
                viewModel.submitPlanReview(.approve)
                feedback = ""
            }
            .buttonStyle(.appPrimary)

            Button("Request Changes") {
                viewModel.submitPlanReview(.requestChanges(feedback))
                feedback = ""
            }
            .buttonStyle(.appSecondary)
            .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel", role: .destructive) {
                viewModel.submitPlanReview(.cancel)
                feedback = ""
            }
            .buttonStyle(.appSecondary)
        }
    }

    @ViewBuilder
    private func ulwCheckpointContent(
        _ request: ConnectOnionULWCheckpointRequest
    ) -> some View {
        Label("Accept mode checkpoint", systemImage: "exclamationmark.shield.fill")
            .font(.headline)
            .foregroundColor(AppPalette.error)

        Text(
            "The agent completed \(request.turnsUsed) of "
                + "\(request.maxTurns) autonomous turns without tool approvals."
        )
        .textSelection(.enabled)

        HStack {
            Button("Continue 10 Turns") {
                viewModel.submitULWCheckpoint(.continueTenTurns)
            }
            .buttonStyle(.appPrimary)

            Button("Return to Safe") {
                viewModel.submitULWCheckpoint(.returnToSafe)
            }
            .buttonStyle(.appSecondary)
        }
    }

    @ViewBuilder
    private func onboardingContent(_ request: ConnectOnionOnboardingRequest) -> some View {
        Label("Access verification required", systemImage: "lock.shield.fill")
            .font(.headline)

        if request.methods.contains("invite_code") {
            SecureField("Invite code", text: $inviteCode)
                .textFieldStyle(.roundedBorder)

            Button(viewModel.isSubmittingInteraction ? "Verifying…" : "Verify Invite Code") {
                let code = inviteCode
                inviteCode = ""
                viewModel.submitInviteCode(code)
            }
            .buttonStyle(.appPrimary)
            .disabled(
                inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isSubmittingInteraction
            )
        }

        if request.methods.contains("payment") {
            let amount = request.paymentAmount.map { String(format: "$%.2f", $0) } ?? "a payment"
            Text("This agent also accepts \(amount), but payment onboarding is not supported by this client.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let address = request.paymentAddress {
                Text(address)
                    .font(AppTypography.mono(size: AppFontSize.footnote))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func composedAnswer(
        for request: ConnectOnionAskUserRequest,
        redactPasswords: Bool = false
    ) -> String {
        var parts: [String] = []
        if !selectedOptions.isEmpty {
            parts.append(selectedOptions.sorted().joined(separator: ", "))
        }
        for field in request.fields {
            let value = fieldValues[field.name, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                let displayedValue = redactPasswords && field.type.lowercased() == "password"
                    ? "••••••"
                    : value
                parts.append("\(field.label): \(displayedValue)")
            }
        }
        let freeText = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeText.isEmpty {
            parts.append(freeText)
        }
        return parts.joined(separator: "\n")
    }
}

/// Presents agent status, capabilities, and starter prompts before the first message.
