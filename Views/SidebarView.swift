import SwiftUI
import ConnectOnionKit

private struct SidebarAgentHeaderState {
    let hasChats: Bool
    let areChatsExpanded: Bool
    let isConnected: Bool
    let isHovered: Bool
    let isActive: Bool
    let isEditing: Bool
}

struct SidebarViewInitialState {
    var hoveredConfigId: UUID?
    var hoveredSessionId: UUID?
    var hoveredNewChat = false
    var hoveredSettings = false
    var searchText = ""
    var isAgentsSectionExpanded = true
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

/// Manages agent and chat navigation, search, inline renaming, and deletion.
struct SidebarView: View {
    @ObservedObject var appViewModel: AppViewModel

    @State private var hoveredConfigId: UUID?
    @State private var hoveredSessionId: UUID?
    @State private var hoveredNewChat: Bool
    @State private var hoveredLogo = false
    @State private var hoveredUsage = false
    @State private var hoveredSettings: Bool
    @State private var searchText: String
    @State private var isAgentsSectionExpanded: Bool
    @State private var agentChatExpansionState = SidebarAgentChatExpansionState()
    @State private var editingAgentId: UUID?
    @State private var editingAgentName: String
    @State private var editingSessionId: UUID?
    @State private var editingSessionTitle: String
    @State private var agentPendingDeletion: GeneralAgentConfiguration?
    @State private var sessionPendingDeletion: ChatSession?
    // Dropdown menu for sidebar view chats
    @State private var activeSessionMenuId: UUID?
    @State private var activeAgentMenuId: UUID?
    @FocusState private var focusedAgentId: UUID?
    @FocusState private var focusedSessionId: UUID?

    init(
        appViewModel: AppViewModel,
        initialState: SidebarViewInitialState = SidebarViewInitialState()
    ) {
        self.appViewModel = appViewModel
        _hoveredConfigId = State(initialValue: initialState.hoveredConfigId)
        _hoveredSessionId = State(initialValue: initialState.hoveredSessionId)
        _hoveredNewChat = State(initialValue: initialState.hoveredNewChat)
        _hoveredSettings = State(initialValue: initialState.hoveredSettings)
        _searchText = State(initialValue: initialState.searchText)
        _isAgentsSectionExpanded = State(
            initialValue: initialState.isAgentsSectionExpanded
        )
        _editingAgentId = State(initialValue: initialState.editingAgentId)
        _editingAgentName = State(initialValue: initialState.editingAgentName)
        _editingSessionId = State(initialValue: initialState.editingSessionId)
        _editingSessionTitle = State(initialValue: initialState.editingSessionTitle)
        _agentPendingDeletion = State(initialValue: initialState.agentPendingDeletion)
        _sessionPendingDeletion = State(initialValue: initialState.sessionPendingDeletion)
    }

    private var filteredConfigurations: [GeneralAgentConfiguration] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appViewModel.configurations
        } else {
            return appViewModel.configurations.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private var onlineAgentCount: Int {
        appViewModel.configurations.reduce(into: 0) { count, configuration in
            if appViewModel.isAgentConnected(configuration) {
                count += 1
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            newChatButton

            if !appViewModel.configurations.isEmpty {
                searchField
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if appViewModel.configurations.isEmpty {
                        emptyState
                    } else {
                        sectionHeader

                        if isAgentsSectionExpanded {
                            ForEach(filteredConfigurations) { config in
                                agentRow(for: config)
                            }

                            if filteredConfigurations.isEmpty {
                                noResultsState
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
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
                    deleteAgent(configuration)
                    agentPendingDeletion = nil
                }
            } message: { configuration in
                Text("Removing \(configuration.name) also deletes its chats and messages.")
            }

            VStack(spacing: 2) {
                settingsButton
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OOColor.paper)
        .onAppear {
            appViewModel.refreshAgentStatuses()
        }
        .onChange(of: focusedSessionId) { _, newValue in
            if editingSessionId != nil && newValue != editingSessionId {
                finishRenamingSession()
            }
        }
        .onChange(of: focusedAgentId) { _, newValue in
            if editingAgentId != nil && newValue != editingAgentId {
                finishRenamingAgent()
            }
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

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                appViewModel.selection = .chooseAgent
            } label: {
                HStack(spacing: 10) {
                    logoMark

                    Text("ConnectOnion")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hoveredLogo ? OOColor.surface : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Go to agent picker")
            .accessibilityLabel("ConnectOnion — Go to agent picker")
            .onHover { hoveredLogo = $0 }

            Spacer()

            onlineAgentIndicator
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var onlineAgentIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                // Green only when something is online, grey at "0 online".
                .fill(onlineAgentCount > 0 ? OOColor.live : OOColor.inkSecondary)
                .frame(width: 7, height: 7)

            Text("\(onlineAgentCount) online")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OOColor.inkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(onlineAgentCount) agents online")
    }

    private var logoMark: some View {
        OOLogo.image
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
    }

    private var newChatButton: some View {
        Button {
            if let configuration = preferredNewChatConfiguration {
                appViewModel.createNewSession(for: configuration)
            } else {
                showConnectAgent()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                    .frame(width: 18)

                Text("New chat")
                    .font(.system(size: AppFontSize.body, weight: .semibold))

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OOColor.live)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var preferredNewChatConfiguration: GeneralAgentConfiguration? {
        if case .session(let sessionID) = appViewModel.selection,
           let session = appViewModel.sessions.first(where: { $0.id == sessionID }),
           let configuration = appViewModel.configuration(for: session) {
            return configuration
        }
        return appViewModel.configurations.first
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppFontSize.caption))
                .foregroundColor(.secondary)

            TextField("Search agents", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: AppFontSize.caption))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppFontSize.caption))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OOColor.surface)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAgentsSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isAgentsSectionExpanded ? 0 : -90))

                Text("AGENTS")
                    .font(.system(size: AppFontSize.footnote, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(OOColor.inkSecondary)
                    .fixedSize()
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: showConnectAgent) {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: AppFontSize.footnote, weight: .semibold))

                    Text("Add agent")
                        .font(.system(size: AppFontSize.caption, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OOColor.live)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add agent")
            .help("Add agent")

        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var noResultsState: some View {
        VStack(spacing: 6) {
            Text("No matching agents")
                .font(.system(size: AppFontSize.caption, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension SidebarView {
    /// Builds an agent row with connection state and inline editing controls.
    private func agentRow(for config: GeneralAgentConfiguration) -> some View {
        let sessions = appViewModel.visibleSessions
            .filter { $0.agentConfigId == config.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        let isConnected = appViewModel.isAgentConnected(config)
        let isHovered = hoveredConfigId == config.id
        let isActive = sessions.contains { appViewModel.selection == .session($0.id) }
        let isEditing = editingAgentId == config.id
        let areChatsExpanded = agentChatExpansionState.isExpanded(config.id)
        let headerState = SidebarAgentHeaderState(
            hasChats: !sessions.isEmpty,
            areChatsExpanded: areChatsExpanded,
            isConnected: isConnected,
            isHovered: isHovered,
            isActive: isActive,
            isEditing: isEditing
        )

        return VStack(alignment: .leading, spacing: 1) {
            agentHeader(
                for: config,
                state: headerState
            )

            if !sessions.isEmpty && areChatsExpanded {
                sessionList(sessions)
            }
        }
    }

    private func agentHeader(
        for config: GeneralAgentConfiguration,
        state: SidebarAgentHeaderState
    ) -> some View {

        HStack(spacing: 8) {
            if state.isEditing {
                AgentChatDisclosureButton(
                    agentName: config.name,
                    hasChats: state.hasChats,
                    isExpanded: state.areChatsExpanded
                ) {
                    toggleChats(for: config.id)
                }

                OOAvatarTile(name: config.name, isOnline: state.isConnected)

                TextField("Agent name", text: $editingAgentName)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                    .focused($focusedAgentId, equals: config.id)
                    .onSubmit {
                        finishRenamingAgent()
                    }
                    .onExitCommand {
                        cancelRenamingAgent()
                    }
            } else {
                Button {
                    toggleChats(for: config.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(OOColor.inkSecondary)
                            .frame(width: 18)
                            .rotationEffect(
                                .degrees(state.areChatsExpanded ? 0 : -90)
                            )

                        OOAvatarTile(
                            name: config.name,
                            isOnline: state.isConnected
                        )

                        Text(config.name)
                            .font(.system(
                                size: AppFontSize.body,
                                weight: .semibold
                            ))
                            .foregroundColor(
                                .primary.opacity(state.isActive ? 1 : 0.9)
                            )
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!state.hasChats)
                .accessibilityLabel(config.name)
                .accessibilityHint(
                    state.areChatsExpanded
                        ? "Collapse chats"
                        : "Expand chats"
                )
            }

            agentTrailingActions(
                for: config,
                isEditing: state.isEditing,
                isHovered: state.isHovered
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    rowBackground(
                        isActive: state.isActive,
                        isHovered: state.isHovered
                    )
                )
        )
        .contentShape(Rectangle())
        .contextMenu {
            if state.hasChats {
                Button(
                    state.areChatsExpanded
                        ? "Collapse Chats"
                        : "Expand Chats"
                ) {
                    toggleChats(for: config.id)
                }

                Divider()
            }

            Button("New Chat") {
                appViewModel.createNewSession(for: config)
            }

            Button("Rename") {
                startRenamingAgent(config)
            }

            Button("Delete Agent…", role: .destructive) {
                agentPendingDeletion = config
            }
        }
        .onHover { isHovering in
            if isHovering {
                hoveredConfigId = config.id
            } else if hoveredConfigId == config.id {
                hoveredConfigId = nil
            }
        }
        .task {
            appViewModel.refreshAgentStatus(for: config)
        }
    }

    @ViewBuilder
    private func agentTrailingActions(
        for config: GeneralAgentConfiguration,
        isEditing: Bool,
        isHovered: Bool
    ) -> some View {
        if isEditing {
            iconButton("checkmark") {
                finishRenamingAgent()
            }
            .accessibilityLabel("Save agent name")
            .help("Save agent name")

        } else {

            HStack(spacing: 2) {

                // Original individual Add Chat button
                Button {
                    appViewModel.createNewSession(for: config)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: AppFontSize.footnote))
                        .foregroundStyle(OOColor.live)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
                .help("New chat")

                // Three-dot agent actions menu
                Button {
                    activeAgentMenuId = activeAgentMenuId == config.id
                        ? nil
                        : config.id
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(OOColor.live)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent actions")
                .help("Agent actions")
                .popover(
                    isPresented: Binding(
                        get: { activeAgentMenuId == config.id },
                        set: { isPresented in
                            if !isPresented {
                                activeAgentMenuId = nil
                            }
                        }
                    ),
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            activeAgentMenuId = nil
                            startRenamingAgent(config)
                        } label: {
                            HStack {
                                Label("Rename agent", systemImage: "pencil")
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                        Button(role: .destructive) {
                            activeAgentMenuId = nil
                            agentPendingDeletion = config
                        } label: {
                            HStack {
                                Label("Delete agent", systemImage: "trash")
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .frame(width: 180, alignment: .leading)
                }
            }
        }
    }

    private func sessionList(_ sessions: [ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(groupedSessions(sessions), id: \.label) { group in
                Text(group.label.uppercased())
                    .font(.system(size: AppFontSize.footnote, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(OOColor.inkSecondary)
                    .padding(.leading, 4)
                    .padding(.top, 4)

                VStack(spacing: 1) {
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .padding(.leading, 30)
        .padding(.top, 1)
        .padding(.bottom, 4)
    }

    private func toggleChats(for agentID: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            agentChatExpansionState.toggle(agentID)
        }
    }

    private func deleteAgent(_ configuration: GeneralAgentConfiguration) {
        agentChatExpansionState.remove(configuration.id)
        appViewModel.deleteConfiguration(configuration)
    }

    private func startRenamingAgent(_ configuration: GeneralAgentConfiguration) {
        editingAgentId = configuration.id
        editingAgentName = configuration.name
        DispatchQueue.main.async {
            focusedAgentId = configuration.id
        }
    }

    private func finishRenamingAgent() {
        guard let configurationId = editingAgentId,
              let configuration = appViewModel.configurations.first(where: { $0.id == configurationId }) else {
            cancelRenamingAgent()
            return
        }

        appViewModel.renameAgent(configuration, to: editingAgentName)
        editingAgentId = nil
        editingAgentName = ""
        focusedAgentId = nil
    }

    private func cancelRenamingAgent() {
        editingAgentId = nil
        editingAgentName = ""
        focusedAgentId = nil
    }

    /// Groups sessions into stable date sections for sidebar display.
    private func groupedSessions(_ sessions: [ChatSession]) -> [(label: String, sessions: [ChatSession])] {
        var groups: [(label: String, sessions: [ChatSession])] = []
        for session in sessions {
            let label = dateGroupLabel(for: session.updatedAt)
            if let lastIndex = groups.indices.last, groups[lastIndex].label == label {
                groups[lastIndex].sessions.append(session)
            } else {
                groups.append((label: label, sessions: [session]))
            }
        }
        return groups
    }

    private func dateGroupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }

    /// Builds a selectable session row with rename and delete actions.
    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        let isSelected = appViewModel.selection == .session(session.id)
        let isHovered = hoveredSessionId == session.id
        let isEditing = editingSessionId == session.id

        if isEditing {
            HStack(alignment: .top, spacing: 6) {
                TextField("Chat name", text: $editingSessionTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                    .focused($focusedSessionId, equals: session.id)
                    .onSubmit {
                        finishRenamingSession()
                    }
                    .onExitCommand {
                        cancelRenamingSession()
                    }

                Spacer(minLength: 4)

                iconButton("checkmark") {
                    finishRenamingSession()
                }
                .accessibilityLabel("Save name")
                .help("Save name")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    hoveredSessionId = session.id
                } else if hoveredSessionId == session.id {
                    hoveredSessionId = nil
                }
            }
        } else {
            HStack(spacing: 2) {
                // Chat selection button
                Button {
                    appViewModel.selectHistoricalSession(session.id)
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Text(session.title)
                            .font(
                                .system(
                                    size: AppFontSize.body,
                                    weight: isSelected ? .semibold : .regular
                                )
                            )
                            .foregroundColor(
                                isSelected ? OOColor.ink : OOColor.inkSecondary
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // New Chat and three-dot actions
                if isHovered || isSelected || activeSessionMenuId == session.id {
                    HStack(spacing: 2) {

                        // Create a new chat using the same agent
                        Button {
                            if let configuration = appViewModel.configuration(for: session) {
                                appViewModel.createNewSession(for: configuration)
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: AppFontSize.body, weight: .medium))
                                .foregroundStyle(OOColor.live)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New chat")
                        .help("New chat")

                        // Three-dot actions menu
                        Button {
                            activeSessionMenuId = activeSessionMenuId == session.id
                                ? nil
                                : session.id
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: AppFontSize.body, weight: .medium))
                                .foregroundStyle(OOColor.live)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Chat actions")
                        .help("Chat actions")
                        .popover(
                            isPresented: Binding(
                                get: { activeSessionMenuId == session.id },
                                set: { isPresented in
                                    if !isPresented {
                                        activeSessionMenuId = nil
                                    }
                                }
                            ),
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .bottom
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    activeSessionMenuId = nil
                                    startRenamingSession(session)
                                } label: {
                                    HStack {
                                        Label("Rename chat", systemImage: "pencil")
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()

                                Button(role: .destructive) {
                                    activeSessionMenuId = nil
                                    sessionPendingDeletion = session
                                } label: {
                                    HStack {
                                        Label("Delete chat", systemImage: "trash")
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(6)
                            .frame(width: 180, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
                    .fill(
                        isSelected
                            ? OOColor.currentTint
                            : (isHovered ? OOColor.hairline : Color.clear)
                    )
            )
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add chat") {
                    if let configuration = appViewModel.configuration(for: session) {
                        appViewModel.createNewSession(for: configuration)
                    }
                }

                Button("Rename") {
                    startRenamingSession(session)
                }

                Button("Delete Chat…", role: .destructive) {
                    sessionPendingDeletion = session
                }
            }
            .onHover { isHovering in
                if isHovering {
                    hoveredSessionId = session.id
                } else if hoveredSessionId == session.id {
                    hoveredSessionId = nil
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
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
            editingSessionId = nil
            editingSessionTitle = ""
            focusedSessionId = nil
            return
        }

        appViewModel.renameSession(session, to: editingSessionTitle)
        editingSessionId = nil
        editingSessionTitle = ""
        focusedSessionId = nil
    }

    private func cancelRenamingSession() {
        editingSessionId = nil
        editingSessionTitle = ""
        focusedSessionId = nil
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppFontSize.footnote))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button {
            appViewModel.previousSelection = appViewModel.selection
            appViewModel.selection = .settings
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: AppFontSize.subheadline, weight: .medium))
                Text("Settings")
                    .font(.system(size: AppFontSize.body, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        appViewModel.selection == .settings
                            ? OOColor.hover
                            : (hoveredSettings ? OOColor.surface : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredSettings = isHovering
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("No agents yet")
                .font(.system(size: AppFontSize.body, weight: .semibold))
                .foregroundColor(.primary)

            Text("Paste an address on the right to start chatting.")
                .font(.system(size: AppFontSize.caption))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func showConnectAgent() {
        if appViewModel.selection != .newConfiguration {
            appViewModel.previousSelection = appViewModel.selection
        }
        appViewModel.selection = .chooseAgent
    }

    private func rowBackground(isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return OOColor.hover
        } else if isHovered {
            return OOColor.surface
        } else {
            return Color.clear
        }
    }
}
