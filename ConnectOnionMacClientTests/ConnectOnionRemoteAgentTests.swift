import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

final class ConnectOnionRemoteAgentTests: XCTestCase {
    let relayHTTPBaseURL = URL(string: "https://relay.test")!
    let relayWebSocketURL = URL(string: "wss://relay.test/ws/input")!

    private var ephemeralIdentityDirectories: [URL] = []

    override func tearDown() {
        RemoteAgentURLProtocolStub.reset()
        for directory in ephemeralIdentityDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        ephemeralIdentityDirectories.removeAll()
        super.tearDown()
    }

    func makeEphemeralIdentityStore() -> ConnectOnionIdentityStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ConnectOnionRemoteAgentTests-\(UUID().uuidString)"
            )
        ephemeralIdentityDirectories.append(directory)
        return ConnectOnionIdentityStore(
            identityFileURL: directory.appendingPathComponent("identity")
        )
    }

    func testJSONValueConvertsEverySupportedFoundationShapeAndRoundTrips() throws {
        let value = ConnectOnionJSONValue(
            any: [
                "string": "value",
                "boolean": true,
                "number": NSNumber(value: 4.5),
                "array": [1, "two", NSNull()],
                "object": ["nested": false],
                "unsupported": Date(timeIntervalSince1970: 0)
            ] as [String: Any]
        )

        guard case .object(let object) = value else {
            return XCTFail("Expected a JSON object")
        }
        XCTAssertEqual(object["string"], .string("value"))
        XCTAssertEqual(object["boolean"], .bool(true))
        XCTAssertEqual(object["number"], .number(4.5))
        XCTAssertEqual(
            object["array"],
            .array([.number(1), .string("two"), .null])
        )
        XCTAssertEqual(object["object"], .object(["nested": .bool(false)]))
        XCTAssertEqual(object["unsupported"], .null)

        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(ConnectOnionJSONValue.self, from: encoded),
            value
        )
        XCTAssertTrue(value.displayText.contains("\"boolean\" : true"))
        XCTAssertEqual(ConnectOnionJSONValue(any: NSNull()), .null)
    }

    func testRelayReachabilityCoversExplicitAndInferredRoutes() throws {
        let explicitlyOffline = try decodeRelayInfo(
            ["online": false, "endpoints": ["https://agent.test"]]
        )
        XCTAssertFalse(explicitlyOffline.isReachable)

        let explicitlyOnline = try decodeRelayInfo(
            ["online": true, "endpoints": []]
        )
        XCTAssertTrue(explicitlyOnline.isReachable)

        XCTAssertTrue(
            try decodeRelayInfo(["endpoints": ["https://agent.test"]]).isReachable
        )
        XCTAssertTrue(
            try decodeRelayInfo(["endpoints": [], "relay": "connection-1"]).isReachable
        )
        XCTAssertTrue(
            try decodeRelayInfo(
                ["endpoints": [], "relay": ["connection_id": "active"]]
            ).isReachable
        )
        XCTAssertTrue(
            try decodeRelayInfo(["endpoints": [], "relay": ["route"]]).isReachable
        )
        XCTAssertTrue(
            try decodeRelayInfo(["endpoints": [], "relay": 0]).isReachable
        )
        XCTAssertFalse(
            try decodeRelayInfo(["endpoints": [], "relay": ""]).isReachable
        )
        XCTAssertFalse(
            try decodeRelayInfo(["endpoints": [], "relay": NSNull()]).isReachable
        )
    }

    func testExecutionModesAndInteractionDecisionsProduceProtocolPayloads() {
        XCTAssertEqual(AgentExecutionMode.allCases, [.safe, .plan, .accept])
        XCTAssertEqual(AgentExecutionMode.safe.helpText, "Dangerous tools require approval")
        XCTAssertEqual(
            AgentExecutionMode.plan.helpText,
            "Read-only exploration followed by a plan review"
        )
        XCTAssertTrue(AgentExecutionMode.accept.helpText.contains("10 turns"))
        XCTAssertEqual(AgentExecutionMode.safe.systemImage, "checkmark.shield.fill")
        XCTAssertEqual(AgentExecutionMode.plan.systemImage, "list.clipboard.fill")
        XCTAssertEqual(AgentExecutionMode.accept.systemImage, "bolt.shield.fill")
        XCTAssertEqual(AgentExecutionMode.safe.confirmationText, "Safe mode enabled")
        XCTAssertEqual(AgentExecutionMode.plan.confirmationText, "Plan mode enabled")
        XCTAssertEqual(
            AgentExecutionMode.accept.confirmationText,
            "Accept enabled for up to 10 turns"
        )

        let planApproval = ConnectOnionPlanReviewDecision.approve.message
        XCTAssertEqual(planApproval["type"] as? String, "plan_review")
        XCTAssertTrue((planApproval["message"] as? String)?.contains("approved") == true)

        let revision = ConnectOnionPlanReviewDecision
            .requestChanges("Cover the fallback path")
            .message
        XCTAssertTrue(
            (revision["message"] as? String)?.contains("Cover the fallback path") == true
        )

        let cancellation = ConnectOnionPlanReviewDecision.cancel.message
        XCTAssertTrue((cancellation["message"] as? String)?.contains("cancelled") == true)

        XCTAssertEqual(
            ConnectOnionULWCheckpointDecision.continueTenTurns.message["turns"] as? Int,
            AgentExecutionMode.acceptTurns
        )
        XCTAssertEqual(
            ConnectOnionULWCheckpointDecision.returnToSafe.message["mode"] as? String,
            "safe"
        )
        XCTAssertEqual(
            ConnectOnionRemoteAgentClient.buildInterruptMessage(
                inputID: nil
            )["type"] as? String,
            "INTERRUPT"
        )
        XCTAssertNotNil(
            ConnectOnionRemoteAgentClient.buildInterruptMessage(
                inputID: nil
            )["requested_at_ms"] as? Int
        )
        XCTAssertNil(
            ConnectOnionRemoteAgentClient.buildInterruptMessage(inputID: nil)["input_id"],
            "With no active run there is no input_id to correlate."
        )
        XCTAssertEqual(
            ConnectOnionRemoteAgentClient.buildInterruptMessage(
                inputID: "input-42"
            )["input_id"] as? String,
            "input-42",
            "The interrupt must name the run it targets so the peer can echo it back."
        )
    }

    func testApprovalRequestsExplainEverySupportedOperation() {
        func request(
            _ tool: String,
            arguments: [String: ConnectOnionJSONValue] = [:]
        ) -> ConnectOnionApprovalRequest {
            ConnectOnionApprovalRequest(
                id: UUID().uuidString,
                tool: tool,
                arguments: .object(arguments),
                description: nil,
                batchRemaining: []
            )
        }

        XCTAssertEqual(request("delete_file").riskLevel, .high)
        XCTAssertEqual(request("write_file").riskLevel, .medium)
        XCTAssertEqual(request("read_file").riskLevel, .low)
        XCTAssertNil(
            ConnectOnionApprovalRequest(
                id: "non-object",
                tool: "read",
                arguments: .string("value"),
                description: nil,
                batchRemaining: []
            ).targetSummary
        )

        let laterTarget = request(
            "send_email",
            arguments: [
                "path": .string(""),
                "file_path": .number(1),
                "recipient": .string("person@example.test")
            ]
        )
        XCTAssertEqual(laterTarget.targetSummary, "person@example.test")
        XCTAssertTrue(
            laterTarget.plainEnglishExplanation.contains("person@example.test")
        )
        XCTAssertEqual(
            request("reply_to_message").plainEnglishExplanation,
            "Send information to an external recipient."
        )

        let explanations = [
            request(
                "delete_file",
                arguments: ["path": .string("/tmp/report.txt")]
            ).plainEnglishExplanation,
            request("remove_item").plainEnglishExplanation,
            request(
                "write_file",
                arguments: ["filename": .string("/tmp/output.txt")]
            ).plainEnglishExplanation,
            request("write_file").plainEnglishExplanation,
            request(
                "edit_file",
                arguments: ["filepath": .string("/tmp/source.swift")]
            ).plainEnglishExplanation,
            request("patch_resource").plainEnglishExplanation,
            request(
                "create_file",
                arguments: ["target": .string("/tmp/new.txt")]
            ).plainEnglishExplanation,
            request("create_resource").plainEnglishExplanation,
            request(
                "rename_file",
                arguments: ["file_path": .string("/tmp/old.txt")]
            ).plainEnglishExplanation,
            request("move_resource").plainEnglishExplanation,
            request(
                "upload_file",
                arguments: ["url": .string("https://uploads.test")]
            ).plainEnglishExplanation,
            request("upload_file").plainEnglishExplanation,
            request("click_element").plainEnglishExplanation,
            request("custom_tool").plainEnglishExplanation
        ]
        XCTAssertEqual(explanations.count, 14)
        XCTAssertTrue(explanations[0].contains("report.txt"))
        XCTAssertEqual(explanations[1], "Delete the selected item.")
        XCTAssertTrue(explanations[2].contains("output.txt"))
        XCTAssertEqual(explanations[3], "Write content to a file.")
        XCTAssertTrue(explanations[4].contains("source.swift"))
        XCTAssertEqual(explanations[5], "Modify an existing file or resource.")
        XCTAssertTrue(explanations[6].contains("new.txt"))
        XCTAssertEqual(explanations[7], "Create a new file or resource.")
        XCTAssertTrue(explanations[8].contains("old.txt"))
        XCTAssertEqual(explanations[9], "Move or rename a file or resource.")
        XCTAssertTrue(explanations[10].contains("uploads.test"))
        XCTAssertEqual(explanations[11], "Upload a file to an external service.")
        XCTAssertEqual(explanations[12], "Interact with the currently open webpage.")
        XCTAssertTrue(explanations[13].contains("custom_tool"))

        let commandExpectations: [(String, String)] = [
            ("rm -rf build", "Delete"),
            ("mkdir output", "folders"),
            ("touch file.txt", "empty file"),
            ("cp a b", "Copy"),
            ("mv a b", "Move"),
            ("git status", "Git status"),
            ("git", "Git operation"),
            ("npm test", "test task"),
            ("pnpm", "command task"),
            ("yarn build", "build task"),
            ("python script.py", "Python"),
            ("python3 script.py", "Python"),
            ("swift test", "Swift"),
            ("curl example.test", "using curl"),
            ("   ", "shell command")
        ]
        for (command, expectedText) in commandExpectations {
            let approval = request(
                "shell_command",
                arguments: ["command": .string(command)]
            )
            XCTAssertTrue(
                approval.plainEnglishExplanation.contains(expectedText),
                "Expected \(command) to contain \(expectedText)"
            )
        }
        let scriptApproval = request(
            "execute_script",
            arguments: ["script": .string("swift test")]
        )
        XCTAssertEqual(scriptApproval.commandText, "swift test")

        let field = ConnectOnionAskUserField(
            name: "environment",
            label: "Environment",
            type: "text"
        )
        XCTAssertEqual(field.id, "environment")
    }

    func testRemoteErrorsExposeStableDescriptionsAndRetryPolicy() {
        struct ErrorExpectation {
            let error: ConnectOnionRemoteError
            let description: String
            let isRetryable: Bool
        }

        let cases: [ErrorExpectation] = [
            .init(
                error: .invalidAgentTarget,
                description: "Enter a valid ConnectOnion 0x address or HTTP(S) Direct URL",
                isRetryable: false
            ),
            .init(
                error: .agentNotFound,
                description: "The ConnectOnion relay could not find this agent",
                isRetryable: false
            ),
            .init(
                error: .agentOffline,
                description: "The ConnectOnion agent is offline",
                isRetryable: false
            ),
            .init(
                error: .invalidRelayResponse,
                description: "The ConnectOnion relay returned an invalid response",
                isRetryable: false
            ),
            .init(
                error: .directEndpointUnavailable,
                description: "The agent's direct endpoint is unavailable",
                isRetryable: true
            ),
            .init(
                error: .invalidAgentInfo,
                description: "The agent endpoint did not return a matching ConnectOnion address",
                isRetryable: false
            ),
            .init(
                error: .invalidProtocolMessage,
                description: "The hosted agent returned an invalid protocol message",
                isRetryable: false
            ),
            .init(
                error: .connectionClosed,
                description: "The hosted agent connection closed unexpectedly",
                isRetryable: true
            ),
            .init(
                error: .timedOut,
                description: "The hosted agent request timed out",
                isRetryable: true
            ),
            .init(
                error: .requestInProgress,
                description: "Wait for the current hosted agent request to finish",
                isRetryable: false
            ),
            .init(
                error: .recoveryUnavailable,
                description: "The hosted session could not be recovered safely. The original task was not resent.",
                isRetryable: false
            ),
            .init(
                error: .cancelled,
                description: "The hosted agent connection was cancelled",
                isRetryable: false
            ),
            .init(
                error: .interactionRequired("Approval needed"),
                description: "Approval needed",
                isRetryable: false
            ),
            .init(
                error: .server("Server rejected the request"),
                description: "Server rejected the request",
                isRetryable: false
            )
        ]

        for expectation in cases {
            XCTAssertEqual(
                expectation.error.errorDescription,
                expectation.description
            )
            XCTAssertEqual(
                expectation.error.isRetryable,
                expectation.isRetryable
            )
        }
    }

    func testIdentityProducesStableAddressCanonicalJSONAndVerifiableSignature() throws {
        let privateKeyData = Data((0..<32).map(UInt8.init))
        let identity = try ConnectOnionIdentity(rawPrivateKey: privateKeyData)
        let payload: [String: Any] = ["z": "last", "a": 1]

        XCTAssertEqual(identity.rawPrivateKey, privateKeyData)
        XCTAssertEqual(identity.address.count, 66)
        XCTAssertEqual(ConnectOnionAddress.normalized(identity.address), identity.address)
        XCTAssertEqual(
            String(data: try identity.canonicalJSON(for: payload), encoding: .utf8),
            #"{"a":1,"z":"last"}"#
        )

        let signature = try identity.signature(for: payload)
        XCTAssertEqual(signature.count, 128)
        let signatureData = try XCTUnwrap(Data(hexString: signature))
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        )
        XCTAssertTrue(
            privateKey.publicKey.isValidSignature(
                signatureData,
                for: try identity.canonicalJSON(for: payload)
            )
        )
        XCTAssertThrowsError(
            try ConnectOnionIdentity(rawPrivateKey: Data([0x01, 0x02]))
        )
    }

    func testIdentityStorePersistsReusesAndSecuresIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)
        let created = try store.loadOrCreateIdentity()
        let cached = try store.loadOrCreateIdentity()
        let reloaded = try ConnectOnionIdentityStore(
            identityFileURL: identityURL
        ).loadOrCreateIdentity()

        XCTAssertEqual(created.rawPrivateKey, cached.rawPrivateKey)
        XCTAssertEqual(created.rawPrivateKey, reloaded.rawPrivateKey)
        XCTAssertEqual(created.address, reloaded.address)
        XCTAssertEqual(try Data(contentsOf: identityURL), created.rawPrivateKey)

        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: identityURL.path
            )[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: directory.path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
    }

    func testIdentityStoreRejectsMalformedStoredPrivateKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02]).write(to: identityURL)

        XCTAssertThrowsError(
            try ConnectOnionIdentityStore(
                identityFileURL: identityURL
            ).loadOrCreateIdentity()
        )
    }

}
