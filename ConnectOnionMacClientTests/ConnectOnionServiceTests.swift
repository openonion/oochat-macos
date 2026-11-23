import Combine
import ConnectOnionKit
import CryptoKit
import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionServiceTests: XCTestCase {
    func testInitialStateIsDisconnected() async {
        await MainActor.run {
            let service = ConnectOnionService()

            XCTAssertFalse(service.isConnected)
            XCTAssertNil(service.connectionError)
            XCTAssertEqual(service.hostedAgentStatus, "Not Connected")
            XCTAssertFalse(service.isHostedAgentStatusLive)
            XCTAssertFalse(service.hostedFilesystemEnabled)
            XCTAssertNil(service.hostedWorkspacePath)
        }
    }

    func testConnectRejectsRetiredDirectAPIConfiguration() async {
        await MainActor.run {
            let service = ConnectOnionService()
            let configuration = GeneralAgentConfiguration(
                name: "Legacy API Agent",
                connectionType: .legacyByApi,
                addressConfiguration: nil
            )

            service.connect(with: configuration)

            XCTAssertFalse(service.isConnected)
            XCTAssertEqual(
                service.connectionError,
                "Direct API configurations are no longer supported. Connect to a hosted agent instead."
            )
        }
    }

    func testConnectRejectsMissingAddressConfiguration() async {
        await MainActor.run {
            let service = ConnectOnionService()
            let configuration = GeneralAgentConfiguration(
                name: "Test Agent",
                connectionType: .byAddress,
                addressConfiguration: nil
            )

            service.connect(with: configuration)

            XCTAssertFalse(service.isConnected)
            XCTAssertEqual(service.connectionError, "Missing agent target configuration")
        }
    }

    func testHostedAddressRejectsUnsupportedScheme() async {
        await MainActor.run {
            let service = ConnectOnionService()
            let configuration = AgentAddressConfiguration(
                agentAddress: "ftp://127.0.0.1:8000"
            )

            service.connectWithAddressConfig(configuration, agentName: "Test Agent")

            XCTAssertFalse(service.isConnected)
            XCTAssertEqual(
                service.connectionError,
                "Enter a valid 0x address or HTTP(S) Direct URL"
            )
        }
    }

    @MainActor
    func testHostedConnectionDelegatesProtocolLifecycleAndFailures() async {
        let address = "0x" + String(repeating: "ab", count: 32)
        let fileCapabilities = ConnectOnionAgentInfo.FileInputCapabilities(
            isSupported: true,
            maxFileSizeMB: 12,
            maxFilesPerRequest: 3
        )
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: ConnectOnionAgentInfo(
                name: "Hosted Agent",
                address: address,
                tools: ["read_file", "write", "other"],
                model: "co/test",
                trust: nil,
                version: "1",
                acceptedInputs: ConnectOnionAgentInfo.AcceptedInputs(
                    text: true,
                    images: false,
                    files: fileCapabilities
                )
            )
        )
        let stub = await StubRemoteAgentClient(
            endpoint: endpoint,
            pendingExecution: true
        )
        let conversationID = UUID()
        let remoteSessionID = "shared-session"
        var createdTarget: String?
        var createdConversationID: UUID?
        var createdRemoteSessionID: String?
        let service = ConnectOnionService(
            conversationID: conversationID,
            initialRemoteSessionID: remoteSessionID,
            remoteAgentFactory: {
                createdTarget = $0
                createdConversationID = $1
                createdRemoteSessionID = $2
                return stub
            }
        )
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: "  \(address)  "
            )
        )
        var eventLabels: [String] = []
        let cancellable = service.incomingEvents.sink {
            eventLabels.append(Self.eventLabel($0))
        }

        service.connect(with: configuration)
        await waitUntil {
            service.confirmedExecutionMode == .plan
                && !service.isAgentRequestActive
        }

        XCTAssertEqual(createdTarget, address)
        XCTAssertEqual(createdConversationID, conversationID)
        XCTAssertEqual(createdRemoteSessionID, remoteSessionID)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.hostedAgentStatus, "Recovered")
        XCTAssertEqual(service.hostedAgentStatusDetail, "Stub recovery")
        XCTAssertTrue(service.isHostedAgentStatusLive)
        XCTAssertTrue(service.hostedFilesystemEnabled)
        XCTAssertEqual(service.hostedFileInputCapabilities, fileCapabilities)
        XCTAssertTrue(service.hostedExecutionModesEnabled)

        await service.sendMessage(
            "Primary request",
            localMessageID: UUID(),
            using: configuration
        )
        XCTAssertEqual(service.hostedAgentStatus, "Running")
        XCTAssertEqual(service.desiredExecutionMode, .accept)
        XCTAssertTrue(eventLabels.contains("output:stub response"))
        XCTAssertTrue(eventLabels.contains("mode:ulw"))

        service.isAgentRequestActive = true
        await service.sendMessage(
            "Runtime request",
            localMessageID: UUID(),
            using: configuration
        )
        let interruptAccepted = await service.interruptCurrentRequest()
        XCTAssertTrue(interruptAccepted)
        service.isAgentRequestActive = false
        await service.respondToAskUser("answer")
        await service.respondToApproval(.approveSession)
        await service.respondToPlanReview(.requestChanges("Revise"))
        await service.respondToULWCheckpoint(.continueTurns)
        await service.submitInviteCode("invite")
        await service.setExecutionMode(.safe)

        await stub.setPendingExecution(true)
        await service.retryRecovery()
        XCTAssertEqual(service.confirmedExecutionMode, .plan)

        await stub.setFailures([
            .send,
            .runtimeInput,
            .interrupt,
            .askUser,
            .approval,
            .mode,
            .planReview,
            .ulwCheckpoint,
            .inviteCode
        ])
        await service.sendMessage(
            "Fail primary request",
            localMessageID: UUID(),
            using: configuration
        )
        XCTAssertEqual(service.hostedAgentStatus, "Connection error")
        service.isAgentRequestActive = true
        await service.sendMessage(
            "Fail runtime request",
            localMessageID: UUID(),
            using: configuration
        )
        let failedInterruptAccepted = await service.interruptCurrentRequest()
        XCTAssertFalse(failedInterruptAccepted)
        service.isAgentRequestActive = false
        await service.respondToAskUser("answer")
        await service.respondToApproval(.approveOnce)
        await service.respondToPlanReview(.approve)
        await service.respondToULWCheckpoint(.returnToSafe)
        await service.submitInviteCode("invite")
        let previousMode = service.desiredExecutionMode
        await service.setExecutionMode(.accept)
        XCTAssertEqual(service.desiredExecutionMode, previousMode)
        XCTAssertTrue(
            eventLabels.filter { $0 == "error:Stub remote operation failed" }.count >= 8
        )

        service.disconnect()
        await waitUntil {
            await stub.callSnapshot().contains("disconnect")
        }
        let calls = await stub.callSnapshot()
        XCTAssertTrue(calls.contains("probe"))
        XCTAssertTrue(calls.contains("recoverIfNeeded"))
        XCTAssertTrue(calls.contains("send:Primary request:0"))
        XCTAssertTrue(calls.contains("runtimeInput:Runtime request:0"))
        XCTAssertTrue(calls.contains("interrupt"))
        XCTAssertTrue(calls.contains("askUser:answer"))
        XCTAssertTrue(calls.contains("inviteCode:invite"))
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testDisconnectingTellsTheWorkRoomStoreItsConnectionIsGone() async {
        let address = "0x" + String(repeating: "ad", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: nil
        )
        let stub = await StubRemoteAgentClient(endpoint: endpoint)
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        var dropped = false
        let cancellable = service.incomingEvents.sink {
            if case .workRoomConnectionDropped = $0 { dropped = true }
        }
        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        let generation = service.connectionGeneration

        service.disconnect()

        XCTAssertTrue(dropped)
        XCTAssertNotEqual(service.connectionGeneration, generation)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testAcceptAutoApprovesStaleRequestsWithoutPublishingPrompt() async {
        let address = "0x" + String(repeating: "ac", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: nil
        )
        let stub = await StubRemoteAgentClient(
            endpoint: endpoint,
            emitsApprovalOnSend: true
        )
        let service = ConnectOnionService(
            remoteAgentFactory: { _, _, _ in stub }
        )
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(
                agentAddress: address
            )
        )
        var receivedApprovalPrompt = false
        let cancellable = service.incomingEvents.sink {
            if case .approvalRequired = $0 {
                receivedApprovalPrompt = true
            }
        }

        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        await service.setExecutionMode(.accept)
        await service.sendMessage(
            "Run without prompting",
            localMessageID: UUID(),
            using: configuration
        )
        await waitUntil {
            await stub.callSnapshot().contains("approval:approveOnce")
        }

        XCTAssertFalse(receivedApprovalPrompt)
        XCTAssertEqual(service.desiredExecutionMode, .accept)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testOwnedProviderApprovalIsNotAutoAnsweredButGenericOneStillIs() async {
        let address = "0x" + String(repeating: "6a", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: nil
        )
        func approval(_ id: String) -> ConnectOnionTransportEvent {
            .approvalRequired(
                ConnectOnionApprovalRequest(id: id, tool: "bash", arguments: .object([:]), description: nil, batchRemaining: [])
            )
        }
        func frame(_ id: String, provider: String?) -> ConnectOnionTransportEvent {
            .workRoomFrame(.event(type: "approval_needed", id: id, body: provider.map { ["provider": .string($0)] } ?? [:]))
        }
        let stub = await StubRemoteAgentClient(
            endpoint: endpoint,
            eventsOnSend: [frame("owned", provider: "codex"), approval("owned"), frame("generic", provider: nil), approval("generic")]
        )
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        service.ownsProviderApproval = { $0["provider"] != nil }
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        await service.sendMessage("Go", localMessageID: UUID(), using: configuration)
        // The stub switches to accept mode, which answers a hosted approval on its own.
        await waitUntil { await stub.callSnapshot().contains("approval:approveOnce") }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let answers = await stub.callSnapshot().filter { $0.hasPrefix("approval:") }
        XCTAssertEqual(answers, ["approval:approveOnce"])
    }

    // The invocation frame that makes a Provider approval known reaches the store before the approval is checked,
    // so the outer approval prompt never appears for it, even in a burst.
    @MainActor
    func testWorkRoomFramesReachTheStoreBeforeTheNextApprovalIsChecked() async throws {
        let address = "0x" + String(repeating: "6b", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: nil
        )
        func frame(_ json: String) throws -> ConnectOnionTransportEvent {
            .workRoomFrame(OIPServerFrame.decode(try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))))
        }
        let invocation = try frame("""
            {"type":"provider_invocation","invocationId":"codex:call-7","parentToolCallId":"call-7","provider":"codex",
             "status":"awaiting_approval","stateRevision":2,"workroomId":"codex:call-7"}
            """)
        let approval = try frame("""
            {"type":"approval_needed","id":"approval-1","tool":"codex","arguments":{},"provider":"codex",
             "invocationId":"codex:call-7","parentToolCallId":"call-7","providerApproval":{"action":"Inspect the workspace",
             "scope":"This Work Room only","reason":"Check the requested workspace result before continuing",
             "scopeClassification":"workroom","allowOnce":true,"allowSession":false,"files":[]}}
            """)
        let prompt = ConnectOnionTransportEvent.approvalRequired(
            ConnectOnionApprovalRequest(id: "approval-1", tool: "codex", arguments: .object([:]), description: nil, batchRemaining: [])
        )
        let stub = await StubRemoteAgentClient(endpoint: endpoint, eventsOnSend: [invocation, approval, prompt])
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        let store = WorkRoomStore()
        service.ownsProviderApproval = { store.ownsApproval($0) }
        service.onWorkRoomEvent = { if case .workRoomFrame(let frame) = $0 { store.receive(frame) } }
        var receivedApprovalPrompt = false
        let cancellable = service.incomingEvents.sink {
            if case .approvalRequired = $0 { receivedApprovalPrompt = true }
        }
        let configuration = GeneralAgentConfiguration(
            name: "Hosted Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        await service.sendMessage("Go", localMessageID: UUID(), using: configuration)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(receivedApprovalPrompt)
        XCTAssertNotNil(store.workRoom(id: "codex:call-7")?.approval)
        withExtendedLifetime(cancellable) {}
    }

    // 16.2: CONNECTED confirms only the host's side, so a requested mode stays pending.
    @MainActor
    func testSessionModesKeepARequestPendingAndTurnsLeftFollowsAccept() async {
        let address = "0x" + String(repeating: "16", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: URL(string: "wss://agent.test/ws")!,
                httpBaseURL: URL(string: "https://agent.test")!,
                isDirect: true,
                info: nil
            ),
            eventsOnSend: [
                .modeChanged(.accept, turnsLeft: 4),
                .sessionModes(available: [.safe, .plan, .accept], current: .safe, turnsLeft: nil)
            ]
        )
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        let configuration = GeneralAgentConfiguration(
            name: "Mode Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        var turnsSeen: [Int?] = []
        let cancellable = service.$acceptTurnsLeft.sink { turnsSeen.append($0) }

        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        await service.sendMessage("Go", localMessageID: UUID(), using: configuration)
        await waitUntil { service.availableExecutionModes.contains(.accept) }

        XCTAssertTrue(turnsSeen.contains(4), "turns_left shows while in accept")
        XCTAssertEqual(service.desiredExecutionMode, .accept, "CONNECTED does not overwrite the request")
        XCTAssertEqual(service.confirmedExecutionMode, .safe)
        XCTAssertNil(service.acceptTurnsLeft, "no turns left outside accept")
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testHostedProbeFailurePublishesOfflineStatus() async {
        let address = "0x" + String(repeating: "cd", count: 32)
        let stub = await StubRemoteAgentClient(
            endpoint: ConnectOnionResolvedEndpoint(
                agentAddress: address,
                webSocketURL: URL(string: "wss://agent.test/ws")!,
                httpBaseURL: nil,
                isDirect: false,
                info: nil
            ),
            failures: [.probe]
        )
        let service = ConnectOnionService(
            remoteAgentFactory: { _, _, _ in stub }
        )

        service.connectWithAddressConfig(
            AgentAddressConfiguration(agentAddress: address),
            agentName: "Offline Agent"
        )
        await waitUntil { service.hostedAgentStatus == "Offline" }

        XCTAssertTrue(service.isConnected)
        XCTAssertFalse(service.isHostedAgentStatusLive)
        XCTAssertEqual(
            service.hostedAgentStatusDetail,
            "Stub remote operation failed"
        )
    }

    func testValidatedHTTPURLTrimsWhitespace() async {
        await MainActor.run {
            let url = ConnectOnionService.validatedHTTPURL(
                from: "  https://example.com/api  "
            )

            XCTAssertEqual(url?.absoluteString, "https://example.com/api")
        }
    }

    func testValidatedHTTPURLRequiresHostAndHTTPScheme() async {
        await MainActor.run {
            XCTAssertNil(ConnectOnionService.validatedHTTPURL(from: "example.com"))
            XCTAssertNil(ConnectOnionService.validatedHTTPURL(from: "file:///tmp/test"))
            XCTAssertNil(ConnectOnionService.validatedHTTPURL(from: ""))
        }
    }

    func testUsageSummaryUsesLatestTokensAndAccumulatesSessionCost() throws {
        let payload: [String: Any] = [
            "session": [
                "trace": [
                    [
                        "type": "llm_result",
                        "usage": [
                            "input_tokens": 200_000,
                            "output_tokens": 500,
                            "cost": 0.12
                        ],
                        "context_percent": 20.0
                    ],
                    [
                        "type": "tool_result",
                        "usage": [
                            "input_tokens": 999_999,
                            "output_tokens": 999_999,
                            "cost": 99.0
                        ]
                    ],
                    [
                        "type": "llm_result",
                        "usage": [
                            "input_tokens": 449_500,
                            "output_tokens": 1_000,
                            "cost": 0.19
                        ],
                        "context_percent": 35.0
                    ]
                ]
            ]
        ]

        let usage = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeUsageSummary(from: payload)
        )

        XCTAssertEqual(usage.tokenCount, 450_500)
        XCTAssertEqual(usage.totalCost, 0.31, accuracy: 0.000_001)
        XCTAssertEqual(usage.contextPercent, 35)
    }

    func testConnectOnionAddressNormalizesHexCase() {
        let uppercaseAddress = "0x" + String(repeating: "AB", count: 32)

        XCTAssertEqual(
            ConnectOnionAddress.normalized(uppercaseAddress),
            "0x" + String(repeating: "ab", count: 32)
        )
    }

    func testConnectOnionAddressRejectsWrongLengthAndCharacters() {
        XCTAssertNil(ConnectOnionAddress.normalized("0x1234"))
        XCTAssertNil(
            ConnectOnionAddress.normalized(
                "0x" + String(repeating: "z", count: 64)
            )
        )
    }

    func testAgentTargetNormalizesAddressesAndDirectURLs() {
        let uppercaseAddress = "0x" + String(repeating: "AB", count: 32)
        XCTAssertEqual(
            ConnectOnionAgentTarget.normalized(uppercaseAddress),
            "0x" + String(repeating: "ab", count: 32)
        )
        XCTAssertEqual(
            ConnectOnionAgentTarget.normalized(
                "  HTTPS://AGENT.EXAMPLE:8443/workspace?q=1  "
            ),
            "https://agent.example:8443/workspace?q=1"
        )
        XCTAssertEqual(
            ConnectOnionAgentTarget.normalized("HTTP://LOCALHOST:8000/"),
            "http://localhost:8000"
        )
        XCTAssertNil(ConnectOnionAgentTarget.normalized("ws://agent.example"))
        XCTAssertNil(ConnectOnionAgentTarget.normalized("not-an-agent"))
    }

}
