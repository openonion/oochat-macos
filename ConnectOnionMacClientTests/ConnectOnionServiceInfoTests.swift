import Combine
import CryptoKit
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionServiceTests {
    func testRelayInfoAllowsCurrentResponseWithoutOnlineField() throws {
        let data = Data(
            #"{"endpoints":["http://localhost:8000","ws://localhost:8000/ws"]}"#.utf8
        )

        let info = try JSONDecoder().decode(
            ConnectOnionRelayAgentInfo.self,
            from: data
        )

        XCTAssertNil(info.online)
        XCTAssertEqual(info.endpoints.first, "http://localhost:8000")
        XCTAssertTrue(info.isReachable)
    }

    func testRelayInfoTreatsStoredProfileWithoutLiveRouteAsOffline() throws {
        let data = Data(
            """
            {
              "endpoints": [],
              "relay": null,
              "last_seen": "2026-07-14T02:02:41.372534+00:00",
              "profile": {
                "alias": "oo",
                "tools": ["edit", "glob", "grep"]
              }
            }
            """.utf8
        )

        let info = try JSONDecoder().decode(
            ConnectOnionRelayAgentInfo.self,
            from: data
        )

        XCTAssertNil(info.online)
        XCTAssertTrue(info.endpoints.isEmpty)
        XCTAssertNil(info.relay)
        XCTAssertEqual(info.lastSeen, "2026-07-14T02:02:41.372534+00:00")
        XCTAssertFalse(info.isReachable)
    }

    func testRelayInfoTreatsActiveRelayRegistrationAsOnline() throws {
        let data = Data(
            #"{"endpoints":[],"relay":{"connection_id":"active"}}"#.utf8
        )

        let info = try JSONDecoder().decode(
            ConnectOnionRelayAgentInfo.self,
            from: data
        )

        XCTAssertTrue(info.isReachable)
    }

    func testAgentInfoDecodesFileInputLimits() throws {
        let data = Data(
            """
            {
              "name": "Document Agent",
              "address": "0x\(String(repeating: "ab", count: 32))",
              "accepted_inputs": {
                "text": true,
                "images": true,
                "files": {
                  "max_file_size_mb": 25,
                  "max_files_per_request": 4
                }
              }
            }
            """.utf8
        )

        let info = try JSONDecoder().decode(ConnectOnionAgentInfo.self, from: data)

        XCTAssertEqual(info.acceptedInputs?.text, true)
        XCTAssertEqual(info.acceptedInputs?.images, true)
        XCTAssertEqual(info.acceptedInputs?.files?.isSupported, true)
        XCTAssertEqual(info.acceptedInputs?.files?.maxFileSizeMB, 25)
        XCTAssertEqual(info.acceptedInputs?.files?.maxFilesPerRequest, 4)
    }

    func testAgentInfoDecodesExplicitlyDisabledFileInput() throws {
        let data = Data(
            """
            {
              "name": "Text Agent",
              "address": "0x\(String(repeating: "cd", count: 32))",
              "accepted_inputs": {"text": true, "files": false}
            }
            """.utf8
        )

        let info = try JSONDecoder().decode(ConnectOnionAgentInfo.self, from: data)

        XCTAssertEqual(info.acceptedInputs?.files?.isSupported, false)
    }

    func testInputFileBuildsConnectOnionDataURL() {
        let file = ConnectOnionInputFile(
            name: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )

        XCTAssertEqual(file.byteCount, 5)
        XCTAssertEqual(
            file.protocolObject,
            [
                "name": "notes.txt",
                "data": "data:text/plain;base64,aGVsbG8="
            ]
        )
    }

    func testHostedInputMessageIncludesFilesAtProtocolTopLevel() throws {
        let identity = try ConnectOnionIdentity(
            rawPrivateKey: Data((0..<32).map(UInt8.init))
        )
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: "0x" + String(repeating: "ab", count: 32),
            webSocketURL: URL(string: "wss://agent.example/ws")!,
            httpBaseURL: URL(string: "https://agent.example")!,
            isDirect: true,
            info: nil
        )
        let file = ConnectOnionInputFile(
            name: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )

        let message = try ConnectOnionRemoteAgentClient.buildInputMessage(
            prompt: "Summarize this file",
            files: [file],
            inputID: "input-1",
            identity: identity,
            endpoint: endpoint
        )

        XCTAssertEqual(message["type"] as? String, "INPUT")
        XCTAssertEqual(message["prompt"] as? String, "Summarize this file")
        let files = try XCTUnwrap(message["files"] as? [[String: String]])
        XCTAssertEqual(files, [file.protocolObject])
    }

    func testApprovalDecisionPayloadsMatchHostedProtocol() {
        assertApprovalMessage(
            ConnectOnionApprovalDecision.approveOnce.message,
            approved: true,
            scope: "once"
        )
        assertApprovalMessage(
            ConnectOnionApprovalDecision.approveSession.message,
            approved: true,
            scope: "session"
        )

        let soft = ConnectOnionApprovalDecision.rejectSoft(feedback: "Use another file").message
        XCTAssertEqual(soft["approved"] as? Bool, false)
        XCTAssertEqual(soft["mode"] as? String, "reject_soft")
        XCTAssertEqual(soft["feedback"] as? String, "Use another file")

        let hard = ConnectOnionApprovalDecision.rejectHard(feedback: "Stop").message
        XCTAssertEqual(hard["approved"] as? Bool, false)
        XCTAssertEqual(hard["mode"] as? String, "reject_hard")
        XCTAssertEqual(hard["feedback"] as? String, "Stop")
    }

    func testExecutionModePayloadsMatchHostedProtocol() {
        let safe = ConnectOnionRemoteAgentClient.buildModeChangeMessage(.safe)
        XCTAssertEqual(safe["type"] as? String, "mode_change")
        XCTAssertEqual(safe["mode"] as? String, "safe")
        XCTAssertNil(safe["turns"])

        let plan = ConnectOnionRemoteAgentClient.buildModeChangeMessage(.plan)
        XCTAssertEqual(plan["mode"] as? String, "plan")

        let accept = ConnectOnionRemoteAgentClient.buildModeChangeMessage(.accept)
        XCTAssertEqual(accept["mode"] as? String, "ulw")
        XCTAssertEqual(accept["turns"] as? Int, 10)
        XCTAssertEqual(AgentExecutionMode.accept.displayName, "accept")
    }

    func testExecutionRunShowsModelAndSynthesisForDirectAnswers() {
        var run = ExecutionRun(sessionId: UUID())
        run.items = [
            .thinking(
                ThinkingExecutionItem(
                    id: "llm-1",
                    status: .done,
                    model: "gemini-2.5-pro"
                )
            )
        ]
        XCTAssertTrue(run.hasUserVisibleTrace)
        XCTAssertTrue(run.isDirectAnswerTrace)

        run.items.append(
            .thinking(
                ThinkingExecutionItem(
                    id: "plan-1",
                    status: .done,
                    kind: "plan",
                    content: "Inspect and verify."
                )
            )
        )
        XCTAssertTrue(run.hasUserVisibleTrace)
        XCTAssertFalse(run.isDirectAnswerTrace)
    }

    func testPlanAndULWInteractionPayloadsMatchOfficialProtocol() {
        let approval = ConnectOnionPlanReviewDecision.approve.message
        XCTAssertEqual(approval["type"] as? String, "plan_review")
        XCTAssertTrue((approval["message"] as? String)?.contains("approved") == true)

        let revision = ConnectOnionPlanReviewDecision
            .requestChanges("Add tests")
            .message
        XCTAssertTrue((revision["message"] as? String)?.contains("Add tests") == true)

        let continueMessage = ConnectOnionULWCheckpointDecision.continueTenTurns.message
        XCTAssertEqual(continueMessage["action"] as? String, "continue")
        XCTAssertEqual(continueMessage["turns"] as? Int, 10)

        let safeMessage = ConnectOnionULWCheckpointDecision.returnToSafe.message
        XCTAssertEqual(safeMessage["action"] as? String, "switch_mode")
        XCTAssertEqual(safeMessage["mode"] as? String, "safe")
    }

    func testJSONValueRoundTripsNestedProtocolArguments() throws {
        let value = ConnectOnionJSONValue(
            any: [
                "path": "README.md",
                "overwrite": true,
                "changes": [1, 2, 3]
            ] as [String: Any]
        )

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ConnectOnionJSONValue.self, from: encoded)

        XCTAssertEqual(decoded, value)
        XCTAssertTrue(value.displayText.contains("README.md"))
        XCTAssertTrue(value.displayText.contains("overwrite"))
    }

    func testResolvedEndpointDistinguishesDirectPollingFromRelayOnly() {
        let directBaseURL = URL(string: "https://agent.example")!
        let direct = ConnectOnionResolvedEndpoint(
            agentAddress: "0x" + String(repeating: "ab", count: 32),
            webSocketURL: URL(string: "wss://agent.example/ws")!,
            httpBaseURL: directBaseURL,
            isDirect: true,
            info: nil
        )
        let relay = ConnectOnionResolvedEndpoint(
            agentAddress: direct.agentAddress,
            webSocketURL: URL(string: "wss://oo.openonion.ai/ws/input")!,
            httpBaseURL: nil,
            isDirect: false,
            info: nil
        )

        XCTAssertEqual(direct.httpBaseURL, directBaseURL)
        XCTAssertNil(relay.httpBaseURL)
    }

    func testQueuedMessageStatusRemainsCodable() throws {
        let data = try JSONEncoder().encode(MessageStatus.queued)
        let decoded = try JSONDecoder().decode(MessageStatus.self, from: data)

        XCTAssertEqual(decoded, .queued)
    }

    func testAgentImageEventAcceptsOnlyHTTPURLs() throws {
        XCTAssertEqual(
            try ConnectOnionRemoteAgentClient.validatedAgentImageURL(
                from: [
                    "type": "agent_image",
                    "image": "https://oo.openonion.ai/img/screenshot.png"
                ]
            ),
            "https://oo.openonion.ai/img/screenshot.png"
        )
        XCTAssertEqual(
            try ConnectOnionRemoteAgentClient.validatedAgentImageURL(
                from: [
                    "type": "agent_image",
                    "image": "http://localhost:8000/image.png"
                ]
            ),
            "http://localhost:8000/image.png"
        )

        for event: [String: Any] in [
            ["type": "agent_image"],
            ["type": "agent_image", "image": 42],
            ["type": "agent_image", "image": "data:image/png;base64,AAAA"],
            ["type": "agent_image", "image": "file:///tmp/image.png"]
        ] {
            XCTAssertThrowsError(
                try ConnectOnionRemoteAgentClient.validatedAgentImageURL(
                    from: event
                )
            )
        }
    }

    func testChatMessageImageURLIsBackwardCompatibleAndCodable() throws {
        let sessionID = UUID()
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "sessionId": "\(sessionID.uuidString)",
          "role": "agent",
          "content": "Legacy",
          "timestamp": 0,
          "status": "sent"
        }
        """
        let legacy = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacy.imageURL)

        let message = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "",
            imageURL: "https://oo.openonion.ai/img/screenshot.png"
        )
        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded, message)
    }

    func testAgentAvatarColorsAreBackwardCompatibleAndCodable() throws {
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy Agent",
          "connectionType": "byAddress",
          "addressConfiguration": {
            "agentAddress": "0x\(String(repeating: "ab", count: 32))"
          }
        }
        """
        let legacy = try JSONDecoder().decode(
            GeneralAgentConfiguration.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacy.avatarTextColorHex)
        XCTAssertNil(legacy.avatarBackgroundColorHex)

        var customized = legacy
        customized.avatarTextColorHex = "#112233"
        customized.avatarBackgroundColorHex = "#AABBCC"

        let decoded = try JSONDecoder().decode(
            GeneralAgentConfiguration.self,
            from: JSONEncoder().encode(customized)
        )
        XCTAssertEqual(decoded, customized)
    }

    func testEd25519SignatureMatchesConnectOnionCanonicalJSON() throws {
        let privateKey = Data((0..<32).map(UInt8.init))
        let identity = try ConnectOnionIdentity(rawPrivateKey: privateKey)
        let payload: [String: Any] = [
            "to": "0x" + String(repeating: "ab", count: 32),
            "timestamp": 1_700_000_000
        ]

        XCTAssertEqual(
            identity.address,
            "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )
        let canonical = try identity.canonicalJSON(for: payload)
        XCTAssertEqual(
            String(data: canonical, encoding: .utf8),
            #"{"timestamp":1700000000,"to":"0xabababababababababababababababababababababababababababababababab"}"#
        )

        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try data(
                fromHex: "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
            )
        )
        let pythonSignatureHex =
            "7350e386cb3d2e2bfe9d6dd95dd31892b339582d0efd5a37d1e2b9088c154696" +
            "0d7f1f7f24892f4537cc7366639ea10cf75522458648cb0315374bdf01c32c00"
        let pythonSignature = try data(fromHex: pythonSignatureHex)
        XCTAssertTrue(publicKey.isValidSignature(pythonSignature, for: canonical))

        let swiftSignature = try data(
            fromHex: identity.signature(for: payload)
        )
        XCTAssertTrue(publicKey.isValidSignature(swiftSignature, for: canonical))
    }

}
