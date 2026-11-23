import Foundation
import Combine
import ConnectOnionKit
import SwiftUI
import UniformTypeIdentifiers

/// Why an agent's status is checked: someone asked (launch, foreground, a new agent), or the
/// Settings timer. A poll never re-pulls history for an agent that has already restored.
enum AgentStatusTrigger {
    case requested
    case poll
}

/// App-wide source of truth for agent configurations, sessions, messages, and
/// execution history. Persists everything to UserDefaults and keeps sessions
/// attached to the right agent as configurations come and go.
@MainActor
class AppViewModel: ObservableObject {
    @Published var previousSelection: NavigationItem?
    /// Configurations currently believed reachable, updated by both status
    /// probes and live chat traffic.
    @Published var connectedConfigurationIds: Set<UUID> = []
    @Published var agentConnectionSnapshots: [UUID: AgentConnectionSnapshot] = [:]

    @Published var configurations: [GeneralAgentConfiguration] = [] {
        didSet { saveConfigurations() }
    }
    @Published var sessions: [ChatSession] = [] {
        didSet { saveSessions() }
    }

    @Published var messages: [ChatMessage] = [] {
        didSet {
            saveMessages()
            // A session is only persisted once it has messages, so the
            // session list must be re-evaluated whenever messages change.
            saveSessions()
        }
    }
    @Published var executionItemsBySession: [UUID: [ExecutionItem]] = [:] {
        didSet { saveExecutionItems() }
    }
    @Published var executionRunsBySession: [UUID: [ExecutionRun]] = [:] {
        didSet { saveExecutionRuns() }
    }

    @Published var selection: NavigationItem? {
        didSet {
            pruneEmptySessions()
            rememberSelection()
            // Leaving a chat closes its connection, so its Approve or Working no longer holds.
            liveActivity = liveActivity.filter { selection == .session($0.key) }
        }
    }
    /// Approve or Working for the open chat, reported by its ChatViewModel. The Mac keeps only
    /// the open chat connected, so no other chat can be waiting or working.
    @Published private(set) var liveActivity: [UUID: SidebarChatStatus] = [:]
    /// The agent last picked on the rail; the pane shows it while no chat is open.
    @Published var focusedAgentID: UUID?
    /// The open chat's view model, so the agent pane can show its Work Rooms, skills and Control Center.
    @Published var activeChat: ChatViewModel?
    /// Bumped on every explicit history selection so views can re-focus the
    /// session even when the selection value itself did not change.
    @Published private(set) var sessionSelectionRevision = 0
    /// Sessions that no longer resolve to a live agent configuration and could
    /// not be reconciled by their stable identity.
    @Published private(set) var orphanedSessions: [ChatSession] = []
    /// The chat waiting on "Delete chat?", from the sidebar or Chat ▸ Delete….
    @Published var sessionPendingDeletion: ChatSession?
    /// Bumped by Chat ▸ Rename…; the toolbar's chat name turns into a field.
    @Published private(set) var renameChatRequests = 0
    /// Per-agent History Restore outcome; absent until the first attempt.
    @Published private(set) var historyRestoreStates: [UUID: HistoryRestoreState] = [:]

    static let configurationsStorageKey = "saved_configurations"
    private let configKey = AppViewModel.configurationsStorageKey
    private let lastSelectedSessionKey = "last_selected_session"
    private let sessionKey = "saved_sessions"
    private let messageKey = "saved_messages"
    private let executionItemsKey = "saved_execution_items"
    private let executionRunsKey = "saved_execution_runs"
    private let deletedRemoteSessionIDsKey = "deleted_remote_session_ids"
    private let draftsKey = "composer_drafts"
    /// Unsent composer text per chat, so switching chats or relaunching keeps it.
    private var drafts: [UUID: String] = [:]
    private let storage: UserDefaults
    /// Suppresses session persistence while stored state is being restored,
    /// because messages load after sessions and would otherwise make every
    /// restored session look empty.
    private var isRestoringData = false
    let generatedArtifactStore: GeneratedArtifactStore
    private let resolveAgentEndpoint: (String) async throws -> ConnectOnionResolvedEndpoint
    private let historyURLSession: URLSession
    private let historyKeyStore: any PrivateKeyStoring
    private let localAgentDefinitions: [LocalAgentDefinition]
    private var agentStatusTasks: [UUID: Task<Void, Never>] = [:]
    private var retryRequestsByMessageID: [UUID: ChatRetryRequest] = [:]
    private var retryRequestOrder: [UUID] = []
    /// Session ids deleted by builds before Tombstones; each turns into a Tombstone row when next restored.
    private var deletedRemoteSessionIDs: Set<String> = []
    /// Agents added here by Address alone, still named by default until they first report a name.
    private var awaitingReportedName: Set<UUID> = []
    /// Read only once a chat carries a stamp, so first launch never mints a key just to check.
    private lazy var currentAddress: String? = readCurrentAddress()
    private var workRoomStores: [UUID: WorkRoomStore] = [:]
    private let retryRequestCountLimit = 20
    private let retryAttachmentByteLimit = 50 * 1_024 * 1_024
    /// One chat view model, and so one service and one viewer, per chat. A new pair per visit left the
    /// last visit's viewer running too, and each pair added the same mirrored turn to the transcript.
    private var chatViewModels: [UUID: ChatViewModel] = [:]

    init(
        storage: UserDefaults = .standard,
        generatedArtifactStore: GeneratedArtifactStore = .shared,
        localAgentDefinitions: [LocalAgentDefinition] =
            LocalAgentDefinition.automaticDiscoveryTargets,
        historyURLSession: URLSession = .shared,
        historyKeyStore: any PrivateKeyStoring = ConnectOnionIdentityStore.shared,
        resolveAgentEndpoint: @escaping (String) async throws -> ConnectOnionResolvedEndpoint = {
            try await ConnectOnionEndpointResolver().resolve($0)
        }
    ) {
        self.storage = storage
        self.generatedArtifactStore = generatedArtifactStore
        self.localAgentDefinitions = localAgentDefinitions
        self.historyURLSession = historyURLSession
        self.historyKeyStore = historyKeyStore
        self.resolveAgentEndpoint = resolveAgentEndpoint
        loadData()
        loadDrafts()
        restoreLastSelection()
    }

    func draft(for sessionID: UUID) -> String {
        drafts[sessionID] ?? ""
    }

    func setDraft(_ text: String, for sessionID: UUID) {
        guard drafts[sessionID, default: ""] != text else { return }
        drafts[sessionID] = text.isEmpty ? nil : text
        saveDrafts()
    }

    private func forgetDrafts(for sessionIDs: some Sequence<UUID>) {
        for id in sessionIDs {
            drafts[id] = nil
        }
        saveDrafts()
    }

    private func saveDrafts() {
        let stored = Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) })
        storage.set(stored, forKey: draftsKey)
    }

    /// Keeps only drafts whose chat still exists.
    private func loadDrafts() {
        let stored = storage.dictionary(forKey: draftsKey) as? [String: String] ?? [:]
        let sessionIDs = Set(sessions.map(\.id))
        drafts = stored.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key), sessionIDs.contains(id) {
                result[id] = entry.value
            }
        }
    }

    /// Starts a draft chat. The draft lives only in memory and stays out of the
    /// sidebar and storage until its first message is sent. Seeds the remote
    /// session ID from the local UUID so the transcript the host stores for
    /// this chat can be matched back during history import.
    func createNewSession(for config: GeneralAgentConfiguration) {
        // A Claude Station has one pane: its existing session is opened, keeping its pairing.
        let isStation = configurations.first { $0.id == config.id }?.isClaudeStation ?? config.isClaudeStation
        if isStation, let existing = sessions.last(where: { $0.agentConfigId == config.id }) {
            selection = .session(existing.id)
            return
        }
        // Reuse the selected draft instead of stacking up empty chats.
        if case .session(let selectedID) = selection,
           let existing = sessions.first(where: { $0.id == selectedID }),
           !hasMessages(existing),
           existing.agentConfigId == config.id {
            return
        }

        let sessionID = UUID()
        let newSession = ChatSession(
            id: sessionID,
            agentConfigId: config.id,
            agentIdentity: config.agentIdentity,
            remoteSessionID: sessionID.uuidString.lowercased(),
            title: ChatSession.defaultTitle
        )
        sessions.append(newSession)
        selection = .session(newSession.id)
    }

    /// Call after a Device Link replaced the key. Every chat made so far belongs to `previousAddress`
    /// and becomes a Previous-Identity Conversation: readable, never resumed and never merged. Its
    /// resume bookmark goes, and a send still in flight is marked failed. Nothing is wiped.
    func adoptReplacedIdentity(previousAddress: String) {
        currentAddress = readCurrentAddress()
        sessions = sessions.map { session in
            var session = session
            session.identityAddress = PreviousIdentity.stamp(session.identityAddress, replacing: previousAddress)
            return session
        }
        let previousIDs = Set(sessions.filter { isFromPreviousIdentity($0) }.map(\.id))
        for id in previousIDs {
            storage.removeObject(forKey: ConnectOnionRemoteSessionStore.key(for: id))
        }
        messages = messages.map { message in
            var message = message
            if previousIDs.contains(message.sessionId), message.status == .sending || message.status == .queued {
                message.status = .error
            }
            return message
        }
        // The new Address owns its own Hosted History, so the sidebar fills now, not at the next refresh.
        refreshAgentStatuses()
    }

    /// Everything a Device Link does here. A replace stamps the old chats and closes every connection,
    /// so new chats connect as the new Address. A give keeps the Address, so connections stay and only
    /// start viewers.
    var deviceLinkHandlers: DeviceLinkHandlers {
        DeviceLinkHandlers(
            agentNames: agentNamesForLink,
            applyAgentNames: applyLinkedAgentNames,
            replaced: { [weak self] previousAddress in
                self?.adoptReplacedIdentity(previousAddress: previousAddress)
                ConnectOnionService.identityDidChange()
            },
            linked: { ConnectOnionService.didLink() }
        )
    }

    /// Reads the stored row for `session`, since a link can stamp a chat after a view model copied it.
    /// Falls back to the copy once the row is gone.
    func isFromPreviousIdentity(storedRowOf session: ChatSession) -> Bool {
        isFromPreviousIdentity(sessions.first { $0.id == session.id } ?? session)
    }

    /// Made under an Address this device no longer holds. The nil check comes first so an unstamped
    /// chat never reads the key store.
    func isFromPreviousIdentity(_ session: ChatSession) -> Bool {
        session.identityAddress != nil
            && PreviousIdentity.isPrevious(stamp: session.identityAddress, current: currentAddress)
    }

    private func readCurrentAddress() -> String? {
        try? OIPSigner(keyStore: historyKeyStore).address()
    }

    /// Remembers the open chat so a relaunch can reopen it. A draft's ID may be saved too,
    /// but drafts aren't persisted, so `restoreLastSelection` skips it.
    private func rememberSelection() {
        guard !isRestoringData, case .session(let id) = selection else { return }
        storage.set(id.uuidString, forKey: lastSelectedSessionKey)
    }

    /// Reopens the chat that was open at quit, if it and its agent are still here.
    /// Otherwise the selection stays empty and the app shows Choose an agent.
    private func restoreLastSelection() {
        guard let raw = storage.string(forKey: lastSelectedSessionKey),
              let id = UUID(uuidString: raw),
              let session = sessions.first(where: { $0.id == id }),
              configuration(for: session) != nil else {
            return
        }
        selection = .session(id)
    }

    /// Drops draft sessions the user has navigated away from.
    private func pruneEmptySessions() {
        guard !isRestoringData else { return }
        var keptID: UUID?
        if case .session(let id) = selection { keptID = id }
        let sessionIDsWithMessages = Set(messages.map { $0.sessionId })
        let abandoned = sessions.filter {
            !$0.isTombstone && !sessionIDsWithMessages.contains($0.id) && !hasMessages($0) && $0.id != keptID
        }
        guard !abandoned.isEmpty else { return }
        let abandonedIDs = Set(abandoned.map { $0.id })
        forgetStopBarriers(for: abandoned)
        sessions.removeAll { abandonedIDs.contains($0.id) }
        for id in abandonedIDs {
            executionItemsBySession.removeValue(forKey: id)
            executionRunsBySession.removeValue(forKey: id)
        }
        forgetDrafts(for: abandonedIDs)
    }

    func selectHistoricalSession(_ sessionId: UUID) {
        selection = .session(sessionId)
        sessionSelectionRevision &+= 1
    }

    func deleteConfiguration(_ configuration: GeneralAgentConfiguration) {
        let sessionIds = sessions
            .filter { $0.agentConfigId == configuration.id }
            .map { $0.id }
        let artifactReferences = messages
            .filter { sessionIds.contains($0.sessionId) }
            .flatMap { $0.artifacts ?? [] }

        forgetStopBarriers(for: sessions.filter { $0.agentConfigId == configuration.id })
        forgetStatus(of: configuration.id)
        configurations.removeAll { $0.id == configuration.id }
        sessions.removeAll { $0.agentConfigId == configuration.id }
        messages.removeAll { sessionIds.contains($0.sessionId) }
        for sessionId in sessionIds {
            executionItemsBySession.removeValue(forKey: sessionId)
            executionRunsBySession.removeValue(forKey: sessionId)
            workRoomStores.removeValue(forKey: sessionId)
        }
        forgetDrafts(for: sessionIds)
        generatedArtifactStore.removeArtifacts(artifactReferences)

        if case .session(let selectedSessionId) = selection,
           sessionIds.contains(selectedSessionId) {
            selection = nil
        }
    }

    /// Removes sessions that could not be reconciled to any live agent,
    /// along with their messages and execution history.
    func discardOrphanedSessions() {
        let orphanIDs = orphanedSessions.map { $0.id }
        guard !orphanIDs.isEmpty else { return }
        forgetStopBarriers(for: orphanedSessions)
        sessions.removeAll { orphanIDs.contains($0.id) }
        messages.removeAll { orphanIDs.contains($0.sessionId) }
        for sessionId in orphanIDs {
            executionItemsBySession.removeValue(forKey: sessionId)
            executionRunsBySession.removeValue(forKey: sessionId)
            workRoomStores.removeValue(forKey: sessionId)
        }
        forgetDrafts(for: orphanIDs)
        orphanedSessions = []
    }

    /// Titles the session from its first message, but only while it still
    /// shows the placeholder title.
    /// Names an untitled chat once, from its first real message (Kit ChatTitle, as on iOS): a
    /// /command or a blank message leaves it untitled so the next real message names it.
    func updateSessionTitle(_ session: ChatSession, with message: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }),
              sessions[index].isUntitled,
              let title = ChatTitle.from(message) else {
            return
        }
        sessions[index].title = title
    }

    func renameSession(_ session: ChatSession, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = trimmedTitle.isEmpty ? ChatSession.defaultTitle : trimmedTitle
    }

    func renameAgent(_ configuration: GeneralAgentConfiguration, to name: String) {
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        configurations[index].name = trimmedName
        awaitingReportedName.remove(configuration.id)
    }

    func chatViewModel(
        for session: ChatSession,
        configuration: GeneralAgentConfiguration,
        usageRecorder: any UsageRecording
    ) -> ChatViewModel {
        if let cached = chatViewModels[session.id], cached.configuration.id == configuration.id {
            return cached
        }
        let service = ConnectOnionService(
            conversationID: session.id,
            initialRemoteSessionID: session.remoteSessionID,
            usageRecorder: usageRecorder
        )
        let viewModel = ChatViewModel(session: session, configuration: configuration, service: service, appViewModel: self)
        chatViewModels[session.id] = viewModel
        return viewModel
    }

    func updateSessionDate(_ session: ChatSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }),
              !sessions[index].isTombstone else {
            return
        }

        sessions[index].updatedAt = Date()
    }

    /// Inserts or updates a configuration, merging duplicates by stable agent
    /// identity, then opens a fresh session for the effective record.
    func saveAgent(_ config: GeneralAgentConfiguration) {
        let effectiveConfig: GeneralAgentConfiguration
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            effectiveConfig = configurations[index]
        } else if let existing = config.addressConfiguration.flatMap({ existingAgent(for: $0.agentAddress) }),
                  let duplicateIndex = configurations.firstIndex(where: { $0.id == existing.id }) {
            // Reuse the existing configuration so sessions attached to the
            // same agent keep their stable UUID instead of being orphaned.
            var merged = config
            merged.id = configurations[duplicateIndex].id
            configurations[duplicateIndex] = merged
            effectiveConfig = configurations[duplicateIndex]
        } else {
            configurations.append(config)
            effectiveConfig = config
        }

        awaitingReportedName.remove(effectiveConfig.id)
        createNewSession(for: effectiveConfig)
        reconcileSessions()
    }

    /// Adds an agent from a pasted address or URL, rejecting targets that fail
    /// normalization and targets that normalize to an existing configuration.
    @discardableResult
    func addAgent(_ rawTarget: String) -> AddAgentResult {
        guard let target = ConnectOnionAgentTarget.normalized(rawTarget) else {
            return .invalid
        }

        guard existingAgent(for: target) == nil else {
            return .duplicate
        }

        let configuration = GeneralAgentConfiguration(
            name: suggestedAgentName(for: target),
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: target)
        )
        configurations.append(configuration)
        awaitingReportedName.insert(configuration.id)
        refreshAgentStatus(for: configuration)
        reconcileSessions()
        return .added(configuration)
    }

    func isAgentConnected(_ config: GeneralAgentConfiguration) -> Bool {
        connectedConfigurationIds.contains(config.id)
    }

    func setAgentConnected(_ config: GeneralAgentConfiguration, isConnected: Bool) {
        if isConnected {
            connectedConfigurationIds.insert(config.id)
        } else {
            connectedConfigurationIds.remove(config.id)
        }
    }

    /// Whether the agent's last History Restore did not succeed, so a poll may retry it.
    func needsHistoryRestore(_ configurationID: UUID) -> Bool {
        historyRestoreStates[configurationID] != .restored
    }

    /// A `.poll` restores history only for an agent that has not restored yet.
    func refreshAgentStatus(for config: GeneralAgentConfiguration, trigger: AgentStatusTrigger = .requested) {
        agentStatusTasks[config.id]?.cancel()

        guard config.connectionType == .byAddress else {
            connectedConfigurationIds.remove(config.id)
            agentConnectionSnapshots[config.id] = nil
            return
        }

        if agentConnectionSnapshots[config.id] == nil {
            agentConnectionSnapshots[config.id] = .checking
        }
        agentStatusTasks[config.id] = Task { [weak self] in
            await self?.refreshAgentStatusAndWait(for: config, trigger: trigger)
        }
    }

    func refreshAgentStatuses(trigger: AgentStatusTrigger = .requested) {
        for config in configurations {
            refreshAgentStatus(for: config, trigger: trigger)
        }
    }

    func monitorLocalAgents(
        intervalNanoseconds: UInt64 = 15_000_000_000
    ) async {
        while !Task.isCancelled {
            await discoverLocalAgents()
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// Probes each built-in local endpoint, reusing an existing configuration
    /// whenever the target or its resolved address already matches so repeated
    /// discovery never duplicates the Main Agent.
    func discoverLocalAgents() async {
        for definition in localAgentDefinitions {
            guard !Task.isCancelled else { return }

            do {
                let endpoint = try await resolveAgentEndpoint(definition.endpoint)
                let configuration: GeneralAgentConfiguration
                if let existing = matchingConfiguration(
                    matching: definition.endpoint,
                    resolvedAddress: endpoint.agentAddress
                ) {
                    configuration = existing
                } else {
                    configuration = GeneralAgentConfiguration(
                        name: endpoint.info?.name ?? definition.fallbackName,
                        connectionType: .byAddress,
                        addressConfiguration: AgentAddressConfiguration(
                            agentAddress: definition.endpoint
                        )
                    )
                    configurations.append(configuration)
                }
                apply(endpoint: endpoint, to: configuration)
                // The poll must not re-pull history on a timer; it only
                // retries an agent that has not restored yet.
                if needsHistoryRestore(configuration.id) {
                    await restoreHistoryIfAvailable(
                        from: endpoint,
                        for: configuration
                    )
                }
            } catch {
                guard let existing = matchingConfiguration(
                    matching: definition.endpoint,
                    resolvedAddress: nil
                ) else {
                    continue
                }
                applyConnectionFailure(error, to: existing)
            }
        }
    }

    func refreshAgentStatusAndWait(for config: GeneralAgentConfiguration, trigger: AgentStatusTrigger = .requested) async {
        await checkAgentStatus(for: config, trigger: trigger)
    }

    func findMessages(for sessionId: UUID) -> [ChatMessage] {
        return messages.filter { $0.sessionId == sessionId }
    }

    func findExecutionItems(for sessionId: UUID) -> [ExecutionItem] {
        return executionItemsBySession[sessionId] ?? []
    }

    /// Resolves the live configuration for a session, preferring its stored
    /// config UUID and falling back to the stable agent identity.
    func configuration(for session: ChatSession) -> GeneralAgentConfiguration? {
        if let config = configurations.first(where: { $0.id == session.agentConfigId }) {
            return config
        }
        if let identity = session.agentIdentity {
            return configurations.first { $0.agentIdentity == identity }
        }
        return nil
    }

    func findExecutionRuns(for sessionId: UUID) -> [ExecutionRun] {
        return executionRunsBySession[sessionId] ?? []
    }

    func setExecutionItems(_ items: [ExecutionItem], for sessionId: UUID) {
        executionItemsBySession[sessionId] = items
    }

    func setExecutionRuns(_ runs: [ExecutionRun], for sessionId: UUID) {
        executionRunsBySession[sessionId] = runs
    }

    func addExecutionItem(_ item: ExecutionItem, for sessionId: UUID) {
        var items = executionItemsBySession[sessionId] ?? []
        items.append(item)
        executionItemsBySession[sessionId] = items
    }

    func addMessage(_ message: ChatMessage) {
        // A reply that lands after its chat was deleted stays out of the Tombstone.
        guard !sessions.contains(where: { $0.id == message.sessionId && $0.isTombstone }) else { return }
        messages.append(message)
    }

    /// Caches an outbound request so it can be retried, evicting the oldest
    /// entries once the count or combined attachment size exceeds its budget.
    func cacheRetryRequest(
        _ request: ChatRetryRequest,
        for messageID: UUID
    ) {
        retryRequestOrder.removeAll { $0 == messageID }
        retryRequestOrder.append(messageID)
        retryRequestsByMessageID[messageID] = request

        while retryRequestOrder.count > retryRequestCountLimit
            || cachedRetryAttachmentByteCount > retryAttachmentByteLimit {
            guard let oldestMessageID = retryRequestOrder.first else { break }
            retryRequestOrder.removeFirst()
            retryRequestsByMessageID.removeValue(forKey: oldestMessageID)
        }
    }

    func retryRequest(for messageID: UUID) -> ChatRetryRequest? {
        retryRequestsByMessageID[messageID]
    }

    private var cachedRetryAttachmentByteCount: Int {
        retryRequestsByMessageID.values.reduce(0) {
            $0 + $1.attachmentByteCount
        }
    }

    func upsertMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    func updateMessageStatus(_ messageID: UUID, to status: MessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].status = status
    }

    func saveMessages() {
        if let data = try? JSONEncoder().encode(messages) {
            storage.set(data, forKey: messageKey)
        }
    }

    func saveExecutionItems() {
        if let data = try? JSONEncoder().encode(executionItemsBySession) {
            storage.set(data, forKey: executionItemsKey)
        }
    }

    func saveExecutionRuns() {
        if let data = try? JSONEncoder().encode(executionRunsBySession) {
            storage.set(data, forKey: executionRunsKey)
        }
    }

    private func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            storage.set(data, forKey: configKey)
        }
    }

    private func saveSessions() {
        guard !isRestoringData else { return }
        let sessionIDsWithMessages = Set(messages.map { $0.sessionId })
        let stored = sessions.filter { $0.isTombstone || sessionIDsWithMessages.contains($0.id) }
        if let data = try? JSONEncoder().encode(stored) {
            storage.set(data, forKey: sessionKey)
        }
    }

    /// Restores persisted state, migrating older records along the way: legacy
    /// non-address configurations are dropped, missing remote session IDs are
    /// backfilled, and obsolete connection notices are filtered out.
    private func loadData() {
        isRestoringData = true
        defer {
            isRestoringData = false
            // Drops draft sessions persisted by older versions.
            sessions.removeAll { !$0.isTombstone && !hasMessages($0) }
            saveSessions()
        }

        if let deletedSessionData = storage.data(
            forKey: deletedRemoteSessionIDsKey
        ), let decodedIDs = try? JSONDecoder().decode(
            Set<String>.self,
            from: deletedSessionData
        ) {
            deletedRemoteSessionIDs = decodedIDs
        }

        if let configData = storage.data(forKey: configKey),
           let decodedConfigs = try? JSONDecoder().decode([GeneralAgentConfiguration].self, from: configData) {
            configurations = decodedConfigs.filter {
                $0.connectionType == .byAddress
            }
            if configurations.count != decodedConfigs.count {
                saveConfigurations()
            }
        }

        if let sessionData = storage.data(forKey: sessionKey),
           let decodedSessions = try? JSONDecoder().decode([ChatSession].self, from: sessionData) {
            var migratedSessions = decodedSessions
            for index in migratedSessions.indices
                where migratedSessions[index].remoteSessionID == nil {
                migratedSessions[index].remoteSessionID =
                    connectOnionPersistedRemoteSessionID(
                        for: migratedSessions[index].id,
                        storage: storage
                    )
            }
            sessions = migratedSessions
        }

        if let messageData = storage.data(forKey: messageKey),
           let decodedMessages = try? JSONDecoder().decode([ChatMessage].self, from: messageData) {
            messages = Self.collapsingIntermediateAgentMessages(
                decodedMessages.filter { message in
                    !(message.role == .system
                        && message.content.hasPrefix("Connected to "))
                }
            )
        }

        if let executionData = storage.data(forKey: executionItemsKey),
           let decodedItems = try? JSONDecoder().decode([UUID: [ExecutionItem]].self, from: executionData) {
            executionItemsBySession = decodedItems
        }

        if let executionRunData = storage.data(forKey: executionRunsKey),
           let decodedRuns = try? JSONDecoder().decode([UUID: [ExecutionRun]].self, from: executionRunData) {
            executionRunsBySession = decodedRuns
        }

        mergeDuplicateAgents()
        reconcileSessions()
    }

    /// Re-attaches sessions to live configurations using their stable agent
    /// identity and surfaces sessions that can no longer be resolved.
    func reconcileSessions() {
        var reconciled = 0
        var orphans: [ChatSession] = []
        var updatedSessions = sessions
        for index in updatedSessions.indices {
            var session = updatedSessions[index]
            let isAttached = configurations.contains(where: {
                $0.id == session.agentConfigId
            })
            if isAttached {
                if session.agentIdentity == nil {
                    session.agentIdentity = configuration(for: session)?.agentIdentity
                    updatedSessions[index] = session
                }
                continue
            }
            if let identity = session.agentIdentity,
               let config = configurations.first(where: {
                   $0.agentIdentity == identity
               }) {
                session.agentConfigId = config.id
                updatedSessions[index] = session
                reconciled += 1
            } else if !session.isTombstone {
                orphans.append(session)
            }
        }
        sessions = updatedSessions
        orphanedSessions = orphans
        if reconciled > 0 {
            saveSessions()
        }
    }

    private func checkAgentStatus(for config: GeneralAgentConfiguration, trigger: AgentStatusTrigger) async {
        guard config.connectionType == .byAddress,
              let address = config.addressConfiguration?.agentAddress
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            connectedConfigurationIds.remove(config.id)
            agentConnectionSnapshots[config.id] = AgentConnectionSnapshot(
                state: .invalid,
                route: nil,
                remoteName: nil,
                tools: [],
                detail: "Missing agent target"
            )
            return
        }

        do {
            let endpoint = try await resolveAgentEndpoint(address)
            guard !Task.isCancelled,
                  configurations.contains(where: { $0.id == config.id }) else {
                return
            }

            apply(endpoint: endpoint, to: config)
            // It may have just merged into an agent with the same Address, which restores on its own check.
            guard configurations.contains(where: { $0.id == config.id }) else { return }
            // Like discovery, a poll only retries an agent that has not restored yet.
            guard trigger == .requested || needsHistoryRestore(config.id) else { return }
            await restoreHistoryIfAvailable(from: endpoint, for: config)
        } catch {
            guard !Task.isCancelled,
                  configurations.contains(where: { $0.id == config.id }) else {
                return
            }

            applyConnectionFailure(error, to: config)
        }
    }

    /// Matches by normalized target first, then by resolved 0x address so a
    /// URL entry and an address entry for the same agent count as one.
    private func matchingConfiguration(
        matching target: String,
        resolvedAddress: String?
    ) -> GeneralAgentConfiguration? {
        let normalizedResolvedAddress = resolvedAddress.flatMap(
            ConnectOnionAddress.normalized
        )
        return configurations.first { configuration in
            guard configuration.connectionType == .byAddress,
                  let existingTarget = configuration.addressConfiguration?
                    .agentAddress else {
                return false
            }
            if ConnectOnionAgentTarget.normalized(existingTarget)
                == ConnectOnionAgentTarget.normalized(target) {
                return true
            }
            guard let normalizedResolvedAddress else { return false }
            return ConnectOnionAddress.normalized(existingTarget)
                == normalizedResolvedAddress
        }
    }

    private func apply(
        endpoint: ConnectOnionResolvedEndpoint,
        to configuration: GeneralAgentConfiguration
    ) {
        connectedConfigurationIds.insert(configuration.id)
        agentConnectionSnapshots[configuration.id] = AgentConnectionSnapshot(
            state: .online,
            route: endpoint.isDirect ? .direct : .relay,
            remoteName: endpoint.info?.name,
            tools: endpoint.info?.tools ?? [],
            detail: endpoint.isDirect ? "Direct endpoint" : "ConnectOnion relay",
            model: endpoint.info?.model,
            trust: endpoint.info?.trust,
            version: endpoint.info?.version
        )
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else { return }
        // The reported name only fills the default given on add, never a name the person or a link chose.
        if let reported = endpoint.info?.name.trimmingCharacters(in: .whitespacesAndNewlines), !reported.isEmpty,
           awaitingReportedName.remove(configuration.id) != nil {
            configurations[index].name = reported
        }
        // A Direct URL agent's Address is only known once reached; record it so it matches by Address.
        let target = configuration.addressConfiguration?.agentAddress ?? ""
        if ConnectOnionAddress.normalized(target) == nil,
           let address = ConnectOnionAddress.normalized(endpoint.agentAddress),
           configurations[index].resolvedAddress != address {
            configurations[index].resolvedAddress = address
            mergeDuplicateAgents()
            reconcileSessions()
        }
    }

    /// Restores this Identity's Hosted History from the agent's signed
    /// `/sessions` endpoint. Agents without a direct HTTP endpoint (relay-only)
    /// or that cannot be reached are `pending` and retry on the next connect;
    /// an auth rejection or bad answer is `failed`, never an empty history.
    private func restoreHistoryIfAvailable(
        from endpoint: ConnectOnionResolvedEndpoint,
        for configuration: GeneralAgentConfiguration
    ) async {
        guard endpoint.isDirect, let baseURL = endpoint.httpBaseURL else {
            historyRestoreStates[configuration.id] = .pending
            return
        }

        let client = SessionsClient(
            baseURL: baseURL,
            agentAddress: endpoint.agentAddress,
            keyStore: historyKeyStore,
            urlSession: historyURLSession
        )
        do {
            let fetchedAs = readCurrentAddress()
            let hostedSessions = try await client.listSessions()
            // Fetched as an Address a link has since replaced: those sessions belong to the old identity.
            guard readCurrentAddress() == fetchedAs else { return }
            mergeHostedSessions(hostedSessions, for: configuration)
            historyRestoreStates[configuration.id] = .restored
        } catch {
            // Never marks an otherwise healthy agent offline.
            historyRestoreStates[configuration.id] = HistoryRestoreState(error: error)
        }
    }

    /// Only ever forward: a stale host `updated` must not lower the time a Tombstone is later recorded at.
    private static func isNewer(_ hostTime: Date, than recorded: Date?) -> Bool {
        recorded.map { hostTime > $0 } ?? true
    }

    /// False for a Tombstone the host has not updated since it was recorded; that chat stays deleted.
    private static func isLive(_ session: ChatSession, given hosted: ConnectOnionHostedSession) -> Bool {
        guard let recorded = session.tombstoneUpdatedAt else { return true }
        return hosted.conversation?.updatedDate.map { $0 > recorded } ?? false
    }

    /// Records the host's time on the row for a hosted session with no visible messages, forward only. A
    /// Tombstone moves only on the host's `updated`. Returns whether the row changed.
    private func recordHostTimeOfEmptySession(
        _ hosted: ConnectOnionHostedSession,
        on session: inout ChatSession
    ) -> Bool {
        guard let hostTime = hosted.updatedOrCreatedDate,
              !isFromPreviousIdentity(session) else { return false }
        if let recorded = session.tombstoneUpdatedAt {
            guard let hostUpdated = hosted.conversation?.updatedDate, hostUpdated > recorded else { return false }
            session.tombstoneUpdatedAt = hostUpdated
            session.hostUpdatedAt = hostUpdated
            return true
        }
        guard Self.isNewer(hostTime, than: session.hostUpdatedAt) else { return false }
        session.hostUpdatedAt = hostTime
        return true
    }

    /// Imports hosted transcripts as local sessions and fills empty ones, skipping Tombstones the host has
    /// not updated since. A chat with messages only records the host's time. A session with no
    /// visible messages creates and revives nothing; it only records its time on a row that exists.
    private func mergeHostedSessions(
        _ hostedSessions: [ConnectOnionHostedSession],
        for configuration: GeneralAgentConfiguration
    ) {
        // Removed while the fetch ran: its sessions would be saved under an agent that no longer exists.
        guard configurations.contains(where: { $0.id == configuration.id }) else { return }
        var updatedSessions = sessions
        var updatedMessages = messages
        var didChangeSessions = false
        var didChangeMessages = false

        for hosted in hostedSessions {
            let remoteID = Self.normalizedRemoteSessionID(hosted.sessionID)
            guard !remoteID.isEmpty else { continue }

            let localID = UUID(uuidString: remoteID) ?? UUID()
            let projected = Self.projectMessages(
                from: hosted,
                sessionID: localID
            )
            // The host's own time only; nil when it sent neither `updated` nor `created`.
            let hostTime = hosted.updatedOrCreatedDate
            let createdAt = hosted.createdDate ?? Date()
            let remoteUpdatedAt = hostTime ?? createdAt
            let existingIndex = updatedSessions.firstIndex {
                $0.remoteSessionID == remoteID
                    || $0.id.uuidString.caseInsensitiveCompare(remoteID)
                        == .orderedSame
            }

            // Nothing to show: creates and revives nothing, but a row that exists still records the host's time.
            if projected.isEmpty {
                if let existingIndex, recordHostTimeOfEmptySession(hosted, on: &updatedSessions[existingIndex]) {
                    didChangeSessions = true
                }
                continue
            }

            if let existingIndex {
                let existing = updatedSessions[existingIndex]
                guard !isFromPreviousIdentity(existing) else { continue }
                // A Tombstone used again elsewhere since it was deleted: restore it in full, through the path below.
                guard Self.isLive(existing, given: hosted) else { continue }
                updatedSessions[existingIndex].tombstoneUpdatedAt = nil
                if let hostTime, Self.isNewer(hostTime, than: existing.hostUpdatedAt) {
                    updatedSessions[existingIndex].hostUpdatedAt = hostTime
                    didChangeSessions = true
                }
                if existing.remoteSessionID == nil {
                    updatedSessions[existingIndex].remoteSessionID = remoteID
                    didChangeSessions = true
                }
                // Never replaces a live chat's messages; catch-up on open does that. It only fills an empty
                // chat, which a revived Tombstone always is.
                guard !updatedMessages.contains(where: { $0.sessionId == existing.id }) else { continue }

                updatedSessions[existingIndex].agentConfigId = configuration.id
                updatedSessions[existingIndex].agentIdentity =
                    configuration.agentIdentity
                updatedSessions[existingIndex].updatedAt = remoteUpdatedAt
                if updatedSessions[existingIndex].isUntitled {
                    updatedSessions[existingIndex].title = Self.title(
                        for: projected
                    )
                }
                didChangeSessions = true
                updatedMessages.append(contentsOf: projected.map {
                    var message = $0
                    message.sessionId = existing.id
                    return message
                })
                didChangeMessages = true
            } else if deletedRemoteSessionIDs.remove(remoteID) != nil {
                // Deleted by an older build, which kept only the id: it becomes a Tombstone row.
                updatedSessions.append(ChatSession(
                    id: localID,
                    agentConfigId: configuration.id,
                    agentIdentity: configuration.agentIdentity,
                    remoteSessionID: remoteID,
                    title: ChatSession.defaultTitle,
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt,
                    hostUpdatedAt: hostTime,
                    tombstoneUpdatedAt: remoteUpdatedAt
                ))
                storage.set(try? JSONEncoder().encode(deletedRemoteSessionIDs), forKey: deletedRemoteSessionIDsKey)
                didChangeSessions = true
            } else {
                let session = ChatSession(
                    id: localID,
                    agentConfigId: configuration.id,
                    agentIdentity: configuration.agentIdentity,
                    remoteSessionID: remoteID,
                    title: Self.title(for: projected),
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt,
                    hostUpdatedAt: hostTime
                )
                updatedSessions.append(session)
                updatedMessages.append(contentsOf: projected)
                didChangeSessions = true
                didChangeMessages = true
            }
        }
        if didChangeSessions {
            sessions = updatedSessions.sorted { $0.updatedAt > $1.updatedAt }
        }
        if didChangeMessages {
            messages = updatedMessages
        }
    }

    private static func normalizedRemoteSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }

    private func applyConnectionFailure(
        _ error: Error,
        to configuration: GeneralAgentConfiguration
    ) {
        connectedConfigurationIds.remove(configuration.id)
        let state: AgentConnectionState
        if case ConnectOnionRemoteError.invalidAgentTarget = error {
            state = .invalid
        } else {
            state = .offline
        }
        agentConnectionSnapshots[configuration.id] = AgentConnectionSnapshot(
            state: state,
            route: nil,
            remoteName: nil,
            tools: [],
            detail: error.localizedDescription
        )
    }

    private func suggestedAgentName(for target: String) -> String {
        if let address = ConnectOnionAddress.normalized(target) {
            return "\(address.prefix(6))…\(address.suffix(4))"
        }

        guard let url = ConnectOnionAgentTarget.directURL(from: target),
              let host = url.host else {
            return "Direct Agent"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Deleted chats (Tombstones).
extension AppViewModel {
    /// Erases the chat but keeps its row as a Tombstone, so a later History Restore skips its session
    /// unless the host reports newer activity. A Previous-Identity Conversation is just removed: the merge
    /// never touches those. Nothing is deleted on the host.
    func deleteSession(_ session: ChatSession) {
        let sessionMessages = messages.filter { $0.sessionId == session.id }
        let artifactReferences = sessionMessages.flatMap { $0.artifacts ?? [] }
        forgetStopBarriers(for: [session])
        if let index = sessions.firstIndex(where: { $0.id == session.id }), !isFromPreviousIdentity(session) {
            // The later of the last-known host `updated` and the last message time. A reply arrives after
            // the host stamps its turn, so a chat sent in and deleted before the next restore stays deleted.
            // With neither, its creation time. Never the time of deletion.
            sessions[index].tombstoneUpdatedAt = (sessionMessages.map(\.timestamp)
                + [sessions[index].hostUpdatedAt].compactMap { $0 }).max() ?? sessions[index].createdAt
            sessions[index].title = ChatSession.defaultTitle
        } else {
            sessions.removeAll { $0.id == session.id }
        }
        messages.removeAll { $0.sessionId == session.id }
        executionItemsBySession.removeValue(forKey: session.id)
        executionRunsBySession.removeValue(forKey: session.id)
        workRoomStores.removeValue(forKey: session.id)
        forgetDrafts(for: [session.id])
        generatedArtifactStore.removeArtifacts(artifactReferences)
        storage.removeObject(forKey: ConnectOnionRemoteSessionStore.key(for: session.id))
        chatViewModels[session.id] = nil

        if selection == .session(session.id) {
            selection = nil
        }
    }
}

/// One agent per Address (spec 02, Agent Names), and the Agent Name list a Device Link carries.
extension AppViewModel {
    /// The agent a target names, matched by normalized target or by 0x Address in any case: one agent per Address.
    func existingAgent(for rawTarget: String) -> GeneralAgentConfiguration? {
        let target = ConnectOnionAgentTarget.normalized(rawTarget)
        let address = ConnectOnionAddress.normalized(rawTarget)
        return configurations.first { configuration in
            (target != nil && configuration.agentIdentity == target)
                || (address != nil && configuration.agentAddress == address)
        }
    }

    /// Giving Device: the Agent Name list a link sends. One entry per known 0x Address; a Direct URL agent
    /// whose Address this Mac hasn't learned is left out.
    func agentNamesForLink() -> [DeviceLinkAgentName] {
        configurations.compactMap { configuration in
            configuration.agentAddress.flatMap { DeviceLinkAgentName(address: $0, name: configuration.name) }
        }
    }

    /// Receiving Device, after a link replaced the key: the agent with a listed Address takes the giver's
    /// name, a missing one is added as a 0x agent, and every other agent stays as it is. Call it before
    /// `adoptReplacedIdentity`, whose refresh then restores the added agents' chats too.
    func applyLinkedAgentNames(_ list: [DeviceLinkAgentName]) {
        let plan = DeviceLinkAgentName.apply(list, to: configurations, address: \.agentAddress)
        var updated = configurations
        for rename in plan.renames {
            updated[rename.index].name = rename.name
            awaitingReportedName.remove(updated[rename.index].id)
        }
        updated += plan.additions.map {
            GeneralAgentConfiguration(
                name: $0.name,
                connectionType: .byAddress,
                addressConfiguration: AgentAddressConfiguration(agentAddress: $0.address)
            )
        }
        configurations = updated
    }

    /// One agent per Address: agents sharing one merge into the earliest added (first saved), which keeps
    /// its name and takes the others' chats, Tombstones included, so deleted chats stay deleted.
    func mergeDuplicateAgents() {
        let groups = DeviceLinkAgentName.duplicates(in: configurations, address: \.agentAddress)
        guard !groups.isEmpty else { return }
        var keeperByExtra: [UUID: GeneralAgentConfiguration] = [:]
        for group in groups {
            for extra in group.extras { keeperByExtra[extra.id] = group.keep }
        }
        sessions = sessions.map { session in
            guard let keeper = keeperByExtra[session.agentConfigId] else { return session }
            var session = session
            session.agentConfigId = keeper.id
            session.agentIdentity = keeper.agentIdentity
            return session
        }
        for extraID in keeperByExtra.keys {
            forgetStatus(of: extraID)
            historyRestoreStates[extraID] = nil
        }
        configurations.removeAll { keeperByExtra[$0.id] != nil }
    }

    /// Stops an agent's status check and drops what it showed, for an agent that is going away.
    private func forgetStatus(of id: UUID) {
        agentStatusTasks[id]?.cancel()
        agentStatusTasks[id] = nil
        connectedConfigurationIds.remove(id)
        agentConnectionSnapshots[id] = nil
    }
}

/// Work Room stores and their saved Stop Barriers, and Claude Stations.
extension AppViewModel {
    /// The scope for a chat id; a chat that is not in `sessions` yet falls back to its own id.
    func workRoomBarrierScope(forSessionID sessionId: UUID) -> String {
        sessions.first { $0.id == sessionId }.map(workRoomBarrierScope(for:)) ?? sessionId.uuidString
    }

    /// Agent identity plus the host session id (the local id for chats that never had one): both are
    /// saved with the chat, so the scope is the same after a relaunch and differs per chat.
    func workRoomBarrierScope(for session: ChatSession) -> String {
        let agent = session.agentIdentity ?? session.agentConfigId.uuidString
        return "\(agent):\(session.remoteSessionID ?? session.id.uuidString.lowercased())"
    }

    /// The conversation's Work Room store, kept here like its execution runs so a
    /// Work Room Card survives switching chats.
    /// Its Stop Barrier is saved under `workRoomBarrierScope(for:)`, so it survives a relaunch.
    func workRoomStore(for sessionId: UUID) -> WorkRoomStore {
        if let store = workRoomStores[sessionId] {
            return store
        }
        let store = WorkRoomStore(barrierScope: workRoomBarrierScope(forSessionID: sessionId))
        workRoomStores[sessionId] = store
        return store
    }

    /// A deleted chat takes its saved Stop Barrier with it, so the entry does not stay in defaults for good.
    private func forgetStopBarriers(for removed: [ChatSession]) {
        for session in removed {
            WorkRoomStore.forgetBarrier(scope: workRoomBarrierScope(for: session))
        }
    }

    /// Remembers that an agent is a Claude Station so the sidebar can draw its row.
    func markClaudeStation(_ configurationID: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == configurationID }),
              !configurations[index].isClaudeStation else { return }
        configurations[index].isClaudeStation = true
    }
}

// MARK: - Sidebar status

/// Kept out of the class body (type length): what the sidebar says each chat is doing.
extension AppViewModel {
    func setLiveActivity(_ status: SidebarChatStatus?, for sessionID: UUID) {
        guard liveActivity[sessionID] != status else {
            return
        }
        liveActivity[sessionID] = status
    }

    /// What each chat's sidebar row says instead of its time: the open chat's live status, or
    /// Not sent for any chat whose last message from you failed (that's saved, so it lasts).
    var sidebarStatuses: [UUID: SidebarChatStatus] {
        var lastSent: [UUID: ChatMessage] = [:]
        for message in messages where message.role == .user {
            lastSent[message.sessionId] = message
        }
        var statuses: [UUID: SidebarChatStatus] = [:]
        for (sessionID, message) in lastSent where message.status == .error {
            statuses[sessionID] = .notSent
        }
        for (sessionID, status) in liveActivity {
            statuses[sessionID] = SidebarChatStatus.mostUrgent([status] + [statuses[sessionID]].compactMap { $0 })
        }
        return statuses
    }
}

extension AppViewModel {
    /// Whether the session has any messages. Sessions without messages are
    /// drafts: never shown in the sidebar and never persisted. A Claude Station's
    /// session carries no chat messages (its Work Room is the pane), so it is never a draft:
    /// dropping it would lose the pairing it holds.
    func hasMessages(_ session: ChatSession) -> Bool {
        messages.contains { $0.sessionId == session.id }
            || configuration(for: session)?.isClaudeStation == true
    }

    /// Sessions that should appear in the sidebar. Tombstones never do.
    var visibleSessions: [ChatSession] {
        let sessionIDsWithMessages = Set(messages.map { $0.sessionId })
        return sessions.filter { !$0.isTombstone && (sessionIDsWithMessages.contains($0.id) || hasMessages($0)) }
    }
}

/// What the menu bar, the toolbar and the sidebar share, so each command has one owner.
extension AppViewModel {
    /// The open chat, if a chat is open.
    var selectedSession: ChatSession? {
        guard case .session(let id) = selection else {
            return nil
        }
        return sessions.first { $0.id == id }
    }

    /// ⌘N, and the agent pane's New chat: a chat with the agent the pane shows, whether or not
    /// the pane is open. With no agent yet it opens Add Agent instead.
    func startNewChat() {
        guard let agent = paneAgent else {
            showAddAgent()
            return
        }
        focusedAgentID = agent.id
        createNewSession(for: agent)
    }

    /// ⇧⌘N, and the rail's Add agent.
    func showAddAgent() {
        if selection != .newConfiguration && selection != .chooseAgent {
            previousSelection = selection
        }
        selection = .chooseAgent
    }

    func requestRenameChat() {
        renameChatRequests += 1
    }
}
