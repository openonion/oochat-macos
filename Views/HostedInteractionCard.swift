import SwiftUI

struct HostedInteractionCard: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversationWidth: CGFloat

    @State private var answer = ""
    @State private var selectedOptions: Set<String> = []
    @State private var fieldValues: [String: String] = [:]
    @State private var feedback = ""
    @State private var inviteCode = ""
    @State private var showsApprovalDetails = false
    @State private var showsApprovalOptions = false
    @State private var hoveredApprovalOption: String?
    @State private var hoveredAskOption: String?
    @State private var isApprovalChevronHovered = false

    init(
        viewModel: ChatViewModel,
        conversationWidth: CGFloat,
        showsApprovalDetails: Bool = false,
        showsApprovalOptions: Bool = false
    ) {
        self.viewModel = viewModel
        self.conversationWidth = conversationWidth
        _showsApprovalDetails = State(initialValue: showsApprovalDetails)
        _showsApprovalOptions = State(initialValue: showsApprovalOptions)
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
            .padding(isApproval ? 20 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: isApproval ? 22 : 18)
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
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: approvalIcon(for: request))
                .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            Text(approvalCategory(for: request))
                .font(.system(size: AppFontSize.body, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()
        }

        Text(request.plainEnglishExplanation)
            .font(.system(size: AppFontSize.sectionTitle, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

        if let description = request.description, !description.isEmpty {
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if let command = request.commandText {
            approvalValueBlock(label: "COMMAND", value: command)
        } else if let target = request.targetSummary {
            approvalValueBlock(label: "TARGET", value: target)
        }

        if !request.batchRemaining.isEmpty {
            Text("\(request.batchRemaining.count) additional tool call(s) remain in this batch.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

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
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showsApprovalDetails {
            ScrollView(.vertical) {
                Text(request.arguments.displayText)
                    .font(AppTypography.mono(size: AppFontSize.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 150)
            .background(AppPalette.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            TextField("Optional feedback", text: $feedback)
                .textFieldStyle(.roundedBorder)
        }

        HStack(spacing: 10) {
            Spacer()

            Button("Reject", role: .destructive) {
                viewModel.submitApproval(.rejectHard(feedback: feedback))
                feedback = ""
            }
            .buttonStyle(.plain)
            .font(.system(size: AppFontSize.body, weight: .semibold))
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(AppPalette.surfaceMuted, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppPalette.divider, lineWidth: 1)
            }

            approvalSplitButton
        }
    }

    private var approvalSplitButton: some View {
        HStack(spacing: 0) {
            Button("Allow Once") {
                viewModel.submitApproval(.approveOnce)
            }
            .buttonStyle(.plain)
            .font(.system(size: AppFontSize.body, weight: .semibold))
            .foregroundStyle(AppPalette.primaryActionForeground)
            .padding(.leading, 18)
            .padding(.trailing, 13)
            .frame(height: 38)

            Rectangle()
                .fill(AppPalette.primaryActionForeground.opacity(0.18))
                .frame(width: 1, height: 18)

            Button {
                showsApprovalOptions.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: AppFontSize.caption, weight: .bold))
                    .foregroundStyle(AppPalette.primaryActionForeground)
                    .rotationEffect(.degrees(showsApprovalOptions ? 180 : 0))
                    .frame(width: 40, height: 38)
                    .background(
                        AppPalette.primaryActionForeground.opacity(
                            isApprovalChevronHovered ? 0.09 : 0
                        )
                    )
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.15), value: showsApprovalOptions)
            }
            .buttonStyle(.plain)
            .onHover { isApprovalChevronHovered = $0 }
            .accessibilityLabel("More approval options")
            .help("More approval options")
            .popover(
                isPresented: $showsApprovalOptions,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                approvalOptionsPopover
            }
        }
        .background(AppPalette.primaryAction)
        .clipShape(Capsule())
    }

    var approvalOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approval options")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            approvalOptionButton(
                title: "Always Allow",
                detail: "Allow this tool for the rest of this session",
                systemImage: "checkmark.shield"
            ) {
                showsApprovalOptions = false
                viewModel.submitApproval(.approveSession)
            }

            approvalOptionButton(
                title: "Skip This Action",
                detail: "Continue without running this tool",
                systemImage: "forward"
            ) {
                showsApprovalOptions = false
                viewModel.submitApproval(.rejectSoft(feedback: feedback))
                feedback = ""
            }
        }
        .padding(8)
        .frame(width: 290)
    }

    private func approvalOptionButton(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        hoveredApprovalOption == title
                            ? AppPalette.hoverSurface
                            : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredApprovalOption = hovering ? title : nil
        }
    }

    private func approvalValueBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(AppTypography.mono(size: AppFontSize.footnote, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppTypography.mono(size: AppFontSize.caption))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(AppPalette.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(value)
    }

    private func approvalIcon(for request: ConnectOnionApprovalRequest) -> String {
        let tool = request.tool.lowercased()
        if ["shell", "command", "execute", "bash"].contains(where: tool.contains) {
            return "terminal"
        }
        if ["write", "edit", "file", "patch", "delete"].contains(where: tool.contains) {
            return "doc.text"
        }
        if ["send", "mail", "reply"].contains(where: tool.contains) {
            return "envelope"
        }
        return "hand.raised"
    }

    private func approvalCategory(for request: ConnectOnionApprovalRequest) -> String {
        let tool = request.tool.lowercased()
        if ["shell", "command", "execute", "bash"].contains(where: tool.contains) {
            return "Terminal"
        }
        if ["write", "edit", "file", "patch", "delete"].contains(where: tool.contains) {
            return "File change"
        }
        if ["send", "mail", "reply"].contains(where: tool.contains) {
            return "External message"
        }
        return "Agent action"
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
