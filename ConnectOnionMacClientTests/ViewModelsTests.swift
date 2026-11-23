import AppKit
import ConnectOnionKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class ViewModelsTests: XCTestCase {
    @MainActor
    func testDefaultStateStartsWithoutSavedAgents() async {
        let viewModel = AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: []
        )

        XCTAssertTrue(viewModel.configurations.isEmpty)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.selection)
    }

    @MainActor
    func testLocalAgentDiscoveryAddsReachableMainAgentAndPersistsIt() async throws {
        let storage = makeIsolatedDefaults()
        let mainAgentURL = "http://127.0.0.1:8000"
        let mainAgentAddress = "0x" + String(repeating: "ab", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: mainAgentAddress,
            webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: try XCTUnwrap(URL(string: mainAgentURL)),
            isDirect: true,
            info: ConnectOnionAgentInfo(
                name: "main-agent",
                address: mainAgentAddress,
                tools: [],
                model: "co/gemini-2.5-pro",
                trust: "open",
                version: "1.2.1",
                acceptedInputs: nil
            )
        )
        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [
                LocalAgentDefinition(
                    fallbackName: "Main Agent",
                    endpoint: mainAgentURL
                )
            ],
            resolveAgentEndpoint: { target in
                guard target == mainAgentURL else {
                    throw ConnectOnionRemoteError.agentOffline
                }
                return endpoint
            }
        )

        await viewModel.discoverLocalAgents()

        let configuration = try XCTUnwrap(viewModel.configurations.first)
        XCTAssertEqual(viewModel.configurations.count, 1)
        XCTAssertEqual(configuration.name, "main-agent")
        XCTAssertEqual(
            configuration.addressConfiguration?.agentAddress,
            mainAgentURL
        )
        XCTAssertTrue(viewModel.isAgentConnected(configuration))
        XCTAssertEqual(
            viewModel.agentConnectionSnapshots[configuration.id]?.state,
            .online
        )

        let reloaded = AppViewModel(
            storage: storage,
            localAgentDefinitions: []
        )
        XCTAssertEqual(reloaded.configurations, [configuration])
    }

    @MainActor
    func testLocalAgentDiscoveryDeduplicatesAndPreservesUserName() async throws {
        let localURL = "http://127.0.0.1:8000/"
        let address = "0x" + String(repeating: "cd", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: try XCTUnwrap(URL(string: localURL)),
            isDirect: true,
            info: ConnectOnionAgentInfo(
                name: "remote-main-name",
                address: address,
                tools: [],
                model: nil,
                trust: "open",
                version: "1.2.1",
                acceptedInputs: nil
            )
        )
        let viewModel = AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: [
                LocalAgentDefinition(
                    fallbackName: "Main Agent",
                    endpoint: "http://127.0.0.1:8000"
                )
            ],
            resolveAgentEndpoint: { _ in endpoint }
        )
        let existing = GeneralAgentConfiguration(
            name: "My Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: localURL
            )
        )
        viewModel.configurations = [existing]

        await viewModel.discoverLocalAgents()
        await viewModel.discoverLocalAgents()

        XCTAssertEqual(viewModel.configurations.map(\.id), [existing.id])
        XCTAssertEqual(viewModel.configurations[0].name, "My Main Agent")
        XCTAssertEqual(viewModel.configurations[0].agentAddress, address, "the Direct URL agent learns its Address")
        XCTAssertTrue(viewModel.isAgentConnected(existing))
    }

    @MainActor
    func testLocalAgentDiscoveryMatchesExistingRelayAddress() async {
        let address = "0x" + String(repeating: "ef", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "ws://127.0.0.1:8000/ws")!,
            httpBaseURL: URL(string: "http://127.0.0.1:8000")!,
            isDirect: true,
            info: nil
        )
        let viewModel = AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: [
                LocalAgentDefinition(
                    fallbackName: "Main Agent",
                    endpoint: "http://127.0.0.1:8000"
                )
            ],
            resolveAgentEndpoint: { _ in endpoint }
        )
        let existing = GeneralAgentConfiguration(
            name: "Saved by address",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: address
            )
        )
        viewModel.configurations = [existing]

        await viewModel.discoverLocalAgents()

        XCTAssertEqual(viewModel.configurations, [existing])
        XCTAssertTrue(viewModel.isAgentConnected(existing))
    }

    func testAutomaticLocalDiscoveryIncludesOnlyMainAgent() {
        XCTAssertEqual(
            LocalAgentDefinition.automaticDiscoveryTargets,
            [
                LocalAgentDefinition(
                    fallbackName: "Main Agent",
                    endpoint: "http://127.0.0.1:8000"
                )
            ]
        )
    }

    @MainActor
    func testNewChatIsDraftUntilFirstMessageIsSent() async throws {
        let storage = makeIsolatedDefaults()
        let viewModel = AppViewModel(storage: storage, localAgentDefinitions: [])
        let configuration = makeHostedConfiguration()
        viewModel.configurations = [configuration]

        viewModel.createNewSession(for: configuration)
        let draft = try XCTUnwrap(viewModel.sessions.first)

        // Selected, but hidden from the sidebar and not persisted.
        XCTAssertEqual(viewModel.selection, .session(draft.id))
        XCTAssertTrue(viewModel.visibleSessions.isEmpty)
        XCTAssertTrue(
            AppViewModel(storage: storage, localAgentDefinitions: [])
                .sessions.isEmpty
        )

        viewModel.addMessage(
            ChatMessage(sessionId: draft.id, role: .user, content: "Hello")
        )

        XCTAssertEqual(viewModel.visibleSessions.map(\.id), [draft.id])
        XCTAssertEqual(
            AppViewModel(storage: storage, localAgentDefinitions: [])
                .sessions.map(\.id),
            [draft.id]
        )
    }

    @MainActor
    func testRepeatedNewChatReusesDraftAndLeavingDiscardsIt() async throws {
        let viewModel = AppViewModel(
            storage: makeIsolatedDefaults(),
            localAgentDefinitions: []
        )
        let configuration = makeHostedConfiguration()
        viewModel.configurations = [configuration]

        viewModel.createNewSession(for: configuration)
        viewModel.createNewSession(for: configuration)
        XCTAssertEqual(viewModel.sessions.count, 1)

        viewModel.selection = nil
        XCTAssertTrue(viewModel.sessions.isEmpty)
    }

    @MainActor
    func testCreateSessionSelectsItAndTitleUpdatesAreNormalized() async throws {
        let viewModel = makeViewModel()
        let configuration = makeHostedConfiguration()

        viewModel.createNewSession(for: configuration)

        let session = try XCTUnwrap(viewModel.sessions.first)
        XCTAssertEqual(session.agentConfigId, configuration.id)
        XCTAssertEqual(
            session.remoteSessionID,
            session.id.uuidString.lowercased()
        )
        XCTAssertEqual(session.title, "New chat")
        XCTAssertEqual(viewModel.selection, .session(session.id))

        viewModel.updateSessionTitle(session, with: "/help")
        XCTAssertEqual(viewModel.sessions[0].title, "New chat", "a slash command never names a chat")

        viewModel.updateSessionTitle(
            session,
            with: "  This message is deliberately longer than forty characters.  "
        )
        XCTAssertEqual(viewModel.sessions[0].title, "This message is deliberately longer than forty characters.")

        viewModel.updateSessionTitle(viewModel.sessions[0], with: "A later message")
        XCTAssertEqual(viewModel.sessions[0].title, "This message is deliberately longer than forty characters.", "named once")

        viewModel.renameSession(viewModel.sessions[0], to: "  Renamed chat  ")
        XCTAssertEqual(viewModel.sessions[0].title, "Renamed chat")
        viewModel.renameSession(viewModel.sessions[0], to: " \n ")
        XCTAssertEqual(viewModel.sessions[0].title, "New chat")
    }

    @MainActor
    func testSelectingHistoricalSessionPublishesEveryClick() async {
        let viewModel = makeViewModel()
        let sessionID = UUID()

        viewModel.selectHistoricalSession(sessionID)
        let firstRevision = viewModel.sessionSelectionRevision
        viewModel.selectHistoricalSession(sessionID)

        XCTAssertEqual(viewModel.selection, .session(sessionID))
        XCTAssertEqual(viewModel.sessionSelectionRevision, firstRevision + 1)
    }

    @MainActor
    func testLocalAgentHistoryImportsAndPersistsHostedChat() async throws {
        let storage = makeIsolatedDefaults()
        let remoteSessionID = UUID().uuidString.lowercased()
        ViewModelHistoryURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/sessions")
            let body = try JSONSerialization.data(withJSONObject: [
                "sessions": [
                    [
                        "session_id": remoteSessionID,
                        "status": "done",
                        "prompt": "History from web",
                        "result": "Durable response",
                        "created": 1_700_000_000,
                        "session": [
                            "updated": 1_700_000_020,
                            "messages": [
                                [
                                    "role": "system",
                                    "content": "You are a helpful agent."
                                ],
                                [
                                    "role": "user",
                                    "content": "History from web"
                                ],
                                [
                                    "role": "assistant",
                                    "content": "Understood, I'll handle that."
                                ],
                                [
                                    "role": "assistant",
                                    "content": "Durable response"
                                ],
                                [
                                    "role": "assistant",
                                    "content": "hidden",
                                    "internal": true
                                ]
                            ]
                        ]
                    ]
                ]
            ])
            return (
                try makeViewModelHistoryResponse(for: request),
                body
            )
        }
        defer { ViewModelHistoryURLProtocol.reset() }
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [ViewModelHistoryURLProtocol.self]
        let mainAgentURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:8000")
        )
        let address = "0x" + String(repeating: "ab", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(
                URL(string: "ws://127.0.0.1:8000/ws")
            ),
            httpBaseURL: mainAgentURL,
            isDirect: true,
            info: nil
        )
        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [
                LocalAgentDefinition(
                    fallbackName: "Main Agent",
                    endpoint: mainAgentURL.absoluteString
                )
            ],
            historyURLSession: URLSession(configuration: urlConfiguration),
            historyKeyStore: InMemoryPrivateKeyStore(),
            resolveAgentEndpoint: { _ in endpoint }
        )

        await viewModel.discoverLocalAgents()

        let imported = try XCTUnwrap(viewModel.sessions.first)
        XCTAssertEqual(imported.remoteSessionID, remoteSessionID)
        XCTAssertEqual(imported.title, "History from web")
        XCTAssertEqual(
            viewModel.findMessages(for: imported.id).map(\.content),
            ["History from web", "Durable response"]
        )

        let reloaded = AppViewModel(
            storage: storage,
            localAgentDefinitions: []
        )
        XCTAssertEqual(reloaded.sessions.first?.remoteSessionID, remoteSessionID)
        XCTAssertEqual(
            reloaded.findMessages(for: imported.id).map(\.content),
            ["History from web", "Durable response"]
        )
    }

    @MainActor
    func testLegacySessionMigratesPersistedRemoteIdentifier() async throws {
        let storage = makeIsolatedDefaults()
        let configuration = makeHostedConfiguration()
        let session = ChatSession(
            agentConfigId: configuration.id,
            agentIdentity: configuration.agentIdentity,
            title: "Legacy"
        )
        storage.set(
            try JSONEncoder().encode([configuration]),
            forKey: "saved_configurations"
        )
        storage.set(
            try JSONEncoder().encode([session]),
            forKey: "saved_sessions"
        )
        // Sessions without messages are drafts and are discarded on load.
        storage.set(
            try JSONEncoder().encode([
                ChatMessage(
                    sessionId: session.id,
                    role: .user,
                    content: "Legacy message"
                )
            ]),
            forKey: "saved_messages"
        )
        storage.set(
            try JSONSerialization.data(withJSONObject: [
                "sessionID": "legacy-remote-session"
            ]),
            forKey: "connectonion.remote-session.\(session.id.uuidString)"
        )

        let reloaded = AppViewModel(
            storage: storage,
            localAgentDefinitions: []
        )

        XCTAssertEqual(
            reloaded.sessions.first?.remoteSessionID,
            "legacy-remote-session"
        )
    }

    @MainActor
    func testSaveAgentUpdatesExistingConfigurationAndCreatesSession() async {
        let viewModel = makeViewModel()
        var configuration = makeHostedConfiguration()
        viewModel.configurations = [configuration]
        configuration.name = "Updated Agent"

        viewModel.saveAgent(configuration)

        XCTAssertEqual(viewModel.configurations.count, 1)
        XCTAssertEqual(viewModel.configurations[0].name, "Updated Agent")
        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.sessions[0].agentConfigId, configuration.id)
        XCTAssertEqual(viewModel.selection, .session(viewModel.sessions[0].id))
    }

    @MainActor
    func testRenameAgentTrimsNameRejectsEmptyValueAndPersists() async {
        let storage = makeIsolatedDefaults()
        let viewModel = AppViewModel(storage: storage)
        let configuration = makeHostedConfiguration()
        viewModel.configurations = [configuration]
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        let chatViewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: viewModel
        )

        viewModel.renameAgent(configuration, to: "  Renamed Agent  ")
        XCTAssertEqual(viewModel.configurations[0].name, "Renamed Agent")
        XCTAssertEqual(chatViewModel.configuration.name, "Renamed Agent")

        viewModel.renameAgent(viewModel.configurations[0], to: " \n ")
        XCTAssertEqual(viewModel.configurations[0].name, "Renamed Agent")

        let reloaded = AppViewModel(storage: storage)
        XCTAssertEqual(reloaded.configurations[0].name, "Renamed Agent")
    }

    @MainActor
    func testConnectionAndSessionDateUpdates() async {
        let viewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        var session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        session.updatedAt = Date(timeIntervalSince1970: 0)
        viewModel.configurations = [configuration]
        viewModel.sessions = [session]

        viewModel.setAgentConnected(configuration, isConnected: true)
        viewModel.updateSessionDate(session)

        XCTAssertTrue(viewModel.isAgentConnected(configuration))
        XCTAssertGreaterThan(viewModel.sessions[0].updatedAt, session.updatedAt)

        viewModel.setAgentConnected(configuration, isConnected: false)
        XCTAssertFalse(viewModel.isAgentConnected(configuration))
    }

    @MainActor
    func testWorkRoomBarrierScopeIsStablePerChat() {
        let viewModel = makeViewModel()
        let agentId = UUID()
        let first = ChatSession(agentConfigId: agentId, agentIdentity: "0xabc", title: "One")
        let second = ChatSession(agentConfigId: agentId, agentIdentity: "0xabc", title: "Two")
        let reloaded = first

        XCTAssertNotEqual(
            viewModel.workRoomBarrierScope(for: first),
            viewModel.workRoomBarrierScope(for: second)
        )
        XCTAssertEqual(
            viewModel.workRoomBarrierScope(for: first),
            viewModel.workRoomBarrierScope(for: reloaded)
        )
    }

    @MainActor
    func testDeleteSessionRemovesAllRelatedStateAndSelection() async {
        let viewModel = makeViewModel()
        let session = ChatSession(agentConfigId: UUID(), title: "Delete me")
        let retainedSession = ChatSession(agentConfigId: UUID(), title: "Keep me")
        let deletedMessage = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Delete"
        )
        let retainedMessage = ChatMessage(
            sessionId: retainedSession.id,
            role: .user,
            content: "Keep"
        )
        let item = ExecutionItem.intent(
            IntentExecutionItem(id: "intent", status: .understood)
        )
        let run = ExecutionRun(sessionId: session.id)
        viewModel.sessions = [session, retainedSession]
        viewModel.messages = [deletedMessage, retainedMessage]
        viewModel.setExecutionItems([item], for: session.id)
        viewModel.setExecutionRuns([run], for: session.id)
        viewModel.selection = .session(session.id)

        viewModel.deleteSession(session)

        XCTAssertEqual(viewModel.visibleSessions, [retainedSession])
        XCTAssertEqual(viewModel.messages, [retainedMessage])
        XCTAssertTrue(viewModel.findExecutionItems(for: session.id).isEmpty)
        XCTAssertTrue(viewModel.findExecutionRuns(for: session.id).isEmpty)
        XCTAssertNil(viewModel.selection)
    }

    @MainActor
    func testDeletedHostedSessionDoesNotReturnDuringLaterHistorySync() async throws {
        let storage = makeIsolatedDefaults()
        let remoteSessionID = UUID().uuidString.lowercased()
        ViewModelHistoryURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/sessions")
            let body = try JSONSerialization.data(withJSONObject: [
                "sessions": [
                    [
                        "session_id": remoteSessionID,
                        "status": "done",
                        "prompt": "Deleted in another client",
                        "result": "Old response",
                        "created": 1_700_000_000,
                        "session": [
                            "updated": 1_700_000_010,
                            "messages": [
                                [
                                    "role": "user",
                                    "content": "Deleted in another client"
                                ],
                                [
                                    "role": "assistant",
                                    "content": "Old response"
                                ]
                            ]
                        ]
                    ]
                ]
            ])
            return (
                try makeViewModelHistoryResponse(for: request),
                body
            )
        }
        defer { ViewModelHistoryURLProtocol.reset() }
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [ViewModelHistoryURLProtocol.self]
        let mainAgentURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:8000")
        )
        let address = "0x" + String(repeating: "ab", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(
                URL(string: "ws://127.0.0.1:8000/ws")
            ),
            httpBaseURL: mainAgentURL,
            isDirect: true,
            info: nil
        )
        let definitions = [
            LocalAgentDefinition(
                fallbackName: "Main Agent",
                endpoint: mainAgentURL.absoluteString
            )
        ]
        let historyURLSession = URLSession(configuration: urlConfiguration)
        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: definitions,
            historyURLSession: historyURLSession,
            historyKeyStore: InMemoryPrivateKeyStore(),
            resolveAgentEndpoint: { _ in endpoint }
        )

        await viewModel.discoverLocalAgents()
        let imported = try XCTUnwrap(viewModel.sessions.first)
        viewModel.deleteSession(imported)
        XCTAssertTrue(viewModel.visibleSessions.isEmpty)

        let reloaded = AppViewModel(
            storage: storage,
            localAgentDefinitions: definitions,
            historyURLSession: historyURLSession,
            historyKeyStore: InMemoryPrivateKeyStore(),
            resolveAgentEndpoint: { _ in endpoint }
        )
        await reloaded.discoverLocalAgents()

        XCTAssertTrue(reloaded.visibleSessions.isEmpty)
        XCTAssertTrue(reloaded.messages.isEmpty)
    }

    @MainActor
    func testMessagesAndExecutionItemsCanBeAddedUpdatedAndFound() async {
        let viewModel = makeViewModel()
        let sessionID = UUID()
        var message = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Hello"
        )
        message.status = .sending
        let firstItem = ExecutionItem.intent(
            IntentExecutionItem(id: "first", status: .analyzing)
        )
        let secondItem = ExecutionItem.thinking(
            ThinkingExecutionItem(id: "second", status: .running)
        )

        viewModel.addMessage(message)
        viewModel.updateMessageStatus(message.id, to: .queued)
        viewModel.setExecutionItems([firstItem], for: sessionID)
        viewModel.addExecutionItem(secondItem, for: sessionID)
        viewModel.setExecutionRuns([ExecutionRun(sessionId: sessionID)], for: sessionID)

        XCTAssertEqual(viewModel.findMessages(for: sessionID).first?.status, .queued)
        XCTAssertEqual(viewModel.findExecutionItems(for: sessionID).map(\.id), ["first", "second"])
        XCTAssertEqual(viewModel.findExecutionRuns(for: sessionID).count, 1)
        XCTAssertTrue(viewModel.findMessages(for: UUID()).isEmpty)
    }

}

private final class ViewModelHistoryURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        Self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeViewModelHistoryResponse(
    for request: URLRequest
) throws -> HTTPURLResponse {
    let url = try XCTUnwrap(request.url)
    return try XCTUnwrap(
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )
    )
}
