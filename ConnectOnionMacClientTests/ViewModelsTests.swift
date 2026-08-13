import AppKit
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

        XCTAssertEqual(viewModel.configurations, [existing])
        XCTAssertEqual(viewModel.configurations[0].name, "My Main Agent")
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
        XCTAssertEqual(session.title, "New Chat")
        XCTAssertEqual(viewModel.selection, .session(session.id))

        viewModel.updateSessionTitle(
            session,
            with: "  This message is deliberately longer than forty characters.  "
        )
        XCTAssertEqual(viewModel.sessions[0].title.count, 40)
        XCTAssertTrue(viewModel.sessions[0].title.hasPrefix("This message"))

        viewModel.renameSession(viewModel.sessions[0], to: "  Renamed chat  ")
        XCTAssertEqual(viewModel.sessions[0].title, "Renamed chat")
        viewModel.renameSession(viewModel.sessions[0], to: " \n ")
        XCTAssertEqual(viewModel.sessions[0].title, "New Chat")
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
            historyClient: ConnectOnionHistoryClient(
                urlSession: URLSession(configuration: urlConfiguration)
            ),
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
    func testHostedHistoryUpdatePreservesGeneratedArtifactMetadata() async throws {
        let storage = makeIsolatedDefaults()
        let remoteSessionID = UUID().uuidString.lowercased()
        let remoteUpdated = Date().timeIntervalSince1970 + 60
        ViewModelHistoryURLProtocol.install { request in
            let body = try JSONSerialization.data(withJSONObject: [
                "sessions": [
                    [
                        "session_id": remoteSessionID,
                        "status": "done",
                        "prompt": "Export the report",
                        "result": "Your updated report is ready.",
                        "created": remoteUpdated - 10,
                        "session": [
                            "updated": remoteUpdated,
                            "messages": [
                                [
                                    "role": "user",
                                    "content": "Export the report"
                                ],
                                [
                                    "role": "assistant",
                                    "content": "Your updated report is ready."
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

        let mainAgentURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8000"))
        let address = "0x" + String(repeating: "ab", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: mainAgentURL,
            isDirect: true,
            info: nil
        )
        let configuration = GeneralAgentConfiguration(
            name: "Main Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: mainAgentURL.absoluteString
            )
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            agentIdentity: configuration.agentIdentity,
            remoteSessionID: remoteSessionID,
            title: "Export the report",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let userMessage = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: "Export the report"
        )
        let artifact = GeneratedArtifactReference(
            artifactID: UUID().uuidString,
            name: "report.txt",
            mimeType: "text/plain",
            sizeBytes: 12,
            sha256: String(repeating: "a", count: 64)
        )
        let agentMessage = ChatMessage(
            sessionId: session.id,
            role: .agent,
            content: "Your report is ready.",
            usage: ChatUsageSummary(
                tokenCount: 120,
                totalCost: 0.01,
                contextPercent: 2
            ),
            replyToMessageID: userMessage.id,
            artifacts: [artifact]
        )
        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: [],
            historyClient: ConnectOnionHistoryClient(
                urlSession: URLSession(
                    configuration: {
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.protocolClasses = [ViewModelHistoryURLProtocol.self]
                        return configuration
                    }()
                )
            ),
            resolveAgentEndpoint: { _ in endpoint }
        )
        viewModel.configurations = [configuration]
        viewModel.sessions = [session]
        viewModel.messages = [userMessage, agentMessage]

        await viewModel.refreshAgentStatusAndWait(for: configuration)

        let synchronized = viewModel.findMessages(for: session.id)
        XCTAssertEqual(synchronized.map(\.content), [
            "Export the report",
            "Your updated report is ready."
        ])
        XCTAssertEqual(synchronized[0].id, userMessage.id)
        XCTAssertEqual(synchronized[1].id, agentMessage.id)
        XCTAssertEqual(synchronized[1].artifacts, [artifact])
        XCTAssertEqual(synchronized[1].usage, agentMessage.usage)
        XCTAssertEqual(synchronized[1].replyToMessageID, userMessage.id)
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
    func testAvatarConnectionAndSessionDateUpdates() async {
        let viewModel = makeViewModel()
        let configuration = makeHostedConfiguration()
        var session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        session.updatedAt = Date(timeIntervalSince1970: 0)
        viewModel.configurations = [configuration]
        viewModel.sessions = [session]

        viewModel.updateAgentAvatar(
            configuration,
            textColorHex: "#FFFFFF",
            backgroundColorHex: "#123456"
        )
        viewModel.setAgentConnected(configuration, isConnected: true)
        viewModel.updateSessionDate(session)

        XCTAssertEqual(viewModel.configurations[0].avatarTextColorHex, "#FFFFFF")
        XCTAssertEqual(viewModel.configurations[0].avatarBackgroundColorHex, "#123456")
        XCTAssertTrue(viewModel.isAgentConnected(configuration))
        XCTAssertGreaterThan(viewModel.sessions[0].updatedAt, session.updatedAt)

        viewModel.setAgentConnected(configuration, isConnected: false)
        XCTAssertFalse(viewModel.isAgentConnected(configuration))
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

        XCTAssertEqual(viewModel.sessions, [retainedSession])
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
        let historyClient = ConnectOnionHistoryClient(
            urlSession: URLSession(configuration: urlConfiguration)
        )
        let viewModel = AppViewModel(
            storage: storage,
            localAgentDefinitions: definitions,
            historyClient: historyClient,
            resolveAgentEndpoint: { _ in endpoint }
        )

        await viewModel.discoverLocalAgents()
        let imported = try XCTUnwrap(viewModel.sessions.first)
        viewModel.deleteSession(imported)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        let reloaded = AppViewModel(
            storage: storage,
            localAgentDefinitions: definitions,
            historyClient: historyClient,
            resolveAgentEndpoint: { _ in endpoint }
        )
        await reloaded.discoverLocalAgents()

        XCTAssertTrue(reloaded.sessions.isEmpty)
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
