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
    @State private var showsApprovalDetails = false
    @State private var isConfirmingTrust = false
    @State private var hoveredAskOption: String?

    init(
        viewModel: ChatViewModel,
        conversationWidth: CGFloat,
        showsApprovalDetails: Bool = false,
        confirmsTrust: Bool = false
    ) {
        self.viewModel = viewModel
        self.conversationWidth = conversationWidth
        _showsApprovalDetails = State(initialValue: showsApprovalDetails)
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
            title: request.plainEnglishExplanation,
            message: OOApprovalDisclosure.consequence(tool: request.tool, arguments: arguments)
        ) {
            VStack(alignment: .leading, spacing: OOSpace.medium) {
                if let command = request.commandText {
                    approvalValueBlock(label: "COMMAND", value: command)
                } else if let target = request.targetSummary {
                    approvalValueBlock(label: "TARGET", value: target)
                }

                approvalField(
                    label: "APPLIES TO",
                    text: OOApprovalDisclosure.scope(tool: request.tool, arguments: arguments)
                )

                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(OOColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !request.batchRemaining.isEmpty {
                    Text("\(request.batchRemaining.count) additional tool call(s) remain in this batch.")
                        .font(.caption)
                        .foregroundStyle(OOColor.inkSecondary)
                }

                approvalDetails(request)
                approvalButtons
                approvalTrust(tool: request.tool)
            }
        }
    }

    private func approvalField(label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OOSpace.small) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OOColor.inkSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(OOColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The raw values and the optional feedback line, folded until the person asks for them.
    @ViewBuilder
    private func approvalDetails(_ request: ConnectOnionApprovalRequest) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showsApprovalDetails.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsApprovalDetails ? 90 : 0))
                Text(showsApprovalDetails ? "Hide details" : "Review parameters")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(OOColor.inkSecondary)
            .frame(minHeight: ooMinimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showsApprovalDetails {
            ScrollView(.vertical) {
                Text(request.arguments.displayText)
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OOSpace.medium)
            }
            .frame(maxHeight: 150)
            .background(approvalWell)

            TextField("Optional feedback", text: $feedback)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Allow once is the one green button. Skip tool sits beside it, outlined.
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
        }
    }

    /// The host trusts a whole tool for the session, not one command, so the first click only asks
    /// and names the tool. The grant is sent from the second click. Stop -> reject and stop.
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isConfirmingTrust = false
                        }
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ooSecondary)

                    Button {
                        isConfirmingTrust = false
                        viewModel.submitApproval(.approveSession)
                    } label: {
                        Text("Confirm trust")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ooSecondary)
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

        Button {
            viewModel.submitApproval(.rejectHard(feedback: feedback))
            feedback = ""
        } label: {
            Text("Stop response")
        }
        .buttonStyle(.ooQuiet(tint: OOColor.failureText))
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
