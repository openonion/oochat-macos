import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionRemoteAgentTests {
    func testUsageSummaryRequiresTraceTokensAndContextAndUsesLatestResult() throws {
        XCTAssertNil(ConnectOnionRemoteAgentClient.makeUsageSummary(from: [:]))
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.makeUsageSummary(
                from: ["session": ["trace": []]]
            )
        )
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.makeUsageSummary(
                from: [
                    "session": [
                        "trace": [
                            [
                                "type": "llm_result",
                                "usage": ["input_tokens": 2, "output_tokens": 1]
                            ]
                        ]
                    ]
                ]
            )
        )

        let summary = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeUsageSummary(
                from: [
                    "session": [
                        "trace": [
                            [
                                "type": "llm_result",
                                "usage": [
                                    "input_tokens": 4,
                                    "output_tokens": 1,
                                    "cost": 0.1
                                ],
                                "context_percent": 10
                            ],
                            [
                                "type": "tool_result",
                                "usage": ["input_tokens": 999, "cost": 99]
                            ],
                            [
                                "type": "llm_result",
                                "usage": [
                                    "input_tokens": 8,
                                    "output_tokens": 2,
                                    "cost": 0.2
                                ],
                                "context_percent": 20
                            ]
                        ]
                    ]
                ]
            )
        )
        XCTAssertEqual(summary.tokenCount, 10)
        XCTAssertEqual(summary.totalCost, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(summary.contextPercent, 20)
    }

    func testInputMessagesSignDirectAndRelayPayloadsAndIncludeFiles() throws {
        let privateKeyData = Data((0..<32).map(UInt8.init))
        let identity = try ConnectOnionIdentity(rawPrivateKey: privateKeyData)
        let address = makeAddress("78")
        let direct = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: URL(string: "wss://agent.test/ws")!,
            httpBaseURL: URL(string: "https://agent.test")!,
            isDirect: true,
            info: nil
        )
        let relay = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: relayWebSocketURL,
            httpBaseURL: nil,
            isDirect: false,
            info: nil
        )
        let file = ConnectOnionInputFile(
            name: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )

        let directMessage = try ConnectOnionRemoteAgentClient.buildInputMessage(
            prompt: "Summarize",
            files: [file],
            inputID: "input-direct",
            identity: identity,
            endpoint: direct
        )
        XCTAssertNil(directMessage["to"])
        XCTAssertEqual(directMessage["from"] as? String, identity.address)
        XCTAssertEqual(
            directMessage["files"] as? [[String: String]],
            [file.protocolObject]
        )
        try assertValidSignature(
            in: directMessage,
            privateKeyData: privateKeyData
        )

        let relayMessage = try ConnectOnionRemoteAgentClient.buildInputMessage(
            prompt: "Continue",
            files: [],
            inputID: "input-relay",
            identity: identity,
            endpoint: relay
        )
        XCTAssertEqual(relayMessage["to"] as? String, address)
        XCTAssertEqual(
            (relayMessage["payload"] as? [String: Any])?["to"] as? String,
            address
        )
        XCTAssertNil(relayMessage["files"])
        try assertValidSignature(
            in: relayMessage,
            privateKeyData: privateKeyData
        )
    }

    func testAgentImageValidationRejectsMissingHostsAndUnsafeSchemes() throws {
        XCTAssertEqual(
            try ConnectOnionRemoteAgentClient.validatedAgentImageURL(
                from: ["image": "HTTPS://images.test/screenshot.png"]
            ),
            "HTTPS://images.test/screenshot.png"
        )

        for value: Any in [
            "images.test/file.png",
            "file:///tmp/file.png",
            "data:image/png;base64,AAAA",
            "https:///missing-host.png",
            42
        ] {
            XCTAssertThrowsError(
                try ConnectOnionRemoteAgentClient.validatedAgentImageURL(
                    from: ["image": value]
                )
            )
        }
        XCTAssertThrowsError(
            try ConnectOnionRemoteAgentClient.validatedAgentImageURL(from: [:])
        )
    }

    func testClientProcessesCompleteWebSocketProtocolFlow() async throws {
        let address = makeAddress("90")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let artifactData = Data([0, 1, 2, 255])
        let artifactHash = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }
            .joined()
        let artifactID = UUID().uuidString
        let artifact: [String: Any] = [
            "artifact_id": artifactID,
            "name": "result.bin",
            "mime_type": "application/octet-stream",
            "size_bytes": artifactData.count,
            "sha256": artifactHash,
            "data_base64": artifactData.base64EncodedString()
        ]
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Live Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "PING"],
            [
                "type": "ONBOARD_REQUIRED",
                "identity": "onboarding-1",
                "methods": ["invite_code"],
                "payment_amount": 4.5,
                "payment_address": "0xpayment"
            ],
            ["type": "ERROR", "message": "Invite code required"],
            ["type": "ONBOARD_SUCCESS"],
            ["type": "ignored"],
            [
                "type": "CONNECTED",
                "status": "ready",
                "session_id": "session-live",
                "server_newer": true,
                "session": ["trace": []]
            ],
            [
                "type": "intent",
                "id": "intent-1",
                "status": "understood",
                "ack": "Understood",
                "seq": 1
            ],
            [
                "type": "intent",
                "id": "intent-1",
                "status": "understood",
                "ack": "Duplicate",
                "seq": 1
            ],
            [
                "type": "ask_user",
                "id": "ask-1",
                "question": "Which option?",
                "options": ["A", "B"],
                "multi_select": true,
                "fields": [
                    ["name": "detail"],
                    ["label": "ignored"]
                ]
            ],
            [
                "type": "approval_needed",
                "id": "approval-1",
                "tool": "write_file",
                "arguments": ["path": "README.md"],
                "batch_remaining": [["tool": "edit"]]
            ],
            ["type": "mode_changed", "mode": "ulw"],
            ["type": "mode_changed", "mode": "unsupported"],
            ["type": "plan_review", "plan_content": "Implement the plan"],
            ["type": "ulw_turns_reached", "turns_used": 10, "max_turns": 20],
            ["type": "ONBOARD_REQUIRED", "methods": ["invite_code"]],
            ["type": "ERROR", "error": "Still waiting"],
            ["type": "RUNTIME_INPUT_ACK"],
            ["type": "RUNTIME_INPUT_ACK"],
            ["type": "interrupt_ack"],
            ["type": "agent_image", "image": "https://images.test/result.png"],
            ["type": "agent_artifact", "artifact": artifact],
            [
                "type": "llm_result",
                "id": "llm-1",
                "usage": ["total_tokens": 6, "cost": 0.1]
            ],
            ["type": "unhandled"],
            [
                "type": "OUTPUT",
                "result": "completed",
                "session": [
                    "generated_artifacts": [artifact],
                    "trace": [
                        [
                            "type": "llm_result",
                            "usage": [
                                "input_tokens": 8,
                                "output_tokens": 2,
                                "cost": 0.2
                            ],
                            "context_percent": 25
                        ]
                    ]
                ]
            ]
        ])
        let recorder = RemoteProtocolRecorder()
        let queuedMessageID = UUID()
        let liveMessageID = UUID()
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket }
        )

        let output = try await client.send(
            prompt: "Run the task",
            onUpdate: { update in
                await recorder.record(update)
                if update.status == "Authenticating" {
                    await recordProtocolFailure(recorder) {
                        try await client.sendRuntimeInput(
                            prompt: "Queued follow-up",
                            localMessageID: queuedMessageID
                        )
                    }
                    await recordProtocolFailure(recorder) {
                        try await client.interrupt()
                    }
                } else if update.status == "Running", update.detail == nil {
                    await recordProtocolFailure(recorder) {
                        try await client.sendRuntimeInput(
                            prompt: "Live follow-up",
                            localMessageID: liveMessageID
                        )
                    }
                }
            },
            onEvent: { event in
                await recorder.record(event)
                switch event {
                case .askUser:
                    await recordProtocolFailure(recorder) {
                        try await client.respondToAskUser(answer: "A")
                    }
                case .approvalRequired:
                    await recordProtocolFailure(recorder) {
                        try await client.respondToApproval(.approveOnce)
                    }
                case .planReviewRequired:
                    await recordProtocolFailure(recorder) {
                        try await client.respondToPlanReview(.approve)
                    }
                case .ulwCheckpointRequired:
                    await recordProtocolFailure(recorder) {
                        try await client.respondToULWCheckpoint(.continueTenTurns)
                    }
                case .onboardingRequired:
                    await recordProtocolFailure(recorder) {
                        try await client.submitInviteCode(" invite-code ")
                    }
                case .modeChanged:
                    await recordProtocolFailure(recorder) {
                        try await client.setExecutionMode(.plan)
                    }
                default:
                    break
                }
            }
        )

        XCTAssertEqual(output, "completed")
        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.failures.isEmpty)
        XCTAssertTrue(snapshot.updates.contains("Authenticating:Direct endpoint"))
        XCTAssertTrue(snapshot.updates.contains("Running:none"))
        XCTAssertTrue(snapshot.updates.contains("Stopping:Hosted agent acknowledged the interrupt"))
        XCTAssertTrue(snapshot.events.contains("ask_user"))
        XCTAssertTrue(snapshot.events.contains("approval"))
        XCTAssertTrue(snapshot.events.contains("mode:ulw"))
        XCTAssertTrue(snapshot.events.contains("plan_review"))
        XCTAssertTrue(snapshot.events.contains("ulw_checkpoint"))
        XCTAssertTrue(snapshot.events.contains("onboarding"))
        XCTAssertTrue(snapshot.events.contains("onboarding_success:Access granted"))
        XCTAssertTrue(snapshot.events.contains("runtime_ack:\(queuedMessageID.uuidString)"))
        XCTAssertTrue(snapshot.events.contains("runtime_ack:\(liveMessageID.uuidString)"))
        XCTAssertTrue(snapshot.events.contains("agent_image"))
        XCTAssertEqual(
            snapshot.events.filter { $0 == "agent_artifact:\(artifactID)" }.count,
            1
        )
        XCTAssertEqual(snapshot.events.filter { $0 == "execution_item" }.count, 2)
        XCTAssertTrue(snapshot.events.contains("usage:10"))

        let sentObjects = try socket.sentJSONObjects()
        let sentTypes = sentObjects.compactMap { $0["type"] as? String }
        XCTAssertTrue(socket.wasResumed)
        XCTAssertTrue(socket.wasCancelled)
        XCTAssertEqual(sentTypes.filter { $0 == "INPUT" }.count, 3)
        XCTAssertTrue(sentTypes.contains("CONNECT"))
        XCTAssertTrue(sentTypes.contains("PONG"))
        XCTAssertTrue(sentTypes.contains("ONBOARD_SUBMIT"))
        XCTAssertTrue(sentTypes.contains("INTERRUPT"))
        XCTAssertTrue(sentTypes.contains("ASK_USER_RESPONSE"))
        XCTAssertTrue(sentTypes.contains("mode_change"))

        let storedStateData = try XCTUnwrap(
            UserDefaults.standard.data(forKey: storageKey)
        )
        let storedState = try XCTUnwrap(
            JSONSerialization.jsonObject(with: storedStateData)
                as? [String: Any]
        )
        let encodedSession = try XCTUnwrap(
            storedState["sessionData"] as? String
        )
        let sessionData = try XCTUnwrap(
            Data(base64Encoded: encodedSession)
        )
        let storedSession = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sessionData)
                as? [String: Any]
        )
        let storedArtifacts = try XCTUnwrap(
            storedSession["generated_artifacts"] as? [[String: Any]]
        )
        XCTAssertNil(storedArtifacts.first?["data_base64"])

        // This flow requests an interrupt and then still resolves on a normal
        // OUTPUT. The terminal output must clear wasInterrupted; otherwise the
        // stale flag survives to the next turn and mutes its output.
        XCTAssertEqual(
            storedState["wasInterrupted"] as? Bool,
            false,
            "A terminal OUTPUT must clear the interrupt flag"
        )
    }

}
