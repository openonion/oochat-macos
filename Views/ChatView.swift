import SwiftUI
import AppKit

/// Selects the messages, execution runs, and approvals visible in the chat.
struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    let conversationWidth: CGFloat
    let historySelectionRevision: Int

    @AppStorage("chatFontSize") private var chatFontSize: Double = 15
    @State private var keyMonitor: Any?
    @State private var isFileDropTargeted = false
    @FocusState private var isInputFocused: Bool

    private let minChatFontSize: Double = 12
    private let maxChatFontSize: Double = 26
    private let chatFontStep: Double = 1

    init(
        viewModel: ChatViewModel,
        conversationWidth: CGFloat,
        historySelectionRevision: Int = 0,
        isFileDropTargeted: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.conversationWidth = conversationWidth
        self.historySelectionRevision = historySelectionRevision
        _isFileDropTargeted = State(initialValue: isFileDropTargeted)
    }

    var body: some View {
        ZStack {
            AppBackground()

            chatBody

            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppPalette.primaryAction.opacity(0.06))
                    .stroke(
                        AppPalette.primaryAction,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .padding(16)
                    .overlay {
                        Label("Drop files to attach", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(AppPalette.primaryAction)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isChatConnected)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addAttachments(from: urls)
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isFileDropTargeted = isTargeted
            }
        }
        .navigationTitle("")
        .toolbarBackground(AppPalette.toolbarSurface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private var hasStartedConversation: Bool {
        ChatViewPresentation.hasStartedConversation(viewModel.messages)
    }

    private var pendingApproval: ConnectOnionApprovalRequest? {
        ChatViewPresentation.approvalRequest(from: viewModel.pendingInteraction)
    }

    private func executionRuns(for message: ChatMessage) -> [ExecutionRun] {
        ChatViewPresentation.executionRuns(
            for: message,
            from: viewModel.executionRuns
        )
    }

    private var unlinkedExecutionRuns: [ExecutionRun] {
        ChatViewPresentation.unlinkedExecutionRuns(from: viewModel.executionRuns)
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            if !hasStartedConversation {
                WelcomeHomeView(
                    configuration: viewModel.configuration,
                    isConnected: viewModel.isConfigurationConnected,
                    connectionSnapshot: viewModel.connectionSnapshot
                ) { prompt in
                    viewModel.inputText = prompt
                }
            } else {
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            Color.clear
                                .frame(height: 1)
                                .id("topOfChat")

                            ForEach(viewModel.messages) { message in
                                MessageView(
                                    message: message,
                                    fontSize: chatFontSize,
                                    agentConfiguration: viewModel.configuration,
                                    conversationWidth: conversationWidth,
                                    canRetry: viewModel.canRetryAgentMessage(message),
                                    artifactStore: viewModel.appViewModel
                                        .generatedArtifactStore,
                                    onRetry: {
                                        viewModel.retryAgentMessage(message)
                                    }
                                )
                                    .id(message.id)

                                ForEach(executionRuns(for: message)) { run in
                                    ExecutionFlowView(
                                        run: run,
                                        messageFontSize: chatFontSize,
                                        conversationWidth: conversationWidth
                                    )
                                        .id(run.id)
                                }
                            }

                            ForEach(unlinkedExecutionRuns) { run in
                                ExecutionFlowView(
                                    run: run,
                                    messageFontSize: chatFontSize,
                                    conversationWidth: conversationWidth
                                )
                                    .id(run.id)
                            }

                            if viewModel.pendingInteraction != nil,
                               pendingApproval == nil {
                                HostedInteractionCard(
                                    viewModel: viewModel,
                                    conversationWidth: conversationWidth
                                )
                                    .id("hostedInteraction")
                            }

                            if let recoveryStatus = viewModel.recoveryStatus {
                                HStack {
                                    Label(recoveryStatus, systemImage: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button("Retry") {
                                        viewModel.retryRecovery()
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .cardStyle(cornerRadius: 12)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottomOfChat")
                        }
                        .padding()
                    }
                    .scrollContentBackground(.hidden)
                    .onAppear {
                        scrollToLastUserMessage(using: proxy)
                    }
                    .onChange(of: historySelectionRevision) {
                        scrollToLastUserMessage(using: proxy)
                    }
                    .onChange(of: viewModel.messages.count) {
                        withAnimation {
                            proxy.scrollTo("bottomOfChat", anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.pendingInteraction) { _, interaction in
                        if interaction != nil, pendingApproval == nil {
                            withAnimation {
                                proxy.scrollTo("hostedInteraction", anchor: .bottom)
                            }
                        }
                    }

                    HStack {
                        Button("") {
                            withAnimation {
                                proxy.scrollTo("topOfChat", anchor: .top)
                            }
                        }
                        .keyboardShortcut(.upArrow, modifiers: [.command])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)

                        Button("") {
                            withAnimation {
                                proxy.scrollTo("bottomOfChat", anchor: .bottom)
                            }
                        }
                        .keyboardShortcut(.downArrow, modifiers: [.command])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    }
                    .frame(width: 0, height: 0)
                }
            }
            }

            VStack(alignment: .trailing, spacing: 6) {
                if let usage = viewModel.latestUsage {
                    ChatUsageSummaryView(usage: usage)
                        .padding(.trailing, 6)
                }

                if pendingApproval != nil {
                    HostedInteractionCard(
                        viewModel: viewModel,
                        conversationWidth: conversationWidth
                    )
                    .id("approvalComposer")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                VStack(alignment: .leading, spacing: 8) {
                if !viewModel.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.pendingAttachments) { attachment in
                                PendingAttachmentChip(attachment: attachment) {
                                    viewModel.removeAttachment(attachment)
                                }
                            }
                        }
                    }
                }

                if let error = viewModel.attachmentError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(AppPalette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = viewModel.voiceInputService.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(AppPalette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.voiceInputService.isTranscribing {
                    Label("Transcribing with ConnectOnion…", systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    Button(action: openFilePanel) {
                        Image(systemName: "plus")
                            .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(AppPalette.surfaceMuted)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canAttachFiles)
                    .accessibilityLabel("Attach files")
                    .help(viewModel.fileInputHelpText)

                    TextField(
                        "Type a message to ConnectOnion agent…",
                        text: $viewModel.inputText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .font(AppTypography.mono(size: chatFontSize))
                    .lineLimit(1...5)
                    .disabled(viewModel.pendingInteraction != nil)
                    .onSubmit {
                        viewModel.sendMessage()
                    }

                    Button(action: viewModel.toggleVoiceInput) {
                        Image(systemName: viewModel.voiceInputService.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                            .foregroundColor(voiceButtonForeground)
                            .frame(width: 30, height: 30)
                            .background(voiceButtonBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        viewModel.pendingInteraction != nil
                            || viewModel.voiceInputService.isTranscribing
                    )
                    .accessibilityLabel(voiceInputHelpText)
                    .help(voiceInputHelpText)

                    Button(action: performPrimaryInputAction) {
                        Image(systemName: primaryInputButtonSystemImage)
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundColor(AppPalette.primaryActionForeground)
                        .frame(width: 30, height: 30)
                        .background(sendButtonBackground)
                        .clipShape(Circle())
                    }
                    .disabled(!canPerformPrimaryInputAction)
                    .buttonStyle(.plain)
                    .accessibilityLabel(primaryInputButtonHelpText)
                    .help(primaryInputButtonHelpText)
                }

                HStack(spacing: 8) {
                    connectionStatusChip

                    Spacer()

                    if viewModel.showsExecutionModeSelector {
                        if viewModel.isExecutionModeChangePending {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Waiting for the hosted agent to confirm the mode")
                        }
                        ExecutionModeSelector(viewModel: viewModel)
                    }
                }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .cardStyle(cornerRadius: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            isInputFocused
                                ? AppPalette.primaryAction.opacity(0.35)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isInputFocused)
                }
            }
            .padding(.bottom, 14)
            .padding(.top, 4)
            .frame(width: conversationWidth)
        }
        .onAppear {
            viewModel.connectIfNeeded()
            viewModel.startStatusMonitoring()

            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleKeyDown(event)
                }
            }
        }
        .onDisappear {
            viewModel.stopStatusMonitoring()

            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }

    private func scrollToLastUserMessage(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            if let messageID = ChatViewPresentation.lastUserMessageID(
                in: viewModel.messages
            ) {
                proxy.scrollTo(messageID, anchor: .top)
            } else {
                proxy.scrollTo("bottomOfChat", anchor: .bottom)
            }
        }
    }

    private var sendButtonBackground: Color {
        if !canPerformPrimaryInputAction {
            return Color.secondary.opacity(0.4)
        } else {
            return AppPalette.primaryAction
        }
    }

    private var canPerformPrimaryInputAction: Bool {
        viewModel.canInterruptAgent
            ? !viewModel.isInterruptRequested
            : viewModel.canSendMessage
    }

    private var primaryInputButtonSystemImage: String {
        viewModel.canInterruptAgent
            ? "stop.fill"
            : "paperplane.fill"
    }

    private var primaryInputButtonHelpText: String {
        if viewModel.isInterruptRequested {
            return viewModel.isInterruptEscalating
                ? "Force stopping request"
                : "Stop requested"
        }
        return viewModel.canInterruptAgent
            ? "Stop agent"
            : "Send message"
    }

    private func performPrimaryInputAction() {
        if viewModel.canInterruptAgent {
            viewModel.interruptAgent()
        } else {
            viewModel.sendMessage()
        }
    }

    private var voiceButtonBackground: Color {
        if viewModel.voiceInputService.isRecording {
            return AppPalette.error.opacity(0.15)
        } else {
            return AppPalette.surfaceMuted
        }
    }

    private var voiceButtonForeground: Color {
        if viewModel.voiceInputService.isRecording {
            return AppPalette.error
        } else {
            return .primary
        }
    }

    private var voiceInputHelpText: String {
        if viewModel.voiceInputService.isTranscribing {
            return "Transcribing with ConnectOnion"
        }
        return viewModel.voiceInputService.isRecording
            ? "Stop and transcribe voice input"
            : "Start voice input"
    }

    private var isChatConnected: Bool {
        if viewModel.configuration.connectionType == .byAddress {
            return viewModel.isConfigurationConnected
        }
        return viewModel.service.isConnected
    }

    /// Always-visible status chip shown in the input card's bottom row.
    private var connectionStatusChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isChatConnected ? AppPalette.success : AppPalette.error)
                .frame(width: 6, height: 6)

            Text(isChatConnected ? "live" : "error")
                .font(AppTypography.mono(size: AppFontSize.footnote, weight: .semibold))
                .foregroundColor(isChatConnected ? AppPalette.success : AppPalette.error)
        }
        .help(
            isChatConnected
                ? "Connected to the agent"
                : "Not connected to the agent"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isChatConnected ? "Connected" : "Disconnected")
    }

    private func increaseFontSize() {
        chatFontSize = min(chatFontSize + chatFontStep, maxChatFontSize)
    }

    private func decreaseFontSize() {
        chatFontSize = max(chatFontSize - chatFontStep, minChatFontSize)
    }

    private func resetFontSize() {
        chatFontSize = 15
    }

    private func openFilePanel() {
        guard viewModel.canAttachFiles else { return }

        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        panel.begin { response in
            guard response == .OK else { return }
            viewModel.addAttachments(from: panel.urls)
        }
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags.contains(.command) else {
            return event
        }

        switch event.charactersIgnoringModifiers {
        case "=", "+":
            increaseFontSize()
            return nil

        case "-":
            decreaseFontSize()
            return nil

        case "0":
            resetFontSize()
            return nil

        default:
            return event
        }
    }
}

/// Shows the latest session usage in a single compact line.
