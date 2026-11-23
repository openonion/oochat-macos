import SwiftUI
import AppKit
import ConnectOnionKit

/// Selects the messages, execution runs, and approvals visible in the chat.
struct ChatView: View {
    @StateObject var viewModel: ChatViewModel
    private let fullConversationWidth: CGFloat
    let historySelectionRevision: Int

    @AppStorage("chatFontSize") private var chatFontSize: Double = 15
    @AppStorage("isControlCenterOpen") private var isControlCenterOpen = true
    @AppStorage("controlCenterPaneWidth") private var paneWidth = Double(ControlCenterPaneWidth.initial)
    @State private var dragStartWidth: Double?
    @State private var detailWidth: CGFloat = 0
    @State private var keyMonitor: Any?
    @State private var isFileDropTargeted = false
    /// When this chat started connecting; the chip turns "Connecting…" into "Can't connect" after 10 s.
    @State private var connectingSince: Date?
    @FocusState private var isInputFocused: Bool
    @State private var selectedSkillIndex = 0
    @State private var isKeyboardNavigatingSkills = false
    /// Whether you're at (or near) the bottom. Scrolled up, new messages don't pull you down.
    @State private var isAtBottom = true
    /// About 1.5 windows above the newest message; only then does Jump to latest show.
    @State private var isFarFromLatest = false
    /// Something new arrived while you were scrolled up; shown as a dot on Jump to latest.
    @State private var hasUnseenLatest = false

    private let minChatFontSize: Double = 12
    private let maxChatFontSize: Double = 26
    private let chatFontStep: Double = 1
    private let skillPaletteMaxHeight: CGFloat = 240
    private let skillPaletteRowHeight: CGFloat = 44

    init(
        viewModel: ChatViewModel,
        conversationWidth: CGFloat,
        historySelectionRevision: Int = 0,
        isFileDropTargeted: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.fullConversationWidth = conversationWidth
        self.historySelectionRevision = historySelectionRevision
        _isFileDropTargeted = State(initialValue: isFileDropTargeted)
    }

    var body: some View {
        content
            // The agent pane reads this chat's Work Rooms, skills and Control Center from here.
            .onAppear {
                viewModel.appViewModel.activeChat = viewModel
            }
            .onDisappear {
                if viewModel.appViewModel.activeChat === viewModel {
                    viewModel.appViewModel.activeChat = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isStation {
            stationDetail
        } else if let openWorkRoomID = viewModel.openWorkRoomID,
                  let workRoom = viewModel.workRooms.workRoom(id: openWorkRoomID) {
            workRoomDetail(workRoom)
        } else {
            chatDetail
        }
    }

    private func workRoomView(_ workRoom: WorkRoom) -> some View {
        OOWorkRoomView(
            workRoom: workRoom,
            onDecide: { viewModel.workRooms.decide($0, in: workRoom.id) },
            onStop: { viewModel.workRooms.stop(in: workRoom.id) },
            onDraftChange: { viewModel.workRooms.setDraft($0, in: workRoom.id) },
            onSend: { viewModel.workRooms.send(in: workRoom.id) },
            onChangePermission: { viewModel.workRooms.changePermission(to: $0, confirmRisk: $1, in: workRoom.id) },
            onChangeControl: { viewModel.workRooms.changeControl($0, in: workRoom.id) },
            mic: viewModel.workRoomMic(for: workRoom.id)
        )
        .onChange(of: workRoom.composer.canDictate) { _, canDictate in
            if !canDictate { viewModel.cancelDictation(in: workRoom.id) }
        }
        .onDisappear { viewModel.cancelDictation(in: workRoom.id) }
    }

    /// The Work Room takes the whole detail pane. The Control Center pane and its toggle are not
    /// drawn here, and their saved state is not touched, so Back restores them exactly.
    private func workRoomDetail(_ workRoom: WorkRoom) -> some View {
        workRoomView(workRoom)
            // Reconnects after each turn; a running turn uses its own socket.
            .task(id: "\(viewModel.service.isAgentRequestActive)-\(viewModel.service.connectionGeneration)") {
                await viewModel.service.holdWorkRoomConnection()
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.openWorkRoomID = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Back to the chat")
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
            .toolbarBackground(AppPalette.toolbarSurface, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }

    private var chatDetail: some View {
        HStack(spacing: 0) {
            chatColumn

            if let dashboard = viewModel.dashboard, let shownWidth = shownPaneWidth {
                paneResizeHandle
                OOControlCenterPane(
                    dashboard: dashboard,
                    skills: viewModel.agentProfile?.skills,
                    onRunSkill: viewModel.runControlCenterSkill,
                    onCollapse: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isControlCenterOpen = false
                    }
                })
                .frame(width: shownWidth)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { detailWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in detailWidth = width }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.dashboard != nil {
                    OOControlCenterButton(isOpen: isControlCenterOpen) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isControlCenterOpen.toggle()
                        }
                    }
                }
            }
        }
    }

    /// The pane's width on screen: the saved width, cut down so the chat keeps `minimumChatWidth`.
    /// nil when the pane is closed or no dashboard.
    /// The saved width is left alone, so the pane comes back at its old size when the window grows.
    private var shownPaneWidth: CGFloat? {
        guard viewModel.dashboard != nil, isControlCenterOpen else { return nil }
        guard detailWidth > 0 else { return CGFloat(ControlCenterPaneWidth.clamped(paneWidth)) }
        return CGFloat(ControlCenterPaneWidth.fitted(paneWidth, in: Double(detailWidth)))
    }

    /// What the user sees, so a drag or an arrow key starts from the visible edge, not a hidden wider one.
    private var currentPaneWidth: Double {
        shownPaneWidth.map { Double($0) } ?? paneWidth
    }

    /// The reading column narrows by the pane's width, so the pane never covers the chat.
    private var conversationWidth: CGFloat {
        guard let pane = shownPaneWidth, detailWidth > 0 else {
            return fullConversationWidth
        }
        let chatWidth = detailWidth - pane - ControlCenterPaneWidth.handleWidth
        return min(fullConversationWidth, max(0, chatWidth - 48))
    }

    /// A one-point hairline with a wider grab area; drag, or use the arrow keys, to resize
    /// (oo-chat use-pane-width.ts). The pane is on the right, so dragging left widens it.
    private var paneResizeHandle: some View {
        Rectangle()
            .fill(OOColor.hairline)
            .frame(width: 1)
            .frame(width: ControlCenterPaneWidth.handleWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartWidth ?? currentPaneWidth
                    dragStartWidth = start
                    paneWidth = ControlCenterPaneWidth.clamped(start - value.translation.width)
                }
                .onEnded { _ in dragStartWidth = nil }
            )
            .focusable()
            .onKeyPress(.leftArrow) {
                paneWidth = ControlCenterPaneWidth.clamped(currentPaneWidth + ControlCenterPaneWidth.keyStep)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                paneWidth = ControlCenterPaneWidth.clamped(currentPaneWidth - ControlCenterPaneWidth.keyStep)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Resize Control Center")
            .accessibilityValue("\(Int(currentPaneWidth)) points")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? ControlCenterPaneWidth.keyStep : -ControlCenterPaneWidth.keyStep
                paneWidth = ControlCenterPaneWidth.clamped(currentPaneWidth + step)
            }

    }

    private var chatColumn: some View {
        ZStack {
            OOColor.surface
                .ignoresSafeArea()

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
        .animation(.easeInOut(duration: 0.2), value: viewModel.connectionStatus().isLive)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addAttachments(from: urls)
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isFileDropTargeted = isTargeted
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.incompatibility != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.incompatibility = nil
                    }
                }
            )
        ) {
            if let incompatibility = viewModel.incompatibility {
                IncompatibleAgentView(incompatibility: incompatibility) {
                    viewModel.incompatibility = nil
                }
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

    private var skillPaletteQuery: String? {
        let text = viewModel.inputText

        guard text.hasPrefix("/") else { return nil }

        let query = String(text.dropFirst())

        // Only show the palette while entering the skill name, not after the user has started entering arguments.
        guard !query.contains(where: \.isWhitespace) else {
            return nil
        }

        return query
    }

    private var filteredSkills: [OIPAgentSkill] {
        guard let skills = viewModel.agentProfile?.skills,
              let query = skillPaletteQuery else {
            return []
        }

        let rankedNames = SkillSearch.rank(
            skills.map(\.name),
            query: query
        )

        return rankedNames.compactMap { name in
            skills.first { $0.name == name }
        }
    }

    private var skillPalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if filteredSkills.isEmpty {
                            Text(
                                viewModel.agentProfile == nil
                                    ? "Loading agent skills…"
                                    : (viewModel.agentProfile?.skills.isEmpty == true
                                        ? "This agent has no skills."
                                        : "No matching skills.")
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                        } else {
                            ForEach(
                                Array(filteredSkills.enumerated()),
                                id: \.element.name
                            ) { index, skill in
                                Button {
                                    viewModel.inputText = "/\(skill.name) "
                                    isInputFocused = true
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text("/\(skill.name)")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(OOColor.ink)
                                            .fixedSize(horizontal: true, vertical: false)

                                        if let description = skill.description,
                                           !description.isEmpty {
                                            Text(description)
                                                .font(.system(size: 13))
                                                .foregroundStyle(OOColor.inkSecondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }

                                        Spacer(minLength: 0)
                                    }
                                    .ooRow(isSelected: index == selectedSkillIndex)
                                    .onHover { isHovering in
                                        guard isHovering, !isKeyboardNavigatingSkills else { return }
                                        selectedSkillIndex = index
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(skill.name)
                            }
                        }
                    }
                }
                .frame(
                    height: min(
                        CGFloat(filteredSkills.count) * skillPaletteRowHeight,
                        skillPaletteMaxHeight
                    )
                )
                .onChange(of: selectedSkillIndex) { _, newIndex in
                    guard filteredSkills.indices.contains(newIndex) else {
                        return
                    }

                    withAnimation {
                        proxy.scrollTo(
                            filteredSkills[newIndex].name,
                            anchor: .center
                        )
                    }
                }
                .onChange(of: filteredSkills.map(\.name)) { _, _ in
                    proxy.scrollTo(
                        filteredSkills.indices.contains(selectedSkillIndex)
                            ? filteredSkills[selectedSkillIndex].name
                            : filteredSkills.first?.name ?? "",
                        anchor: .top
                    )
                }
            }

            Divider()

            HStack(spacing: 5) {
                Text("↑↓")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppPalette.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("navigate")
                Text("·")

                Text("Tab")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppPalette.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("complete")
                Text("·")

                Text("Esc")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppPalette.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("dismiss")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OOColor.paper,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OOColor.hairline, lineWidth: 1)
        }
        .onContinuousHover { phase in
            if case .active = phase {
                isKeyboardNavigatingSkills = false
            }
        }
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
            AgentBalanceNotice(
                balanceUSD: viewModel.agentProfile?.balanceUSD,
                agentAddress: viewModel.agentProfile?.address
                    ?? viewModel.configuration.addressConfiguration?.agentAddress
            )

            if !hasStartedConversation {
                WelcomeHomeView(
                    configuration: viewModel.configuration,
                    isConnected: viewModel.isConfigurationConnected || viewModel.connectionStatus().isLive,
                    connectionSnapshot: viewModel.connectionSnapshot,
                    agentProfile: viewModel.agentProfile,
                    dashboard: viewModel.dashboard
                ) { prompt in
                    // Fill, don't send: the person can add arguments first.
                    viewModel.inputText = prompt
                    isInputFocused = true
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
                                    },
                                    failure: viewModel.failureByMessageID[message.id],
                                    canRetryFailedMessage: viewModel.canRetryFailedMessage(message),
                                    onRetryFailedMessage: {
                                        viewModel.retryFailedMessage(message)
                                    },
                                    canEdit: viewModel.canEditMessage(message),
                                    onEdit: { text in
                                        viewModel.editLatestMessage(message, to: text)
                                    }
                                )
                                    .id(message.id)

                                ForEach(executionRuns(for: message)) { run in
                                    ExecutionFlowView(
                                        run: run,
                                        messageFontSize: chatFontSize,
                                        conversationWidth: conversationWidth,
                                        workRooms: viewModel.workRooms,
                                        onOpenWorkRoom: { viewModel.openWorkRoomID = $0 }
                                    )
                                        .id(run.id)
                                }
                            }

                            ForEach(unlinkedExecutionRuns) { run in
                                ExecutionFlowView(
                                    run: run,
                                    messageFontSize: chatFontSize,
                                    conversationWidth: conversationWidth,
                                    workRooms: viewModel.workRooms,
                                    onOpenWorkRoom: { viewModel.openWorkRoomID = $0 }
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
                                    .frame(minHeight: 28)
                                    .contentShape(Rectangle())
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
                        .environment(\.toolAwaitingApprovalID, viewModel.toolAwaitingApprovalID)
                    }
                    .scrollContentBackground(.hidden)
                    .onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
                        ChatScrollPosition(geometry)
                    } action: { _, position in
                        isAtBottom = position.isAtBottom
                        isFarFromLatest = position.isFarFromLatest
                        if position.isAtBottom {
                            hasUnseenLatest = false
                        }
                    }
                    .overlay(alignment: .bottom) {
                        JumpToLatestButton(isShown: isFarFromLatest, hasUnseenLatest: hasUnseenLatest) {
                            withAnimation {
                                proxy.scrollTo("bottomOfChat", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        scrollToLastUserMessage(using: proxy)
                    }
                    .onChange(of: historySelectionRevision) {
                        scrollToLastUserMessage(using: proxy)
                    }
                    .onChange(of: viewModel.messages.count) {
                        // Scrolled up, nothing pulls you down, not even your own message. Only the
                        // agent's reply lights the dot on Jump to latest.
                        guard isAtBottom else {
                            if viewModel.messages.last?.role == .agent {
                                hasUnseenLatest = true
                            }
                            return
                        }
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

                if viewModel.isFromPreviousIdentity {
                    PreviousIdentityComposerBar(onStartNewChat: viewModel.startNewChat)
                } else if pendingApproval != nil {
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

                if !filteredSkills.isEmpty {
                    skillPalette
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        "Message the agent",
                        text: $viewModel.inputText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .font(AppTypography.mono(size: chatFontSize))
                    .lineLimit(1...5)
                    .disabled(viewModel.pendingInteraction != nil)
                    .onSubmit {
                        if let completion = SkillPaletteNavigation.completion(
                            for: filteredSkills.map(\.name),
                            selectedIndex: selectedSkillIndex
                        ) {
                            viewModel.inputText = completion
                            isInputFocused = true
                        } else {
                            viewModel.sendMessage()
                        }
                    }
                    .onChange(of: skillPaletteQuery) { _, _ in
                        selectedSkillIndex = 0
                    }
                    .onKeyPress(.downArrow) {
                        guard skillPaletteQuery != nil,
                              let nextIndex = SkillPaletteNavigation.movedIndex(
                                  currentIndex: selectedSkillIndex,
                                  skillCount: filteredSkills.count,
                                  offset: 1
                              ) else {
                            return .ignored
                        }

                        isKeyboardNavigatingSkills = true
                        selectedSkillIndex = nextIndex
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard skillPaletteQuery != nil,
                              let nextIndex = SkillPaletteNavigation.movedIndex(
                                  currentIndex: selectedSkillIndex,
                                  skillCount: filteredSkills.count,
                                  offset: -1
                              ) else {
                            return .ignored
                        }

                        isKeyboardNavigatingSkills = true
                        selectedSkillIndex = nextIndex
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard skillPaletteQuery != nil,
                              let completion = SkillPaletteNavigation.completion(
                                  for: filteredSkills.map(\.name),
                                  selectedIndex: selectedSkillIndex
                              ) else {
                            return .ignored
                        }

                        viewModel.inputText = completion
                        isInputFocused = true
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard skillPaletteQuery != nil,
                              !filteredSkills.isEmpty else {
                            return .ignored
                        }

                        viewModel.inputText = ""
                        selectedSkillIndex = 0
                        return .handled
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

                    if viewModel.isReplyingElsewhere {
                        Text("Replying…")
                            .font(.system(size: AppFontSize.caption))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if viewModel.showsExecutionModeSelector {
                        if viewModel.isExecutionModeChangePending {
                            ProgressView()
                                .controlSize(.mini)
                            Text("\(viewModel.desiredExecutionMode.displayName) pending")
                                .font(.system(size: AppFontSize.caption))
                                .foregroundStyle(.secondary)
                                .help("Waiting for the hosted agent to confirm the mode")
                        } else if let turnsLeft = viewModel.acceptTurnsLeft {
                            Text("\(turnsLeft) \(turnsLeft == 1 ? "turn" : "turns") left")
                                .font(.system(size: AppFontSize.caption, weight: .medium).monospacedDigit())
                                .foregroundStyle(OOColor.inkSecondary)
                                .help("Accept mode ends after these turns")
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
                .animation(.easeInOut(duration: 0.15), value: filteredSkills.isEmpty)
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

enum SkillPaletteNavigation {
    static func movedIndex(
        currentIndex: Int,
        skillCount: Int,
        offset: Int
    ) -> Int? {
        guard skillCount > 0 else { return nil }

        return (currentIndex + offset + skillCount) % skillCount
    }

    static func completion(
        for skillNames: [String],
        selectedIndex: Int
    ) -> String? {
        guard skillNames.indices.contains(selectedIndex) else {
            return nil
        }

        return "/\(skillNames[selectedIndex]) "
    }
}

/// Shows the latest session usage in a single compact line.

/// The Control Center is 320 to 900 points wide and starts at 500 as per webchat
enum ControlCenterPaneWidth {
    static let minimum = 320.0
    static let maximum = 900.0
    static let initial = 500.0
    static let keyStep = 10.0
    static let handleWidth: CGFloat = 12 // original value = 6
    /// oo-chat keeps the chat column at lg:min-w-[360px] (workspace-shell.tsx); the pane gives way, not the chat.
    static let minimumChatWidth = 360.0
    static func clamped(_ width: Double) -> Double {
        min(maximum, max(minimum, width))
    }

    /// The pane's width on screen in a detail area `detailWidth` wide: `width` cut down so the chat keeps
    /// `minimumChatWidth`. As in oo-chat, the pane shrinks below its own minimum rather than hide.
    static func fitted(_ width: Double, in detailWidth: Double) -> Double {
        let room = detailWidth - Double(handleWidth) - minimumChatWidth
        return max(0, min(clamped(width), room))
    }
}

/// Where the chat is scrolled, read from the scroll view itself.
struct ChatScrollPosition: Equatable {
    /// Within this of the bottom, new messages keep you at the bottom.
    static let followThreshold: CGFloat = 80
    /// Jump to latest shows once you're this many windows up, as on iOS.
    static let jumpToLatestScreens: CGFloat = 1.5

    let isAtBottom: Bool
    let isFarFromLatest: Bool

    init(_ geometry: ScrollGeometry) {
        self.init(
            contentHeight: geometry.contentSize.height,
            visibleBottom: geometry.visibleRect.maxY,
            viewportHeight: geometry.containerSize.height
        )
    }

    /// The same, from plain numbers, so it can be tested without a scroll view.
    init(contentHeight: CGFloat, visibleBottom: CGFloat, viewportHeight: CGFloat) {
        let distance = contentHeight - visibleBottom
        isAtBottom = distance <= Self.followThreshold
        isFarFromLatest = distance > viewportHeight * Self.jumpToLatestScreens
    }
}

/// Shown while you're well up the chat; brings you back to the newest message (also ⌘↓).
private struct JumpToLatestButton: View {
    let isShown: Bool
    let hasUnseenLatest: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isShown {
                Button(action: action) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OOColor.ink)
                        .frame(width: 32, height: 32)
                        .background(OOColor.paper, in: Circle())
                        .overlay(Circle().stroke(OOColor.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .overlay(alignment: .topTrailing) {
                            if hasUnseenLatest {
                                Circle()
                                    .fill(OOColor.primary)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Jump to latest (⌘↓)")
                .accessibilityLabel(hasUnseenLatest ? "Jump to latest, new messages" : "Jump to latest")
                .padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isShown)
    }
}

/// The Station pane's single field while the host asks for onboarding. The same code is the invite code and,
/// once connected, the pairing code.
private struct StationInviteCodeView: View {
    let error: String?
    let onSubmit: (String) -> Void
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with your terminal")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Enter the pairing code shown by your Claude Code terminal.")
                .foregroundStyle(.secondary)
            SecureField("Pairing code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .accessibilityLabel("Pairing code")
            Button("Pair", action: submit)
                .buttonStyle(.appPrimary)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Pair with Claude Station")
            if let error {
                Text(error).font(.subheadline).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func submit() {
        onSubmit(code)
        code = ""
    }
}

extension ChatView {
    /// A Claude Station's pane is its Work Room straight away, or the pairing field until it is paired.
    /// There is no Back and no chat behind it. The connection resumes the paired session once there is one.
    private var stationDetail: some View {
        let workRooms = viewModel.workRooms
        return Group {
            if let workRoom = workRooms.stationWorkRoom {
                workRoomView(workRoom)
            } else if viewModel.isStationAwaitingCode {
                StationInviteCodeView(error: viewModel.interactionError, onSubmit: viewModel.submitStationCode)
            } else if workRooms.stationPairing.needsCode {
                OOStationPairingView(pairing: workRooms.stationPairing) { workRooms.pairStation(code: $0) }
            } else {
                ProgressView("Connecting to your Station")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The chat column, which connects an ordinary agent, is never drawn for a Station.
        .onAppear { viewModel.connectIfNeeded() }
        .task(id: "\(viewModel.service.isAgentRequestActive)-\(viewModel.service.connectionGeneration)-"
            + "\(workRooms.stationPairing.sessionID ?? "")-\(viewModel.stationOnboardingAttempt)") {
            await viewModel.service.holdWorkRoomConnection(
                stationSessionID: workRooms.stationPairing.sessionID,
                inviteCode: viewModel.stationInviteCode,
                handlesOnboarding: true
            )
        }
        .toolbarBackground(AppPalette.toolbarSurface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}

/// The connection status under the composer. Kept out of the struct body (type length).
extension ChatView {
    /// The chat's status under the composer, in the same words and colours as iOS.
    /// Ticks once a second only while connecting, to turn into "Can't connect" at 10 s.
    private var connectionStatusChip: some View {
        TimelineView(.periodic(from: .now, by: connectingSince == nil ? 3_600 : 1)) { context in
            statusChip(
                viewModel.connectionStatus(
                    connectingFor: connectingSince.map { context.date.timeIntervalSince($0) } ?? 0
                )
            )
        }
        .onChange(of: viewModel.isConnecting, initial: true) { _, isConnecting in
            connectingSince = isConnecting ? (connectingSince ?? .now) : nil
        }
    }

    @ViewBuilder
    private func statusChip(_ status: ChatConnectionStatus) -> some View {
        let detail = status.detail(agentName: viewModel.configuration.name)
        let mark = HStack(spacing: 4) {
            OOStatusDot(label: status.label, tone: status.tone)
            if status.canRetry {
                Text("· Retry")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: status)

        if status.canRetry {
            Button {
                viewModel.retryConnection()
            } label: {
                mark.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detail)
            .accessibilityLabel(detail)
            .accessibilityHint("Tries to connect again")
        } else {
            mark
                .help(detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(detail)
        }
    }
}
