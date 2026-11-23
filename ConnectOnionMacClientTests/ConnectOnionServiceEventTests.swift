import Combine
import CryptoKit
import XCTest
import ConnectOnionKit
@testable import ConnectOnionMacClient

extension ConnectOnionServiceTests {
    func testThinkingEventsDecodeReActDisplayContent() throws {
        let reflectEvent: [String: Any] = [
            "type": "thinking",
            "id": "reflect-1",
            "kind": "reflect",
            "content": "The tool returned the requested system information."
        ]
        let intentEvent: [String: Any] = [
            "type": "thinking",
            "id": "intent-1",
            "kind": "intent",
            "content": "I will inspect the system information.",
            "status": "running"
        ]

        let reflectItem = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(from: reflectEvent)
        )
        let intentItem = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(from: intentEvent)
        )

        guard case .thinking(let reflection) = reflectItem,
              case .thinking(let intent) = intentItem else {
            return XCTFail("Expected thinking execution items")
        }
        XCTAssertEqual(reflection.status, .done)
        XCTAssertEqual(reflection.kind, "reflect")
        XCTAssertEqual(
            reflection.content,
            "The tool returned the requested system information."
        )
        XCTAssertEqual(intent.status, .running)
        XCTAssertEqual(intent.kind, "intent")
    }

    func testThinkingEventPreservesUnknownKindAndAllowsMissingContent() throws {
        let item = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(from: [
                "type": "thinking",
                "id": "future-1",
                "kind": "future_kind"
            ])
        )

        guard case .thinking(let thinking) = item else {
            return XCTFail("Expected thinking execution item")
        }
        XCTAssertEqual(thinking.status, .done)
        XCTAssertEqual(thinking.kind, "future_kind")
        XCTAssertNil(thinking.content)
    }

    func testLegacyThinkingItemDecodesWithoutReActFields() throws {
        let data = Data(
            #"{"id":"legacy-thinking","status":"done","model":"gemini"}"#.utf8
        )

        let item = try JSONDecoder().decode(ThinkingExecutionItem.self, from: data)

        XCTAssertEqual(item.id, "legacy-thinking")
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(item.model, "gemini")
        XCTAssertNil(item.kind)
        XCTAssertNil(item.content)
    }

    func testThinkingItemMergePreservesReActFields() {
        let existing = ExecutionItem.thinking(
            ThinkingExecutionItem(
                id: "reflect-merge",
                status: .running,
                model: nil,
                durationMS: nil,
                usage: nil,
                contextPercent: nil,
                kind: "reflect",
                content: "Reflection content"
            )
        )
        let update = ExecutionItem.thinking(
            ThinkingExecutionItem(
                id: "reflect-merge",
                status: .done,
                model: "gemini",
                durationMS: 125,
                usage: nil,
                contextPercent: nil
            )
        )

        let merged = update.mergingDisplayFields(from: existing)

        guard case .thinking(let thinking) = merged else {
            return XCTFail("Expected thinking execution item")
        }
        XCTAssertEqual(thinking.status, .done)
        XCTAssertEqual(thinking.kind, "reflect")
        XCTAssertEqual(thinking.content, "Reflection content")
        XCTAssertEqual(thinking.model, "gemini")
        XCTAssertEqual(thinking.durationMS, 125)
    }

    @MainActor
    func testChatViewModelOrdersAndDeduplicatesReActExecutionItems() {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "ReAct Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "78", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "ReAct")
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        let items: [ExecutionItem] = [
            .intent(IntentExecutionItem(id: "intent", status: .understood, ack: "Understood", isBuild: false)),
            .thinking(ThinkingExecutionItem(id: "llm", status: .done, model: "gemini", durationMS: 10, usage: nil, contextPercent: nil)),
            .toolCall(ToolCallExecutionItem(id: "tool", name: "get_system_info", args: [:], status: .done, result: "macOS", timingMS: 5)),
            .thinking(
                ThinkingExecutionItem(
                    id: "reflect",
                    status: .done,
                    model: nil,
                    durationMS: nil,
                    usage: nil,
                    contextPercent: nil,
                    kind: "reflect",
                    content: "The system information was returned."
                )
            ),
            .eval(
                EvalExecutionItem(
                    id: "eval",
                    status: .done,
                    passed: true,
                    summary: "Task complete",
                    expected: "Display system information",
                    evalPath: nil
                )
            )
        ]

        for item in items {
            viewModel.handleIncomingEvent(.executionItem(item))
        }
        viewModel.handleIncomingEvent(
            .executionItem(
                .thinking(
                    ThinkingExecutionItem(
                        id: "reflect",
                        status: .done,
                        model: nil,
                        durationMS: nil,
                        usage: nil,
                        contextPercent: nil,
                        kind: "reflect",
                        content: "Updated reflection."
                    )
                )
            )
        )
        viewModel.handleIncomingEvent(.output("Finished"))

        XCTAssertEqual(viewModel.executionItems.map(\.id), ["intent", "llm", "tool", "reflect", "eval"])
        XCTAssertEqual(viewModel.executionRuns.count, 1)
        XCTAssertEqual(viewModel.executionRuns[0].status, .done)
        XCTAssertEqual(viewModel.executionRuns[0].items.count, 5)
        guard case .thinking(let reflection) = viewModel.executionRuns[0].items[3] else {
            return XCTFail("Expected reflection item")
        }
        XCTAssertEqual(reflection.content, "Updated reflection.")
    }

    @MainActor
    func testChatViewModelMarksRunningThinkingAsError() {
        let storage = makeIsolatedDefaults()
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "Failed ReAct Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "0x" + String(repeating: "90", count: 32)
            )
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Failed ReAct")
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        viewModel.handleIncomingEvent(
            .executionItem(
                .thinking(
                    ThinkingExecutionItem(
                        id: "reflect-running",
                        status: .running,
                        model: nil,
                        durationMS: nil,
                        usage: nil,
                        contextPercent: nil,
                        kind: "reflect",
                        content: nil
                    )
                )
            )
        )

        viewModel.handleIncomingEvent(.error("Reflection failed"))

        XCTAssertEqual(viewModel.executionRuns.count, 1)
        XCTAssertEqual(viewModel.executionRuns[0].status, .error)
        guard case .thinking(let thinking) = viewModel.executionRuns[0].items[0] else {
            return XCTFail("Expected thinking item")
        }
        XCTAssertEqual(thinking.status, .error)
    }

    static func eventLabel(
        _ event: ConnectOnionTransportEvent
    ) -> String {
        switch event {
        case .output(let value):
            return "output:\(value)"
        case .modeChanged(let value, _):
            return "mode:\(value.rawValue)"
        case .error(let value):
            return "error:\(value)"
        default:
            return "other"
        }
    }

    @MainActor
    func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }

    @MainActor
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "ConnectOnionMacClientTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        return storage
    }

    func data(fromHex value: String) throws -> Data {
        guard value.count.isMultiple(of: 2) else {
            throw HexError.invalid
        }

        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw HexError.invalid
            }
            result.append(byte)
            index = next
        }
        return result
    }

    func assertApprovalMessage(
        _ message: [String: Any],
        approved: Bool,
        scope: String
    ) {
        XCTAssertEqual(message["approved"] as? Bool, approved)
        XCTAssertEqual(message["scope"] as? String, scope)
    }

    private enum HexError: Error {
        case invalid
    }
}

// Opening a chat shows the host's Control Center before anything is sent, as O Chat does.
extension ConnectOnionServiceTests {
    @MainActor
    func testOpeningAChatShowsTheHostsControlCenterBeforeAnyMessage() async throws {
        let socketURL = try XCTUnwrap(URL(string: "wss://agent.test/ws"))
        let address = "0x" + String(repeating: "c1", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: socketURL,
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        await stub.setProfileVisitEvents([.dashboard(.page(html: "<main>starter</main>"))])

        let configuration = GeneralAgentConfiguration(
            name: "Starter Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let viewModel = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Starter"),
            configuration: configuration,
            service: ConnectOnionService(remoteAgentFactory: { _, _, _ in stub }),
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )

        viewModel.connectIfNeeded() // what ChatView.onAppear does when the chat opens
        await waitUntil { viewModel.dashboard != nil }

        XCTAssertEqual(viewModel.dashboard, .page(html: "<main>starter</main>"))
        XCTAssertTrue(viewModel.messages.isEmpty, "no turn was needed")
    }

    // A Control Center button's line, already checked by the kit pane, is a normal visible turn.
    @MainActor
    func testAControlCenterSkillIsSentAsAMessageAndKeepsTheDraft() async throws {
        let socketURL = try XCTUnwrap(URL(string: "wss://agent.test/ws"))
        let address = "0x" + String(repeating: "c2", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: socketURL,
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )

        let configuration = GeneralAgentConfiguration(
            name: "Skill Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let viewModel = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Skills"),
            configuration: configuration,
            service: ConnectOnionService(remoteAgentFactory: { _, _, _ in stub }),
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )

        viewModel.inputText = "half a thought"
        viewModel.runControlCenterSkill("/deploy to staging")

        XCTAssertEqual(viewModel.messages.map(\.content), ["/deploy to staging"])
        XCTAssertEqual(viewModel.messages.first?.role, .user)
        XCTAssertEqual(viewModel.inputText, "half a thought")
    }

    // A press while the host waits on an approval or an answer must leave that card alone: sending would
    // clear it and the turn would stall until Stop.
    @MainActor
    func testAControlCenterSkillIsIgnoredWhileAnInteractionIsPending() async throws {
        let socketURL = try XCTUnwrap(URL(string: "wss://agent.test/ws"))
        let address = "0x" + String(repeating: "c3", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: socketURL,
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        let configuration = GeneralAgentConfiguration(
            name: "Skill Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let viewModel = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Skills"),
            configuration: configuration,
            service: ConnectOnionService(remoteAgentFactory: { _, _, _ in stub }),
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )

        let approval = ConnectOnionApprovalRequest(
            id: "deploy-approval",
            tool: "deploy",
            arguments: .object([:]),
            description: "Deploy to staging",
            batchRemaining: []
        )
        viewModel.pendingInteraction = .approval(approval)
        viewModel.runControlCenterSkill("/deploy to staging")
        XCTAssertEqual(viewModel.pendingInteraction, .approval(approval))
        XCTAssertTrue(viewModel.messages.isEmpty)

        let question = ConnectOnionAskUserRequest(
            id: "which-env",
            question: "Which environment?",
            options: ["staging", "production"],
            multiSelect: false,
            fields: []
        )
        viewModel.pendingInteraction = .askUser(question)
        viewModel.runControlCenterSkill("/deploy to staging")
        XCTAssertEqual(viewModel.pendingInteraction, .askUser(question))
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.pendingInteraction = nil
        viewModel.service.isInterruptRequested = true
        viewModel.runControlCenterSkill("/deploy to staging")
        viewModel.inputText = "typed while stopping"
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.inputText, "typed while stopping")

        viewModel.service.isInterruptRequested = false
        viewModel.runControlCenterSkill("/deploy to staging")
        XCTAssertEqual(viewModel.messages.map(\.content), ["/deploy to staging"])
    }

    @MainActor
    func testNewChatOnAStationReopensItsOneSession() {
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults())
        var configuration = GeneralAgentConfiguration(
            name: "Station",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "7a", count: 32))
        )
        configuration.isClaudeStation = true
        appViewModel.configurations = [configuration]
        appViewModel.createNewSession(for: configuration)
        appViewModel.selection = nil
        appViewModel.createNewSession(for: configuration)

        XCTAssertEqual(appViewModel.sessions.count, 1)
        XCTAssertEqual(appViewModel.selection, .session(appViewModel.sessions[0].id))
    }

    @MainActor
    func testStationRefusalMakesAStationAndNothingIsSentToIt() {
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults())
        let configuration = GeneralAgentConfiguration(
            name: "Station",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "79", count: 32))
        )
        appViewModel.configurations = [configuration]
        appViewModel.createNewSession(for: configuration)
        appViewModel.createNewSession(for: configuration)
        XCTAssertEqual(appViewModel.sessions.count, 1)
        let session = appViewModel.sessions[0]
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        XCTAssertFalse(viewModel.isStation)

        let refusal = OIPServerFrame.decode([
            "type": .string("ERROR"), "code": .string("provider_station_only"), "message": .string("Station only")
        ])
        viewModel.handleIncomingEvent(.workRoomFrame(refusal))
        viewModel.handleIncomingEvent(.stationRefusedChat)

        XCTAssertTrue(viewModel.isStation)
        XCTAssertTrue(appViewModel.configurations[0].isClaudeStation)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.interactionError)
        viewModel.inputText = "hello"
        viewModel.sendMessage()
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    @MainActor
    func testAnOrdinaryErrorOnAStationIsStillShown() {
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults())
        var configuration = GeneralAgentConfiguration(
            name: "Station",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "78", count: 32))
        )
        configuration.isClaudeStation = true
        appViewModel.configurations = [configuration]
        appViewModel.createNewSession(for: configuration)
        let session = appViewModel.sessions[0]
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        XCTAssertTrue(viewModel.isStation)

        viewModel.handleIncomingEvent(.error("The agent is offline"))

        XCTAssertEqual(viewModel.interactionError, "The agent is offline")
        XCTAssertFalse(viewModel.messages.isEmpty)
    }

    @MainActor
    func testStationPaneCodeIsRememberedAndRestartsTheConnection() {
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults())
        let configuration = GeneralAgentConfiguration(
            name: "Station",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "7a", count: 32))
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Station")
        let viewModel = ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
        let request = ConnectOnionOnboardingRequest(id: "o", methods: ["invite_code"], paymentAmount: nil, paymentAddress: nil)
        viewModel.handleIncomingEvent(.onboardingRequired(request))
        XCTAssertTrue(viewModel.isStationAwaitingCode)

        viewModel.submitStationCode("  code-1 ")

        XCTAssertEqual(viewModel.stationInviteCode, "code-1")
        XCTAssertEqual(viewModel.stationOnboardingAttempt, 1)
        XCTAssertFalse(viewModel.isStationAwaitingCode)
        XCTAssertFalse(viewModel.workRooms.stationPairing.needsCode)
    }
}

// Mirrored Turn: a turn typed on another device holding this Identity plays here.
extension ConnectOnionRemoteAgentTests {
    func testViewerSocketJoinsWithSessionIDAndReportsMirroredTurn() async throws {
        let address = makeAddress("91")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Live Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "running",
                "session_id": conversationID.uuidString.lowercased(),
                "chat_items": [["type": "user", "content": "from the phone"]]
            ],
            ["type": "approval_needed", "id": "a-1", "tool": "bash", "arguments": [:]],
            ["type": "OUTPUT", "result": "mirrored reply"]
        ])
        let recorder = RemoteProtocolRecorder()
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket }
        )

        let ending = await client.observe(
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(ending, .turnFinished)
        let events = await recorder.snapshot().events
        // approval_needed also reaches the Work Room store first, as on a local turn.
        XCTAssertEqual(events, ["catch_up:1:true", "work_room_frame", "approval", "output:mirrored reply"])
        let sent = try socket.sentJSONObjects()
        XCTAssertEqual(sent.first?["type"] as? String, "CONNECT")
        XCTAssertEqual(sent.first?["session_id"] as? String, conversationID.uuidString.lowercased())
        XCTAssertFalse(sent.contains { $0["type"] as? String == "INPUT" }, "a viewer never sends input")
    }

    func testViewerShowsUserMessageFrameThenReply() async throws {
        let address = makeAddress("92")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Live Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "ready", "session_id": "s-92"],
            ["type": "user_message", "content": "Translate hello", "session_id": "s-92"],
            ["type": "OUTPUT", "result": "Hola"]
        ])
        let recorder = RemoteProtocolRecorder()
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket }
        )

        await client.observe(onUpdate: { _ in }, onEvent: { await recorder.record($0) })

        let events = await recorder.snapshot().events
        XCTAssertEqual(events, ["user_message:Translate hello", "output:Hola"])
    }
}

extension ConnectOnionServiceTests {
    @MainActor
    private func makeMirrorChat(
        observed: [ConnectOnionTransportEvent],
        holdOpen: Bool = false,
        isLinked: Bool = true
    ) async throws -> (ChatViewModel, ConnectOnionService) {
        let address = "0x" + String(repeating: "d1", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        await stub.setObservedEvents(observed, holdOpen: holdOpen)
        let configuration = GeneralAgentConfiguration(
            name: "Mirror Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let service = ConnectOnionService(isLinked: { isLinked }, remoteAgentFactory: { _, _, _ in stub })
        let viewModel = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Mirror"),
            configuration: configuration,
            service: service,
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )
        return (viewModel, service)
    }

    @MainActor
    func testMirroredTurnRendersUserBubbleThenReplyAndLocksUntilDone() async throws {
        let (viewModel, service) = try await makeMirrorChat(
            observed: [.mirroredUserMessage("from the phone"), .output("the reply")]
        )
        var lock: [Bool] = []
        let sink = service.$isMirroredTurn.removeDuplicates().sink { lock.append($0) }
        defer { sink.cancel() }

        viewModel.connectIfNeeded()
        await waitUntil { viewModel.messages.count == 2 }

        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(viewModel.messages.map(\.content), ["from the phone", "the reply"])
        await waitUntil { !service.isMirroredTurn && !service.isAgentRequestActive }
        XCTAssertEqual(lock, [false, true, false])
    }

    @MainActor
    func testSendIsBlockedAndStopOfferedWhileAMirroredTurnStreams() async throws {
        let (viewModel, service) = try await makeMirrorChat(
            observed: [.mirroredUserMessage("busy")],
            holdOpen: true
        )
        viewModel.connectIfNeeded()
        await waitUntil { service.isMirroredTurn }

        viewModel.inputText = "me too"
        viewModel.sendMessage()

        XCTAssertTrue(viewModel.isReplyingElsewhere)
        XCTAssertTrue(viewModel.canInterruptAgent, "Stop is offered")
        XCTAssertEqual(viewModel.messages.map(\.content), ["busy"], "Send did nothing")
        service.disconnect()
    }

    @MainActor
    func testOpeningAChatThatMovedOnCatchesUpToTheLatestTurn() async throws {
        let (viewModel, _) = try await makeMirrorChat(
            observed: [
                .catchUp(
                    [
                        CatchUpItem(role: .user, text: "old q"),
                        CatchUpItem(role: .agent, text: "old a"),
                        CatchUpItem(role: .user, text: "new q"),
                        CatchUpItem(role: .agent, text: "new a")
                    ],
                    isRunning: false
                )
            ]
        )
        viewModel.handleIncomingEvent(.mirroredUserMessage("old q"))
        viewModel.handleIncomingEvent(.output("old a"))
        viewModel.handleIncomingEvent(.catchUp(
            [
                CatchUpItem(role: .user, text: "old q"),
                CatchUpItem(role: .agent, text: "old a"),
                CatchUpItem(role: .user, text: "new q"),
                CatchUpItem(role: .agent, text: "new a")
            ],
            isRunning: false
        ))

        XCTAssertEqual(viewModel.messages.map(\.content), ["old q", "old a", "new q", "new a"])
    }

    @MainActor
    func testMirroredEventsAreIgnoredWhileALocalSendIsActive() async throws {
        let address = "0x" + String(repeating: "d2", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        await stub.setObservedEvents([
            .mirroredUserMessage("from the phone"),
            .catchUp([CatchUpItem(role: .user, text: "other")], isRunning: true)
        ])
        let configuration = GeneralAgentConfiguration(
            name: "Mirror Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let service = ConnectOnionService(isLinked: { true }, remoteAgentFactory: { _, _, _ in stub })
        service.connect(with: configuration)
        var received: [ConnectOnionTransportEvent] = []
        let sink = service.incomingEvents.sink { received.append($0) }
        defer { sink.cancel() }
        await stub.setOnObserveStart { service.isAgentRequestActive = true }

        await service.observe()

        XCTAssertFalse(service.isMirroredTurn)
        XCTAssertTrue(service.isAgentRequestActive, "the local turn is untouched")
        XCTAssertTrue(received.isEmpty, "no transcript change is forwarded")
    }

    // Viewer gate: a device that never linked holds no viewer socket, yet a chat still opens,
    // catches up and sends as before.
    @MainActor
    func testWithoutTheLinkedFlagNoViewerStartsAndTheChatStillCatchesUpAndSends() async throws {
        let address = "0x" + String(repeating: "d3", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        await stub.setProfileVisitEvents([
            .catchUp([CatchUpItem(role: .user, text: "q"), CatchUpItem(role: .agent, text: "a")], isRunning: false)
        ])
        await stub.setObservedEvents([.mirroredUserMessage("never seen")])
        let configuration = GeneralAgentConfiguration(
            name: "Solo Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let service = ConnectOnionService(isLinked: { false }, remoteAgentFactory: { _, _, _ in stub })
        let viewModel = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Solo"),
            configuration: configuration,
            service: service,
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )

        viewModel.connectIfNeeded()
        await waitUntil { viewModel.messages.count == 2 }
        viewModel.inputText = "next"
        viewModel.sendMessage()
        await waitUntil { await stub.sentRequestSnapshot().map(\.prompt) == ["next"] }
        await waitUntil { !service.isAgentRequestActive }
        try await Task.sleep(nanoseconds: 50_000_000) // a send's end is when a viewer would start

        XCTAssertEqual(viewModel.messages.prefix(3).map { $0.content }, ["q", "a", "next"])
        let calls = await stub.callSnapshot()
        XCTAssertFalse(calls.contains("observe"), "no viewer socket without the linked flag")
    }

    @MainActor
    func testWithTheLinkedFlagTheViewerStartsWhenTheChatOpens() async throws {
        let (viewModel, _) = try await makeMirrorChat(observed: [.mirroredUserMessage("from the phone")])

        viewModel.connectIfNeeded()

        await waitUntil { viewModel.messages.map { $0.content } == ["from the phone"] }
    }

    // After a Device Link replaced the key, every existing chat belongs to the old Address, so every
    // open agent connection closes and none connects again. A chat that was not connected stays as it was.
    @MainActor
    func testAnIdentityChangeClosesEveryOpenAgentConnection() async throws {
        let address = "0x" + String(repeating: "d4", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
            httpBaseURL: nil,
            isDirect: false,
            info: nil
        )
        let client = await StubRemoteAgentClient(endpoint: endpoint)
        var clientsMade = 0
        let configuration = GeneralAgentConfiguration(
            name: "Linked Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let notifications = NotificationCenter() // only these two services hear it
        let open = ConnectOnionService(isLinked: { false }, linkNotifications: notifications, remoteAgentFactory: { _, _, _ in
            clientsMade += 1
            return client
        })
        let idle = ConnectOnionService(isLinked: { false }, linkNotifications: notifications, remoteAgentFactory: { _, _, _ in
            clientsMade += 1
            return client
        })
        open.connect(with: configuration)
        await waitUntil { open.hostedAgentStatus == "Connected" }

        ConnectOnionService.identityDidChange(in: notifications)

        await waitUntil { await client.callSnapshot().contains("disconnect") }
        XCTAssertFalse(open.isConnected)
        XCTAssertFalse(idle.isConnected)
        XCTAssertEqual(clientsMade, 1, "nothing connects again as the new Address")
    }

    // The Giving Device keeps its Address, so its open chats keep their connections and only start
    // the viewer the linked flag now allows.
    @MainActor
    func testLinkingStartsTheViewerInAnOpenChatWithoutReconnecting() async throws {
        let address = "0x" + String(repeating: "d5", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            )
        )
        var linked = false
        var gateChecks = 0
        var clientsMade = 0
        let notifications = NotificationCenter()
        let service = ConnectOnionService(
            isLinked: {
                gateChecks += 1
                return linked
            },
            linkNotifications: notifications,
            remoteAgentFactory: { _, _, _ in
                clientsMade += 1
                return stub
            }
        )
        service.connect(with: GeneralAgentConfiguration(
            name: "Giving Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        ))
        await waitUntil { gateChecks == 1 } // the open's own observe() was refused
        let observedBefore = await stub.callSnapshot().contains("observe")

        linked = true
        ConnectOnionService.didLink(in: notifications)

        await waitUntil { await stub.callSnapshot().contains("observe") }
        XCTAssertFalse(observedBefore, "no viewer before the link")
        let calls = await stub.callSnapshot()
        XCTAssertFalse(calls.contains("disconnect"), "the connection is kept")
        XCTAssertEqual(clientsMade, 1)
    }

    // A chat from a previous identity is read-only: opening it connects nothing, Send and retry do
    // nothing, and its one action starts a new chat with the same agent as the current Address.
    @MainActor
    func testAPreviousIdentityChatStaysLockedAndStartsANewChatWithItsAgent() throws {
        let configuration = GeneralAgentConfiguration(
            name: "Old Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: "0x" + String(repeating: "d6", count: 32))
        )
        let session = ChatSession(
            agentConfigId: configuration.id,
            identityAddress: "0x" + String(repeating: "cd", count: 32),
            title: "Old"
        )
        let appViewModel = AppViewModel(storage: makeIsolatedDefaults(), historyKeyStore: InMemoryPrivateKeyStore())
        appViewModel.configurations = [configuration]
        appViewModel.sessions = [session]
        let reply = ChatMessage(sessionId: session.id, role: .agent, content: "old reply")
        appViewModel.messages = [ChatMessage(sessionId: session.id, role: .user, content: "old"), reply]
        var clientsMade = 0
        let service = ConnectOnionService(isLinked: { false }, linkNotifications: NotificationCenter(), remoteAgentFactory: { _, _, _ in
            clientsMade += 1
            return ConnectOnionRemoteAgentClient(configuredTarget: "unused", conversationID: nil, initialSessionID: nil)
        })
        let viewModel = ChatViewModel(session: session, configuration: configuration, service: service, appViewModel: appViewModel)

        viewModel.connectIfNeeded()
        viewModel.inputText = "hello?"
        viewModel.sendMessage()

        XCTAssertTrue(viewModel.isFromPreviousIdentity)
        XCTAssertEqual(viewModel.messages.map(\.content), ["old", "old reply"], "readable, and nothing was sent")
        XCTAssertFalse(viewModel.canRetryAgentMessage(reply))
        XCTAssertEqual(clientsMade, 0)

        viewModel.startNewChat()

        let newChat = try XCTUnwrap(appViewModel.sessions.last)
        XCTAssertEqual(appViewModel.sessions.count, 2)
        XCTAssertEqual(newChat.agentConfigId, configuration.id)
        XCTAssertEqual(appViewModel.selection, .session(newChat.id))
        XCTAssertFalse(appViewModel.isFromPreviousIdentity(newChat))
    }
}
