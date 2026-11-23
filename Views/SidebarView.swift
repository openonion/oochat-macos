import SwiftUI
import ConnectOnionKit
import UniformTypeIdentifiers

struct SidebarViewInitialState {
    var hoveredConfigId: UUID?
    var hoveredSessionId: UUID?
    var hoveredNewChat = false
    var hoveredSettings = false
    var searchText = ""
    var editingAgentId: UUID?
    var editingAgentName = ""
    var editingSessionId: UUID?
    var editingSessionTitle = ""
    var agentPendingDeletion: GeneralAgentConfiguration?
    var sessionPendingDeletion: ChatSession?

    init() {
        hoveredConfigId = nil
        hoveredSessionId = nil
        editingAgentId = nil
        editingSessionId = nil
        agentPendingDeletion = nil
        sessionPendingDeletion = nil
    }
}

/// The agent pane, in the place of a Discord server's channel list: who the agent is (click
/// its name to rename it), what needs you, its chats, and what the open chat offers: its Work
/// Rooms, its skills and its Control Center. The agent rail beside it picks the agent.
struct SidebarView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var hoveredSessionId: UUID?
    @State private var hoveredNewChat: Bool
    @State private var hoveredSearch = false
    @State private var isAttentionExpanded = false
    @State private var isSearchVisible = false
    @State private var searchMatches: Set<UUID> = []
    @FocusState private var isSearchFocused: Bool
    @State private var searchText: String
    @State private var editingSessionId: UUID?
    @State private var editingSessionTitle: String
    @State private var agentPendingDeletion: GeneralAgentConfiguration?
    @State private var sessionPendingDeletion: ChatSession?
    @State private var showsAllChats = false
    @State private var isChatsExpanded = true
    /// Where ↑/↓ has moved to, shown at once; the chat opens a moment later, so holding ↓
    /// doesn't connect and disconnect every chat it passes.
    @State private var keyboardSelectionID: UUID?
    @State private var keyboardCommitTask: Task<Void, Never>?
    @FocusState private var focusedSessionId: UUID?

    init(
        appViewModel: AppViewModel,
        initialState: SidebarViewInitialState = SidebarViewInitialState()
    ) {
        self.appViewModel = appViewModel
        _hoveredSessionId = State(initialValue: initialState.hoveredSessionId)
        _hoveredNewChat = State(initialValue: initialState.hoveredNewChat)
        _searchText = State(initialValue: initialState.searchText)
        _editingSessionId = State(initialValue: initialState.editingSessionId)
        _editingSessionTitle = State(initialValue: initialState.editingSessionTitle)
        _agentPendingDeletion = State(initialValue: initialState.agentPendingDeletion)
        _sessionPendingDeletion = State(initialValue: initialState.sessionPendingDeletion)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    var body: some View {
        let statuses = appViewModel.sidebarStatuses
        VStack(spacing: 0) {
            if let agent = paneAgent {
                AgentPaneHeader(appViewModel: appViewModel, agent: agent) {
                    agentPendingDeletion = agent
                }
                OOColor.hairline
                    .frame(height: 1)
                    .accessibilityHidden(true)
                paneList(agent, statuses: statuses)
            } else {
                emptyState
                    .frame(maxHeight: .infinity)
            }
            // Chats whose agent is gone sit here quietly instead of in a launch alert.
            if !appViewModel.orphanedSessions.isEmpty {
                HiddenChatsRow(count: appViewModel.orphanedSessions.count) {
                    appViewModel.discardOrphanedSessions()
                }
                .padding(.horizontal, OOSpace.small)
                .padding(.vertical, OOSpace.tiny)
                .overlay(alignment: .top) {
                    OOColor.hairline
                        .frame(height: 1)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OOColor.surface)
        // Fresh agent statuses (and their chats) when the pane appears or the app comes back.
        .onAppear {
            appViewModel.refreshAgentStatuses()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            appViewModel.refreshAgentStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentPaneSearch)) { _ in
            if paneAgent?.isClaudeStation == false {
                openSearch()
            }
        }
        // Reruns when a message arrives too, so a new message that matches shows up.
        .task(id: "\(searchText)|\(appViewModel.messages.count)|\(appViewModel.sessions.count)") {
            await updateSearchMatches()
        }
        // A different agent starts with its search closed, its chats folded back to five and its
        // attention list shut.
        .onChange(of: paneAgent?.id) {
            closeSearch()
            showsAllChats = false
            isAttentionExpanded = false
        }
        .onChange(of: focusedSessionId) { _, newValue in
            if editingSessionId != nil && newValue != editingSessionId {
                finishRenamingSession()
            }
        }
        .alert(
            "Remove agent?",
            isPresented: Binding(
                get: { agentPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        agentPendingDeletion = nil
                    }
                }
            ),
            presenting: agentPendingDeletion
        ) { configuration in
            Button("Cancel", role: .cancel) {
                agentPendingDeletion = nil
            }
            Button("Remove", role: .destructive) {
                appViewModel.deleteConfiguration(configuration)
                agentPendingDeletion = nil
            }
        } message: { configuration in
            Text("Removing \(configuration.name) also deletes its chats and messages.")
        }
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionPendingDeletion = nil
                    }
                }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                appViewModel.deleteSession(session)
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("Deleting \u{201C}\(session.title)\u{201D} also deletes its messages and keeps its server record hidden on this Mac.")
        }
    }

    /// The agent the pane is about: the open chat's, else the one picked on the rail, else the first.
    var paneAgent: GeneralAgentConfiguration? {
        appViewModel.paneAgent
    }

    /// One list, so it scrolls as a whole and ↑/↓ work. Native sidebar sections fold from their
    /// header, as Discord's categories do.
    private func paneList(_ agent: GeneralAgentConfiguration, statuses: [UUID: SidebarChatStatus]) -> some View {
        List {
            attentionPanel(attentionItems(statuses, for: agent))
                .sidebarRow()
            if !agent.isClaudeStation {
                actionRow("New chat", systemImage: "square.and.pencil", shortcut: "⌘N", isHovered: hoveredNewChat) {
                    startChat(with: agent)
                }
                .onHover { hoveredNewChat = $0 }
                // ⌘N itself lives on the window, so it works with the pane hidden too.
                .help("New chat with \(agent.name) (⌘N)")
                .sidebarRow(top: OOSpace.tiny)
                searchRow
                    .sidebarRow()
                if isSearchVisible {
                    searchField
                        .sidebarRow()
                }
                chatsSection(agent, statuses: statuses)
            }
            if let chat = appViewModel.activeChat, chat.configuration.id == agent.id {
                AgentChatSections(chat: chat)
            } else if agent.isClaudeStation {
                // With its chat open, the Station is already showing, so Open Station gives way to
                // that chat's sections.
                Section {
                    actionRow("Open Station", systemImage: "terminal", isHovered: false) {
                        appViewModel.createNewSession(for: agent)
                    }
                    .sidebarRow()
                } header: {
                    SidebarSectionHeader("Station")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1, in: agent) }
        .onKeyPress(.downArrow) { moveSelection(by: 1, in: agent) }
    }

    @ViewBuilder
    private func chatsSection(_ agent: GeneralAgentConfiguration, statuses: [UUID: SidebarChatStatus]) -> some View {
        let sessions = listedSessions(for: agent)
        // Searching opens the section and lists every match.
        Section(isExpanded: Binding(get: { isSearching || isChatsExpanded }, set: { isChatsExpanded = $0 })) {
            if sessions.isEmpty {
                Text(isSearching ? "No matches" : "No chats yet")
                    .font(OOSidebarMetrics.metaFont)
                    .foregroundStyle(OOColor.inkTertiary)
                    .padding(.leading, OOSidebarMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                    .sidebarRow()
            }
            ForEach(shownSessions(sessions)) { session in
                sessionRow(session, status: statuses[session.id])
                    .sidebarRow()
            }
            if !isSearching && sessions.count > Self.chatsBeforeShowAll {
                showAllRow(total: sessions.count)
                    .sidebarRow()
            }
        } header: {
            SidebarSectionHeader(sessions.isEmpty ? "Chats" : "Chats · \(sessions.count)")
        }
    }

    /// A plain sidebar row with its icon and, on the right, its shortcut.
    private func actionRow(
        _ title: String,
        systemImage: String,
        shortcut: String? = nil,
        isHovered: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: OOSpace.small) {
                Image(systemName: systemImage)
                    .font(OOSidebarMetrics.titleFont)
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(OOSidebarMetrics.titleFont)
                    .foregroundStyle(OOColor.ink)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(OOSidebarMetrics.metaFont)
                        .foregroundStyle(OOColor.inkTertiary)
                }
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                isHovered ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Opens the field below it, and closes it again. ⌘F (on the window) opens and focuses it; a
    /// Station has no chats to search, so there it does nothing.
    private var searchRow: some View {
        actionRow(
            isSearchVisible ? "Close search" : "Search chats",
            systemImage: isSearchVisible ? "xmark" : "magnifyingglass",
            shortcut: isSearchVisible ? nil : "⌘F",
            isHovered: hoveredSearch,
            action: toggleSearch
        )
        .help("Search this agent's chats and messages (⌘F)")
        .onHover { hoveredSearch = $0 }
    }

    private var searchField: some View {
        HStack(spacing: OOSpace.tiny + 2) {
            Image(systemName: "magnifyingglass")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
            TextField("Chats and messages", text: $searchText)
                .textFieldStyle(.plain)
                .font(OOSidebarMetrics.titleFont)
                .focused($isSearchFocused)
                .onExitCommand(perform: closeSearch)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(OOSidebarMetrics.metaFont)
                        .foregroundStyle(OOColor.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
        .frame(minHeight: OOSidebarMetrics.rowHeight)
        .background(
            OOColor.hover,
            in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
        )
    }

    private func toggleSearch() {
        if isSearchVisible {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func openSearch() {
        isSearchVisible = true
        isChatsExpanded = true
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    /// Closing also clears, so the full list comes back.
    private func closeSearch() {
        isSearchVisible = false
        searchText = ""
        isSearchFocused = false
    }

    /// Chats whose title or any message contains the query, ignoring case and accents. Runs
    /// 150 ms after typing stops.
    private func updateSearchMatches() async {
        let query = searchQuery
        guard !query.isEmpty else {
            if !searchMatches.isEmpty {
                searchMatches = []
            }
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else {
            return
        }
        searchMatches = Self.sessionsMatching(query, sessions: appViewModel.sessions, messages: appViewModel.messages)
    }

    /// Chats whose title or any message contains `query`, ignoring case and accents.
    static func sessionsMatching(_ query: String, sessions: [ChatSession], messages: [ChatMessage]) -> Set<UUID> {
        var matches = Set(sessions.filter { $0.title.localizedStandardContains(query) }.map(\.id))
        for message in messages where message.content.localizedStandardContains(query) {
            matches.insert(message.sessionId)
        }
        return matches
    }

    /// This agent's chats that need you, most urgent first. Other agents show ✋ on the rail.
    private func attentionItems(
        _ statuses: [UUID: SidebarChatStatus],
        for agent: GeneralAgentConfiguration
    ) -> [(session: ChatSession, status: SidebarChatStatus)] {
        appViewModel.sessions
            .compactMap { session -> (session: ChatSession, status: SidebarChatStatus)? in
                guard session.agentConfigId == agent.id,
                      let status = statuses[session.id], status.needsYou else {
                    return nil
                }
                return (session, status)
            }
            .sorted { ($0.status, $1.session.updatedAt) < ($1.status, $0.session.updatedAt) }
    }

    /// One chat, the amber line opens it; several, it drops down to list them, inside the same
    /// amber panel.
    @ViewBuilder
    private func attentionPanel(_ items: [(session: ChatSession, status: SidebarChatStatus)]) -> some View {
        if let summary = SidebarAttention.summary(items.map(\.status)) {
            let listsChats = items.count > 1
            VStack(spacing: 0) {
                Button {
                    if listsChats {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAttentionExpanded.toggle()
                        }
                    } else if let item = items.first {
                        open(item.session)
                    }
                } label: {
                    OOSidebarAttentionLine(
                        summary,
                        isExpanded: listsChats ? isAttentionExpanded : nil,
                        drawsBackground: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(listsChats ? "Lists the chats" : "Opens the chat")
                // Always there and clipped: on close the chats slide up under the line.
                VStack(spacing: 0) {
                    if listsChats && isAttentionExpanded {
                        attentionList(items)
                            .transition(.move(edge: .top))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .background(
                OOColor.decisionFill,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .padding(.top, OOSpace.small)
            .onChange(of: items.count) { _, count in
                if count < 2 {
                    isAttentionExpanded = false
                }
            }
        }
    }

    private func attentionList(_ items: [(session: ChatSession, status: SidebarChatStatus)]) -> some View {
        VStack(spacing: 0) {
            OOColor.decisionLine
                .frame(height: 1)
                .accessibilityHidden(true)
            ForEach(Array(items.enumerated()), id: \.element.session.id) { index, item in
                Button {
                    open(item.session)
                } label: {
                    OOSidebarChatRow(
                        title: item.session.title,
                        lastActivity: nil,
                        status: item.status,
                        indent: OOSidebarMetrics.horizontalPadding + 24
                    )
                }
                .buttonStyle(.plain)
                if index < items.count - 1 {
                    OOColor.decisionLine
                        .opacity(0.6)
                        .frame(height: 1)
                        .padding(.leading, OOSidebarMetrics.horizontalPadding + 24)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.bottom, OOSpace.tiny)
    }

    /// Opens a chat, and moves the rail to its agent.
    private func open(_ session: ChatSession) {
        keyboardCommitTask?.cancel()
        keyboardSelectionID = nil
        appViewModel.focusedAgentID = session.agentConfigId
        appViewModel.selectHistoricalSession(session.id)
    }

    private var emptyState: some View {
        VStack(spacing: OOSpace.small) {
            Text("No agents yet")
                .font(OOSidebarMetrics.titleFont.weight(.semibold))
                .foregroundStyle(OOColor.ink)
            Text("Add one with ＋ on the left.")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(OOSpace.large)
    }
}

private extension SidebarView {
    static let chatsBeforeShowAll = 5

    /// Chats with messages, newest first; an empty chat shows only while it's the open one.
    func listedSessions(for config: GeneralAgentConfiguration) -> [ChatSession] {
        let withMessages = Set(appViewModel.visibleSessions.map(\.id))
        let selectedID = selectedSessionID
        return appViewModel.sessions
            .filter { $0.agentConfigId == config.id && ($0.id == selectedID || withMessages.contains($0.id)) }
            .filter { !isSearching || searchMatches.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The first five, plus the open chat when it's further down, so the open chat is always listed.
    func shownSessions(_ sessions: [ChatSession]) -> [ChatSession] {
        guard !isSearching, !showsAllChats else {
            return sessions
        }
        var shown = Array(sessions.prefix(Self.chatsBeforeShowAll))
        if let selectedID = selectedSessionID,
           !shown.contains(where: { $0.id == selectedID }),
           let selected = sessions.first(where: { $0.id == selectedID }) {
            shown.append(selected)
        }
        return shown
    }

    var selectedSessionID: UUID? {
        if case .session(let id) = appViewModel.selection {
            return id
        }
        return nil
    }

    @ViewBuilder
    func sessionRow(_ session: ChatSession, status: SidebarChatStatus?) -> some View {
        if editingSessionId == session.id {
            TextField("Chat name", text: $editingSessionTitle)
                .focused($focusedSessionId, equals: session.id)
                .onSubmit(finishRenamingSession)
                .onExitCommand(perform: cancelRenamingSession)
                .modifier(SidebarRenameField(indent: OOSidebarMetrics.horizontalPadding))
        } else {
            let isSelected = highlightedSessionID == session.id
            let isHovered = hoveredSessionId == session.id
            // ⋯ on the open chat and the hovered one, where the time was. A status stays put.
            let showsMenu = (isSelected || isHovered) && status == nil
            Button {
                open(session)
            } label: {
                OOSidebarChatRow(
                    title: session.title,
                    lastActivity: session.updatedAt,
                    status: status,
                    preview: appViewModel.isFromPreviousIdentity(session) ? PreviousIdentity.label : nil,
                    isSelected: isSelected,
                    hidesTime: showsMenu,
                    indent: OOSidebarMetrics.horizontalPadding
                )
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if showsMenu {
                    sessionMenu(session)
                        .padding(.trailing, OOSpace.tiny)
                }
            }
            .background(
                isHovered && !isSelected ? OOColor.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                startRenamingSession(session)
            })
            .onHover { isHovering in
                if isHovering {
                    hoveredSessionId = session.id
                } else if hoveredSessionId == session.id {
                    hoveredSessionId = nil
                }
            }
            .contextMenu {
                sessionMenuItems(session)
            }
        }
    }

    func sessionMenu(_ session: ChatSession) -> some View {
        Menu {
            sessionMenuItems(session)
        } label: {
            Image(systemName: "ellipsis")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Grey; a borderless menu otherwise takes the app's green tint.
        .tint(OOColor.inkSecondary)
        .fixedSize()
        .frame(width: 28, height: 28)
        .accessibilityLabel("More for \(session.title)")
        .help("More")
    }

    @ViewBuilder
    func sessionMenuItems(_ session: ChatSession) -> some View {
        Button("Rename") {
            startRenamingSession(session)
        }
        Divider()
        Button("Delete Chat…", role: .destructive) {
            sessionPendingDeletion = session
        }
    }

    /// "Show all (n)" opens the rest; "Show less" folds back to the first five.
    func showAllRow(total: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showsAllChats.toggle()
            }
        } label: {
            Text(showsAllChats ? "Show less" : "Show all (\(total))")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .padding(.leading, OOSidebarMetrics.horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func startChat(with config: GeneralAgentConfiguration) {
        isChatsExpanded = true
        appViewModel.focusedAgentID = config.id
        appViewModel.createNewSession(for: config)
    }

    func moveSelection(by step: Int, in agent: GeneralAgentConfiguration) -> KeyPress.Result {
        let ids = shownSessions(listedSessions(for: agent)).map(\.id)
        guard editingSessionId == nil, isChatsExpanded || isSearching,
              let target = Self.chat(after: highlightedSessionID, in: ids, step: step) else {
            return .ignored
        }
        keyboardSelectionID = target
        keyboardCommitTask?.cancel()
        keyboardCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            appViewModel.selectHistoricalSession(target)
            keyboardSelectionID = nil
        }
        return .handled
    }

    /// The open chat, or the one ↑/↓ has just moved to.
    var highlightedSessionID: UUID? {
        keyboardSelectionID ?? selectedSessionID
    }

    private func startRenamingSession(_ session: ChatSession) {
        editingSessionId = session.id
        editingSessionTitle = session.title
        DispatchQueue.main.async {
            focusedSessionId = session.id
        }
    }

    private func finishRenamingSession() {
        guard let sessionId = editingSessionId,
              let session = appViewModel.sessions.first(where: { $0.id == sessionId }) else {
            cancelRenamingSession()
            return
        }
        appViewModel.renameSession(session, to: editingSessionTitle)
        cancelRenamingSession()
    }

    private func cancelRenamingSession() {
        editingSessionId = nil
        editingSessionTitle = ""
        focusedSessionId = nil
    }
}

/// Chats that belong to an agent that's no longer added. They're hidden, not deleted, so this
/// stays a quiet grey row; the explanation and Discard live in its popover.
struct HiddenChatsRow: View {
    let count: Int
    let onDiscard: () -> Void

    @State private var isShowingDetails = false
    @State private var isConfirmingDiscard = false

    static func title(count: Int) -> String {
        count == 1 ? "1 hidden chat" : "\(count) hidden chats"
    }

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text(Self.title(count: count))
                Spacer()
                Image(systemName: "info.circle")
            }
            .font(OOSidebarMetrics.metaFont)
            .foregroundStyle(OOColor.inkSecondary)
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chats from an agent that's no longer added")
        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
            details
        }
        .confirmationDialog(
            count == 1 ? "Discard 1 hidden chat?" : "Discard \(count) hidden chats?",
            isPresented: $isConfirmingDiscard
        ) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their messages are deleted from this Mac. This can't be undone.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hidden chats")
                .font(.headline)
            Text("These chats belong to an agent that's no longer added. Add the agent again to bring them back.")
                .font(OOSidebarMetrics.metaFont)
                .foregroundStyle(OOColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Discard…", role: .destructive) {
                    isShowingDetails = false
                    isConfirmingDiscard = true
                }
                .tint(AppPalette.error)
                Button("Keep") {
                    isShowingDetails = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// The inline rename field, sized and inset like the row it replaces.
private struct SidebarRenameField: ViewModifier {
    let indent: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(OOSidebarMetrics.titleFont)
            .padding(.leading, indent)
            .padding(.trailing, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                OOColor.surface,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
    }
}

private extension View {
    /// A List row with no system inset, separator or background: the row draws its own.
    func sidebarRow(top: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: OOSpace.small, bottom: 0, trailing: OOSpace.small))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Keyboard navigation, kept outside the private extension so tests can reach it.
extension SidebarView {
    /// The chat ↑/↓ lands on: one step from `current`, held at the ends; from nothing, the first
    /// (↓) or the last (↑). nil when there are no chats.
    static func chat(after current: UUID?, in ids: [UUID], step: Int) -> UUID? {
        guard !ids.isEmpty else {
            return nil
        }
        if let current, let index = ids.firstIndex(of: current) {
            return ids[min(max(index + step, 0), ids.count - 1)]
        }
        return step > 0 ? ids.first : ids.last
    }
}

/// The top of the agent pane: the agent's name (click it to rename in place; Return saves, Esc or
/// a click elsewhere keeps the old name), whether it's online, and its address, which copies on
/// click. ⋯ holds the rest.
struct AgentPaneHeader: View {
    @ObservedObject var appViewModel: AppViewModel
    let agent: GeneralAgentConfiguration
    let onRemove: () -> Void

    @State private var isRenaming = false
    @State private var draft = ""
    @State private var isNameHovered = false
    @State private var didCopy = false
    @State private var clickMonitor: Any?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: OOSpace.small) {
            VStack(alignment: .leading, spacing: 2) {
                name
                statusLine
            }
            Spacer(minLength: 0)
            menu
        }
        .padding(.leading, OOSpace.small)
        .padding(.trailing, OOSpace.tiny)
        .frame(height: 56)
        .onChange(of: agent.id) {
            cancel()
        }
        .onChange(of: isFieldFocused) { _, isFocused in
            // Focus moving to another field (the composer, search) keeps the old name too.
            if isRenaming && !isFocused {
                cancel()
            }
        }
        .onDisappear {
            stopWatchingClicks()
        }
    }

    @ViewBuilder
    private var name: some View {
        if isRenaming {
            TextField("Agent name", text: $draft)
                .textFieldStyle(.plain)
                .font(OOSidebarMetrics.titleFont.weight(.semibold))
                .foregroundStyle(OOColor.ink)
                .focused($isFieldFocused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .padding(.horizontal, OOSpace.tiny + 2)
                .frame(height: 24)
                .background(OOColor.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OOColor.primary, lineWidth: 1)
                }
        } else {
            Button(action: startRenaming) {
                Text(agent.name)
                    .font(OOSidebarMetrics.titleFont.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, OOSpace.tiny + 2)
                    .frame(height: 24)
                    .background(
                        isNameHovered ? OOColor.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isNameHovered = $0 }
            .help("Rename agent")
            .accessibilityLabel(agent.name)
            .accessibilityHint("Renames the agent")
        }
    }

    private var isOnline: Bool {
        appViewModel.isAgentConnected(agent)
    }

    private var statusLine: some View {
        HStack(spacing: OOSpace.tiny + 2) {
            OOSidebarStatusDot(isOnline: isOnline)
            Text(agent.isClaudeStation ? "Claude Station" : (isOnline ? "Online" : "Offline"))
                .foregroundStyle(OOColor.inkSecondary)
            // History that hasn't come back from the agent yet, or couldn't.
            if let restore = appViewModel.historyRestoreStates[agent.id], restore != .restored {
                Image(systemName: restore == .pending ? "clock" : "exclamationmark.triangle")
                    .foregroundStyle(OOColor.inkSecondary)
                    .help(restore.label)
                    .accessibilityLabel(restore.label)
            }
            // An agent named by its address doesn't repeat it here.
            if let address = Self.shortAddress(agent.addressConfiguration?.agentAddress),
               address != agent.name, agent.addressConfiguration?.agentAddress != agent.name {
                Text("·")
                    .foregroundStyle(OOColor.inkTertiary)
                    .accessibilityHidden(true)
                Button(action: copyAddress) {
                    Text(didCopy ? "Copied" : address)
                        .monospacedDigit()
                        .foregroundStyle(didCopy ? OOColor.tintText : OOColor.inkTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the agent's address")
                .accessibilityLabel(didCopy ? "Address copied" : "Copy address")
            }
        }
        .font(OOSidebarMetrics.metaFont)
        .lineLimit(1)
        .padding(.horizontal, OOSpace.tiny + 2)
    }

    private var menu: some View {
        Menu {
            Button("Rename", action: startRenaming)
            if agent.addressConfiguration != nil {
                Button("Copy Address", action: copyAddress)
            }
            Divider()
            Button("Remove Agent…", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(OOSidebarMetrics.titleFont.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(OOColor.inkSecondary)
        .fixedSize()
        .frame(width: 28, height: 28)
        .accessibilityLabel("More for \(agent.name)")
        .help("More")
    }

    /// 0x1234...abcd, as the rest of the app shortens an address.
    static func shortAddress(_ address: String?) -> String? {
        guard let address, !address.isEmpty else {
            return nil
        }
        guard address.count > 12 else {
            return address
        }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    private func copyAddress() {
        guard let address = agent.addressConfiguration?.agentAddress else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    private func startRenaming() {
        draft = agent.name
        isRenaming = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !ChatBreadcrumb.isInsideEditedField(event) {
                DispatchQueue.main.async {
                    cancel()
                }
            }
            return event
        }
    }

    private func commit() {
        guard isRenaming else {
            return
        }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != agent.name {
            appViewModel.renameAgent(agent, to: name)
        }
        finish()
    }

    private func cancel() {
        guard isRenaming else {
            return
        }
        finish()
    }

    private func finish() {
        isRenaming = false
        isFieldFocused = false
        stopWatchingClicks()
    }

    private func stopWatchingClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
}

/// What the open chat offers, under its agent's chats: its Work Rooms, its skills (click one to put
/// it in the composer) and the agent's Control Center. Only for the open chat's agent, because these
/// come from that chat's connection.
struct AgentChatSections: View {
    @ObservedObject var chat: ChatViewModel
    @AppStorage("isControlCenterOpen") private var isControlCenterOpen = true
    @State private var isRoomsExpanded = true
    /// Folded at first: skills are occasional, chats are the point.
    @State private var isSkillsExpanded = false
    @State private var showsAllSkills = false

    static let skillsBeforeShowAll = 4
    @State private var hoveredRowID: String?

    var body: some View {
        let rooms = chat.workRooms.workRooms
        if !rooms.isEmpty {
            Section(isExpanded: $isRoomsExpanded) {
                ForEach(rooms) { room in
                    row(
                        id: "room-\(room.id)",
                        title: room.displayTitle,
                        systemImage: "terminal",
                        isSelected: chat.openWorkRoomID == room.id
                    ) {
                        chat.openWorkRoomID = room.id
                    }
                }
            } header: {
                SidebarSectionHeader("Work Rooms")
            }
        }
        if let skills = chat.agentProfile?.skills, !skills.isEmpty {
            Section(isExpanded: $isSkillsExpanded) {
                let shown = showsAllSkills ? skills : Array(skills.prefix(Self.skillsBeforeShowAll))
                ForEach(shown, id: \.name) { skill in
                    row(id: "skill-\(skill.name)", title: "/\(skill.name)", systemImage: "sparkle", help: skill.description) {
                        chat.inputText = "/\(skill.name) "
                    }
                }
                // The first four, then "Show all (n)" / "Show less", as the chats do.
                if skills.count > Self.skillsBeforeShowAll {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showsAllSkills.toggle()
                        }
                    } label: {
                        Text(showsAllSkills ? "Show less" : "Show all (\(skills.count))")
                            .font(OOSidebarMetrics.metaFont)
                            .foregroundStyle(OOColor.inkSecondary)
                            .padding(.leading, OOSidebarMetrics.horizontalPadding)
                            .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sidebarRow()
                }
            } header: {
                SidebarSectionHeader("Skills")
            }
        }
        Section {
            if chat.dashboard != nil {
                row(
                    id: "control-center",
                    title: isControlCenterOpen ? "Hide Control Center" : "Show Control Center",
                    systemImage: "square.grid.2x2"
                ) {
                    isControlCenterOpen.toggle()
                }
            }
            row(
                id: "refresh",
                title: "Refresh dashboard",
                systemImage: "arrow.clockwise",
                help: "Reconnects to the agent, which sends its dashboard again"
            ) {
                chat.retryConnection()
            }
        } header: {
            SidebarSectionHeader("Agent")
        }
    }

    private func row(
        id: String,
        title: String,
        systemImage: String,
        help: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: OOSpace.small) {
                Image(systemName: systemImage)
                    .font(OOSidebarMetrics.metaFont)
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(OOSidebarMetrics.titleFont)
                    .foregroundStyle(OOColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                isSelected ? OOColor.currentTint : (hoveredRowID == id ? OOColor.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .onHover { isHovering in
            if isHovering {
                hoveredRowID = id
            } else if hoveredRowID == id {
                hoveredRowID = nil
            }
        }
        .sidebarRow()
    }
}

/// The agent rail. Home (the logo) at the top, level with the agent pane's header, then a tile per
/// agent with Add agent under the last one, then Settings at the foot. The agent you're in sits on a soft green plate
/// across the rail, as a selected row does in a Mac sidebar; tiles keep one shape throughout.
/// The rail stays when the agent pane is hidden; ⌘0 is Home and ⌘1 to ⌘9 pick agents.
struct AgentRail: View {
    @ObservedObject var appViewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var draggingAgentID: UUID?

    static let width: CGFloat = 64
    /// The same height as the agent pane's header, so both columns' first rule is one line.
    static let headerHeight: CGFloat = 56

    var body: some View {
        let statuses = appViewModel.sidebarStatuses
        // Nothing is selected on the rail while Home, Add agent or Settings is open.
        let selectedID: UUID? = {
            if case .session = appViewModel.selection {
                return appViewModel.paneAgent?.id
            }
            return nil
        }()
        VStack(spacing: 0) {
            AgentRailItem(
                title: "Home",
                isSelected: appViewModel.selection == nil,
                action: showHome
            ) {
                OOLogo.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            }
            .keyboardShortcut("0", modifiers: .command)
            .frame(height: Self.headerHeight)
            rule
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: OOSpace.tiny) {
                    ForEach(Array(appViewModel.configurations.enumerated()), id: \.element.id) { index, agent in
                        AgentRailTile(
                            appViewModel: appViewModel,
                            agent: agent,
                            isSelected: selectedID == agent.id,
                            needsYou: appViewModel.sessions.contains {
                                $0.agentConfigId == agent.id && statuses[$0.id]?.needsYou == true
                            },
                            index: index
                        )
                        // Drag a tile to reorder; the others slide aside as it passes over them.
                        .onDrag {
                            draggingAgentID = agent.id
                            return NSItemProvider(object: agent.id.uuidString as NSString)
                        }
                    }
                    // Right under the last agent, where a new one will appear.
                    AgentRailItem(
                        title: "Add agent",
                        isSelected: appViewModel.selection == .chooseAgent || appViewModel.selection == .newConfiguration,
                        action: showConnectAgent
                    ) {
                        railIcon("plus")
                    }
                }
                .padding(.vertical, OOSpace.small)
                // One drop zone for the whole column: leaving it, or a drag ending, clears the drag,
                // and only a tile's own drag can reorder (text from elsewhere is refused).
                .onDrop(
                    of: [.text],
                    delegate: AgentRailDropDelegate(
                        agentIDs: appViewModel.configurations.map(\.id),
                        appViewModel: appViewModel,
                        draggingAgentID: $draggingAgentID
                    )
                )
            }
            rule
            VStack(spacing: OOSpace.tiny) {
                AgentRailItem(title: "Refresh chats from each agent", isSelected: false, action: refreshChats) {
                    railIcon("arrow.clockwise")
                }
                AgentRailItem(title: "Settings", isSelected: appViewModel.selection == .settings, action: openSettings) {
                    railIcon("gearshape")
                }
            }
            .padding(.vertical, OOSpace.small)
        }
        .frame(width: Self.width)
        .background {
            // A shade darker than the agent pane, which is a shade darker than the chat.
            OOColor.surface
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.3 : 0.04))
                .ignoresSafeArea()
        }
    }

    private var rule: some View {
        OOColor.hairline
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func railIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(OOColor.inkSecondary)
    }

    private func refreshChats() {
        appViewModel.refreshAgentStatuses()
    }

    private func showHome() {
        appViewModel.selection = nil
    }

    private func showConnectAgent() {
        if appViewModel.selection != .newConfiguration && appViewModel.selection != .chooseAgent {
            appViewModel.previousSelection = appViewModel.selection
        }
        appViewModel.selection = .chooseAgent
    }

    private func openSettings() {
        if appViewModel.selection != .settings {
            appViewModel.previousSelection = appViewModel.selection
        }
        appViewModel.selection = .settings
    }
}

/// A rail slot: the plate behind it is green when selected and faint on hover; the content keeps
/// its shape. Used for Home, Add agent, Settings and, through AgentRailTile, each agent.
struct AgentRailItem<Content: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 48, height: 48)
                .background(
                    isSelected ? OOColor.currentTint : (isHovered ? OOColor.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: OORadius.large + 2, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One agent on the rail: its initial on a soft green square (clay for a Claude Station), the
/// status dot from the agent pane on its corner (filled online, a ring offline), and ✋ when a
/// chat needs you.
struct AgentRailTile: View {
    @ObservedObject var appViewModel: AppViewModel
    let agent: GeneralAgentConfiguration
    let isSelected: Bool
    let needsYou: Bool
    let index: Int

    private func open() {
        appViewModel.openAgent(agent)
    }

    var body: some View {
        let isOnline = appViewModel.isAgentConnected(agent)
        AgentRailItem(
            title: agent.isClaudeStation ? "\(agent.name) (Claude Station)" : agent.name,
            isSelected: isSelected,
            action: open
        ) {
            Text(Self.initial(of: agent.name))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(agent.isClaudeStation ? OOColor.claudeCodeTintText : OOColor.tintText)
                .frame(width: 36, height: 36)
                .background(
                    agent.isClaudeStation ? OOColor.claudeCodeTint : OOColor.currentTint,
                    in: RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                )
                // On the selected plate the tile keeps an edge, so it doesn't melt into it.
                .overlay {
                    RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                        .stroke(isSelected ? OOColor.tintText.opacity(0.35) : Color.clear, lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    OOSidebarStatusDot(isOnline: isOnline)
                        .padding(2)
                        .background(OOColor.surface, in: Circle())
                        .offset(x: 4, y: 4)
                }
                .overlay(alignment: .topTrailing) {
                    if needsYou {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 16, height: 16)
                            .background(OOColor.decisionMark, in: Circle())
                            .overlay(Circle().stroke(OOColor.surface, lineWidth: 2))
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .accessibilityLabel(spokenLabel(isOnline: isOnline))
        .contextMenu {
            Button(agent.isClaudeStation ? "Open Station" : "New Chat") {
                appViewModel.focusedAgentID = agent.id
                appViewModel.createNewSession(for: agent)
            }
            Divider()
            // The keyboard and VoiceOver way to reorder, as dragging is for the pointer.
            Button("Move Up") {
                appViewModel.moveAgent(agent.id, by: -1)
            }
            .disabled(index == 0)
            Button("Move Down") {
                appViewModel.moveAgent(agent.id, by: 1)
            }
            .disabled(index >= appViewModel.configurations.count - 1)
            Divider()
            if let address = agent.addressConfiguration?.agentAddress {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
            }
        }
        .background {
            if index < 9 {
                Button("Agent \(index + 1)") {
                    appViewModel.openAgent(agent)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .hidden()
            }
        }
    }

    /// A name's first letter; for an address-only name ("0x3f9a…"), its first a to f letter, as
    /// the kit's avatar tile does.
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, !trimmed.hasPrefix("0x") {
            return String(first).uppercased()
        }
        let hex = trimmed.dropFirst(2)
        let letter = hex.first { "abcdefABCDEF".contains($0) } ?? hex.first
        return letter.map { String($0).uppercased() } ?? "A"
    }

    private func spokenLabel(isOnline: Bool) -> String {
        var parts = [agent.name]
        if agent.isClaudeStation {
            parts.append("Claude Station")
        }
        parts.append(isOnline ? "online" : "offline")
        if needsYou {
            parts.append("a chat needs attention")
        }
        if index < 9 {
            parts.append("Command \(index + 1)")
        }
        return parts.joined(separator: ", ")
    }
}

/// The edge between the agent pane and the chat: drag to resize (220 to 360 pt), double-click
/// for the default width, or use ← and → when it has focus.
struct AgentPaneResizeHandle: View {
    @Binding var width: Double
    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(OOColor.hairline)
            .frame(width: 1)
            .frame(width: AgentPaneWidth.handleWidth)
            .contentShape(Rectangle())
            // The system resets it when the pointer leaves or the handle goes away: nothing to unbalance.
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        width = AgentPaneWidth.clamped(start + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) {
                width = AgentPaneWidth.initial
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                width = AgentPaneWidth.clamped(width - AgentPaneWidth.keyStep)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                width = AgentPaneWidth.clamped(width + AgentPaneWidth.keyStep)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Resize agent pane")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? AgentPaneWidth.keyStep : -AgentPaneWidth.keyStep
                width = AgentPaneWidth.clamped(width + step)
            }
    }
}

enum AgentPaneWidth {
    static let minimum = 220.0
    static let maximum = 360.0
    static let initial = 260.0
    static let keyStep = 10.0
    static let handleWidth: CGFloat = 6

    static func clamped(_ width: Double) -> Double {
        min(maximum, max(minimum, width))
    }
}

/// Moves the dragged agent into the place of the tile it's over, as the drag goes, so the rail
/// reorders live. The order is the saved agent list, so it lasts and ⌘1 to ⌘9 follow it.
struct AgentRailDropDelegate: DropDelegate {
    let agentIDs: [UUID]
    let appViewModel: AppViewModel
    @Binding var draggingAgentID: UUID?

    /// A 48 pt slot and the 4 pt gap after it, below the column's 8 pt top padding.
    static let slotHeight: CGFloat = 48 + OOSpace.tiny
    static let topInset: CGFloat = OOSpace.small

    static func index(atY offset: CGFloat, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        let slot = Int(((offset - topInset) / slotHeight).rounded(.down))
        return min(max(slot, 0), count - 1)
    }

    /// Only a drag that started on a tile, never text dragged in from elsewhere.
    func validateDrop(info: DropInfo) -> Bool {
        draggingAgentID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggingAgentID,
              let index = Self.index(atY: info.location.y, count: agentIDs.count),
              agentIDs[index] != draggingAgentID else {
            return DropProposal(operation: .move)
        }
        let targetID = agentIDs[index]
        withAnimation(.easeOut(duration: 0.15)) {
            appViewModel.moveAgent(draggingAgentID, to: targetID)
        }
        return DropProposal(operation: .move)
    }

    /// Left the rail, or the drag ended somewhere else: a later drag from outside can't reorder.
    func dropExited(info: DropInfo) {
        draggingAgentID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingAgentID = nil
        return true
    }
}

/// Picking an agent on the rail, and which agent the pane shows.
extension AppViewModel {
    /// Puts the agent where `targetID` is, shifting the rest.
    func moveAgent(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              let sourceIndex = configurations.firstIndex(where: { $0.id == id }),
              let targetIndex = configurations.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        let offset = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        configurations.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: offset)
    }

    /// One place up (-1) or down (1); nothing at either end.
    func moveAgent(_ id: UUID, by step: Int) {
        guard let from = configurations.firstIndex(where: { $0.id == id }),
              configurations.indices.contains(from + step) else {
            return
        }
        moveAgent(id, to: configurations[from + step].id)
    }

    /// The open chat's agent, else the one last picked on the rail, else the first.
    var paneAgent: GeneralAgentConfiguration? {
        if case .session(let sessionID) = selection,
           let session = sessions.first(where: { $0.id == sessionID }),
           let agent = configuration(for: session) {
            return agent
        }
        if let focusedAgentID, let agent = configurations.first(where: { $0.id == focusedAgentID }) {
            return agent
        }
        return configurations.first
    }

    /// As in Discord: the agent opens where you were, its latest chat. One with no chats starts a
    /// new one; a Station opens its Work Room. Picking the agent you're already in changes nothing.
    func openAgent(_ agent: GeneralAgentConfiguration) {
        if case .session = selection, paneAgent?.id == agent.id {
            return
        }
        focusedAgentID = agent.id
        if agent.isClaudeStation {
            createNewSession(for: agent)
            return
        }
        let withMessages = Set(visibleSessions.map(\.id))
        let latest = sessions
            .filter { $0.agentConfigId == agent.id && withMessages.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }
        if let latest {
            selectHistoricalSession(latest.id)
        } else {
            createNewSession(for: agent)
        }
    }
}

/// A section title in the agent pane. The system's own section style is too dim on the dark
/// green surface, so it reads in the secondary ink, in the meta size.
private struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(OOSidebarMetrics.metaFont.weight(.semibold))
            .foregroundStyle(OOColor.inkSecondary)
    }
}

extension Notification.Name {
    /// ⌘F, sent by the window to the agent pane.
    static let agentPaneSearch = Notification.Name("agentPaneSearch")
}
