import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionRemoteAgentTests {
    func testResolverResolvesDirectEndpointAndBuildsWebSocketPath() async throws {
        let address = makeAddress("ab")
        let resolver = makeResolver { request in
            let data = try makeJSONData(
                [
                    "name": "Direct Agent",
                    "address": address.uppercased().replacingOccurrences(
                        of: "0X",
                        with: "0x"
                    ),
                    "tools": ["read_file", "edit"],
                    "model": "co/gemini-2.5-pro",
                    "trust": "careful",
                    "version": "1.2.1",
                    "accepted_inputs": ["text": true, "files": false]
                ]
            )
            return (makeHTTPResponse(for: request, statusCode: 200), data)
        }

        let endpoint = try await resolver.resolve("  https://agent.test/base/  ")

        XCTAssertEqual(endpoint.agentAddress, address)
        XCTAssertEqual(endpoint.httpBaseURL?.absoluteString, "https://agent.test/base/")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "wss://agent.test/base/ws")
        XCTAssertTrue(endpoint.isDirect)
        XCTAssertEqual(endpoint.info?.name, "Direct Agent")
        XCTAssertEqual(endpoint.info?.tools ?? [], ["read_file", "edit"])
        XCTAssertEqual(endpoint.info?.model, "co/gemini-2.5-pro")
        XCTAssertEqual(endpoint.info?.trust, "careful")
        XCTAssertEqual(endpoint.info?.version, "1.2.1")
        XCTAssertEqual(endpoint.info?.acceptedInputs?.files?.isSupported, false)
        XCTAssertEqual(
            RemoteAgentURLProtocolStub.receivedURLs,
            [URL(string: "https://agent.test/base/info")!]
        )
    }

    func testResolverReportsInvalidDirectTargetsResponsesAndAgentInfo() async {
        let resolver = makeResolver { request in
            switch request.url?.host {
            case "unavailable.test":
                return (makeHTTPResponse(for: request, statusCode: 503), Data())
            case "invalid-json.test":
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    Data("not-json".utf8)
                )
            default:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(
                        ["name": "Wrong Agent", "address": "0x1234"]
                    )
                )
            }
        }

        await assertRemoteError(.invalidAgentTarget) {
            _ = try await resolver.resolve("ftp://agent.test")
        }
        await assertRemoteError(.directEndpointUnavailable) {
            _ = try await resolver.resolve("https://unavailable.test")
        }
        await assertRemoteError(.invalidAgentInfo) {
            _ = try await resolver.resolve("https://invalid-json.test")
        }
        await assertRemoteError(.invalidAgentInfo) {
            _ = try await resolver.resolve("https://wrong-address.test")
        }
    }

    func testResolverPrefersMatchingDirectEndpointDiscoveredThroughRelay() async throws {
        let address = makeAddress("cd")
        let otherAddress = makeAddress("ef")
        let resolver = makeResolver { request in
            switch request.url?.host {
            case "relay.test":
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(
                        [
                            "online": true,
                            "endpoints": [
                                "ftp://ignored.test",
                                "https://wrong.test",
                                "https://matching.test/base"
                            ]
                        ]
                    )
                )
            case "wrong.test":
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(
                        ["name": "Wrong", "address": otherAddress]
                    )
                )
            default:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(
                        ["name": "Matched", "address": address]
                    )
                )
            }
        }

        let uppercaseAddress = "0x" + address.dropFirst(2).uppercased()
        let endpoint = try await resolver.resolve(uppercaseAddress)

        XCTAssertTrue(endpoint.isDirect)
        XCTAssertEqual(endpoint.agentAddress, address)
        XCTAssertEqual(endpoint.httpBaseURL?.absoluteString, "https://matching.test/base")
        XCTAssertEqual(endpoint.webSocketURL.absoluteString, "wss://matching.test/base/ws")
        XCTAssertEqual(endpoint.info?.name, "Matched")
        XCTAssertEqual(
            RemoteAgentURLProtocolStub.receivedURLs.map(\.host),
            ["relay.test", "wrong.test", "matching.test"]
        )
    }

    func testResolverFallsBackToRelayAndReportsRelayFailures() async throws {
        let address = makeAddress("12")
        var resolver = makeResolver { request in
            if request.url?.host == "relay.test" {
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(
                        [
                            "online": true,
                            "endpoints": ["https://offline-direct.test"]
                        ]
                    )
                )
            }
            return (makeHTTPResponse(for: request, statusCode: 503), Data())
        }

        let relayEndpoint = try await resolver.resolve(address)
        XCTAssertFalse(relayEndpoint.isDirect)
        XCTAssertNil(relayEndpoint.httpBaseURL)
        XCTAssertNil(relayEndpoint.info)
        XCTAssertEqual(relayEndpoint.webSocketURL, relayWebSocketURL)

        resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["online": false, "endpoints": []])
            )
        }
        await assertRemoteError(.agentOffline) {
            _ = try await resolver.resolve(address)
        }

        resolver = makeResolver { request in
            (makeHTTPResponse(for: request, statusCode: 404), Data())
        }
        await assertRemoteError(.agentNotFound) {
            _ = try await resolver.resolve(address)
        }

        resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                Data("invalid".utf8)
            )
        }
        await assertRemoteError(.invalidRelayResponse) {
            _ = try await resolver.resolve(address)
        }
    }

    func testResolverOnlineCheckConvertsSuccessAndFailureToBoolean() async {
        let address = makeAddress("34")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Agent", "address": address])
            )
        }

        let isAgentOnline = await resolver.isOnline("https://agent.test")
        let isInvalidTargetOnline = await resolver.isOnline("not a supported target")
        XCTAssertTrue(isAgentOnline)
        XCTAssertFalse(isInvalidTargetOnline)
    }

    func testHistoryClientDecodesDurableSessions() async throws {
        RemoteAgentURLProtocolStub.install { request in
            XCTAssertEqual(request.url?.path, "/sessions")
            return (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData([
                    "sessions": [
                        [
                            "session_id": "shared-session",
                            "status": "done",
                            "prompt": "Hello",
                            "result": "Hi there",
                            "created": 1_700_000_000,
                            "session": [
                                "updated": 1_700_000_010,
                                "messages": [
                                    ["role": "user", "content": "Hello"],
                                    [
                                        "role": "assistant",
                                        "content": "Hi there",
                                        "internal": false
                                    ],
                                    ["role": "tool", "name": "glob"]
                                ]
                            ]
                        ]
                    ]
                ])
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteAgentURLProtocolStub.self]
        let client = ConnectOnionHistoryClient(
            urlSession: URLSession(configuration: configuration)
        )

        let sessions = try await client.sessions(
            from: URL(string: "http://127.0.0.1:8000")!
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "shared-session")
        XCTAssertEqual(sessions[0].conversation?.messages.count, 3)
        XCTAssertEqual(sessions[0].conversation?.messages[1].text, "Hi there")
    }

    func testClientSeedsStableRemoteSessionID() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        _ = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            initialSessionID: "web-and-native-session"
        )

        XCTAssertEqual(
            connectOnionPersistedRemoteSessionID(for: conversationID),
            "web-and-native-session"
        )
    }

    func testClientProbeCachesResolvedEndpoint() async throws {
        let address = makeAddress("56")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Cached", "address": address])
            )
        }
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver
        )

        let first = try await client.probe()
        let second = try await client.probe()

        XCTAssertEqual(first.agentAddress, second.agentAddress)
        XCTAssertEqual(first.webSocketURL, second.webSocketURL)
        XCTAssertEqual(RemoteAgentURLProtocolStub.receivedURLs.count, 1)
    }

    func testClientPersistsDesiredExecutionModeWithoutSocket() async throws {
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID
        )
        let initiallyHasPendingExecution = await client.hasPendingExecution()
        XCTAssertFalse(initiallyHasPendingExecution)

        try await client.setExecutionMode(.accept)
        let snapshot = await client.executionModeSnapshot()
        XCTAssertEqual(snapshot.desired, .accept)
        XCTAssertEqual(snapshot.confirmed, .safe)

        let reloaded = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID
        )
        let reloadedSnapshot = await reloaded.executionModeSnapshot()
        XCTAssertEqual(reloadedSnapshot.desired, .accept)
        XCTAssertEqual(reloadedSnapshot.confirmed, .safe)

        try await reloaded.setExecutionMode(.plan)
        let updatedSnapshot = await reloaded.executionModeSnapshot()
        XCTAssertEqual(updatedSnapshot.desired, .plan)
    }

    func testClientRejectsInteractionsAndRuntimeInputWithoutActiveSocket() async {
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil
        )

        await assertRemoteError(.connectionClosed) {
            try await client.respondToAskUser(answer: "Answer")
        }
        await assertRemoteError(.connectionClosed) {
            try await client.respondToApproval(.approveOnce)
        }
        await assertRemoteError(.connectionClosed) {
            try await client.respondToPlanReview(.approve)
        }
        await assertRemoteError(.connectionClosed) {
            try await client.respondToULWCheckpoint(.returnToSafe)
        }
        await assertRemoteError(.connectionClosed) {
            try await client.submitInviteCode("  invite-code  ")
        }
        await assertRemoteError(.connectionClosed) {
            try await client.submitInviteCode("   ")
        }
        await assertRemoteError(.requestInProgress) {
            try await client.sendRuntimeInput(
                prompt: "Follow up",
                localMessageID: UUID()
            )
        }

        await client.disconnect()
        let hasPendingExecution = await client.hasPendingExecution()
        XCTAssertFalse(hasPendingExecution)
    }

    func testClientSendRejectsInvalidTargetAfterCreatingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "invalid target",
            conversationID: nil,
            identityStore: ConnectOnionIdentityStore(identityFileURL: identityURL)
        )

        await assertRemoteError(.invalidAgentTarget) {
            _ = try await client.send(
                prompt: "Hello",
                onUpdate: { _ in },
                onEvent: { _ in }
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: identityURL.path))
    }

    func testExecutionItemBuildsIntentAndThinkingVariants() throws {
        guard case .intent(let intent) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "intent",
                    "id": "intent-1",
                    "status": "understood",
                    "ack": "I understand",
                    "is_build": true
                ]
            )
        ) else {
            return XCTFail("Expected intent item")
        }
        XCTAssertEqual(intent.id, "intent-1")
        XCTAssertEqual(intent.status, .understood)
        XCTAssertEqual(intent.ack, "I understand")
        XCTAssertEqual(intent.isBuild, true)

        guard case .thinking(let call) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "llm_call",
                    "id": "llm-1",
                    "model": "model-a",
                    "duration_ms": 42,
                    "context_percent": Float(25.5),
                    "usage": [
                        "prompt_tokens": 3,
                        "completion_tokens": 2,
                        "cost": 0.25
                    ]
                ]
            )
        ) else {
            return XCTFail("Expected thinking item")
        }
        XCTAssertEqual(call.status, .running)
        XCTAssertEqual(call.durationMS, 42)
        XCTAssertEqual(call.contextPercent, 25.5)
        XCTAssertEqual(call.usage?.tokenCount, 5)
        XCTAssertEqual(call.usage?.totalCost ?? 0, 0.25, accuracy: 0.000_001)

        guard case .thinking(let result) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "llm_result",
                    "id": "llm-1",
                    "status": "error",
                    "usage": ["total_tokens": 11, "cost": 0.4]
                ]
            )
        ) else {
            return XCTFail("Expected result item")
        }
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(result.usage?.tokenCount, 11)

        guard case .thinking(let reflection) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "thinking",
                    "id": "reflection-1",
                    "status": "done",
                    "kind": "reflection",
                    "content": "Check the result"
                ]
            )
        ) else {
            return XCTFail("Expected reflection item")
        }
        XCTAssertEqual(reflection.kind, "reflection")
        XCTAssertEqual(reflection.content, "Check the result")

        XCTAssertNil(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: ["type": "intent", "id": "missing-status"]
            )
        )
    }

    func testExecutionItemBuildsToolAndEvalVariantsAndRejectsMalformedEvents() throws {
        guard case .toolCall(let call) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "tool_call",
                    "tool_id": "tool-1",
                    "name": "write_file",
                    "args": [
                        "path": "README.md",
                        "force": true,
                        "count": 2,
                        "nested": ["enabled": false],
                        "values": [1, "two", NSNull()]
                    ] as [String: Any],
                    "timing_ms": NSNumber(value: 12.5)
                ]
            )
        ) else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(call.id, "tool-1")
        XCTAssertEqual(call.name, "write_file")
        XCTAssertEqual(call.status, .running)
        XCTAssertEqual(call.args["path"], .string("README.md"))
        XCTAssertEqual(call.args["force"], .bool(true))
        XCTAssertEqual(call.args["count"], .number(2))
        XCTAssertEqual(call.args["nested"], .object(["enabled": .bool(false)]))
        XCTAssertEqual(
            call.args["values"],
            .array([.number(1), .string("two"), .null])
        )
        XCTAssertEqual(call.timingMS, 12.5)

        guard case .toolCall(let result) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "tool_result",
                    "id": "tool-1",
                    "status": "error",
                    "result": ["ok": false]
                ]
            )
        ) else {
            return XCTFail("Expected tool result")
        }
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.result?.contains("\"ok\":false") == true)

        guard case .eval(let evaluation) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: [
                    "type": "eval",
                    "id": "eval-1",
                    "status": "done",
                    "passed": true,
                    "summary": "Passed",
                    "expected": "Success",
                    "eval_path": "tests/eval.json"
                ]
            )
        ) else {
            return XCTFail("Expected eval item")
        }
        XCTAssertEqual(evaluation.status, .done)
        XCTAssertEqual(evaluation.passed, true)
        XCTAssertEqual(evaluation.evalPath, "tests/eval.json")

        XCTAssertNil(ConnectOnionRemoteAgentClient.makeExecutionItem(from: [:]))
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: ["type": "unknown", "id": "unknown-1"]
            )
        )
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.makeExecutionItem(
                from: ["type": "eval", "id": "eval-2", "status": "invalid"]
            )
        )
    }

}
