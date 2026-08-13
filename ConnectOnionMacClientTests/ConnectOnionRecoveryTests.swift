import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionRemoteAgentTests {
    func testRecoveryRetriesThenPollsCompletedSession() async throws {
        let address = makeAddress("91")
        let conversationID = UUID()
        let recoveredData = Data("recovered artifact".utf8)
        let recoveredArtifactID = UUID().uuidString
        let recoveredArtifact: [String: Any] = [
            "artifact_id": recoveredArtifactID,
            "name": "recovered.txt",
            "mime_type": "text/plain",
            "size_bytes": recoveredData.count,
            "sha256": SHA256.hash(data: recoveredData)
                .map { String(format: "%02x", $0) }
                .joined(),
            "data_base64": recoveredData.base64EncodedString()
        ]
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let storedSession = try makeJSONData(["cached": true])
        UserDefaults.standard.set(
            try makeJSONData([
                "sessionID": "recover-session",
                "sessionData": storedSession.base64EncodedString(),
                "lastMessageID": "last-event",
                "executionState": "running",
                "activeInputID": "input-recover",
                "inputWasSent": true,
                "desiredMode": "plan",
                "confirmedMode": "safe"
            ]),
            forKey: storageKey
        )

        let pollCounter = LockedCounter()
        RemoteAgentURLProtocolStub.install { request in
            guard request.url?.path != "/info" else {
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(["name": "Recovery Agent", "address": address])
                )
            }

            switch pollCounter.increment() {
            case 1:
                return (makeHTTPResponse(for: request, statusCode: 404), Data())
            case 2:
                return (makeHTTPResponse(for: request, statusCode: 503), Data())
            case 3:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    Data("invalid".utf8)
                )
            case 4:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(["status": "running"])
                )
            case 5:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(["status": "waiting_approval"])
                )
            case 6:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData(["status": "custom"])
                )
            default:
                return (
                    makeHTTPResponse(for: request, statusCode: 200),
                    try makeJSONData([
                        "status": "done",
                        "result": "recovered output",
                        "session": [
                            "generated_artifacts": [recoveredArtifact],
                            "trace": [
                                [
                                    "type": "llm_result",
                                    "usage": [
                                        "input_tokens": 3,
                                        "output_tokens": 2
                                    ],
                                    "context_percent": 15
                                ]
                            ]
                        ]
                    ])
                )
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteAgentURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let resolver = ConnectOnionEndpointResolver(
            urlSession: session,
            relayHTTPBaseURL: relayHTTPBaseURL,
            relayWebSocketURL: relayWebSocketURL
        )
        let socketCounter = LockedCounter()
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            urlSession: session,
            webSocketFactory: { _ in
                _ = socketCounter.increment()
                return ScriptedWebSocketTask(
                    receiveError: ConnectOnionRemoteError.connectionClosed
                )
            },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()

        let initiallyPending = await client.hasPendingExecution()
        XCTAssertTrue(initiallyPending)
        await client.recoverIfNeeded(
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        let pendingAfterRecovery = await client.hasPendingExecution()
        XCTAssertFalse(pendingAfterRecovery)
        XCTAssertEqual(socketCounter.value, 4)
        XCTAssertEqual(pollCounter.value, 7)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.updates.filter { $0.hasPrefix("Reconnecting:") }.count,
            3
        )
        XCTAssertTrue(snapshot.events.contains("recovery:Checking the hosted session result"))
        XCTAssertTrue(snapshot.events.contains("recovery:The hosted agent is still running"))
        XCTAssertTrue(snapshot.events.contains("recovery:The hosted agent is waiting for approval"))
        XCTAssertTrue(snapshot.events.contains("recovery:Hosted session status: custom"))
        XCTAssertTrue(snapshot.events.contains("recovery:Recovered completed session"))
        XCTAssertTrue(snapshot.events.contains("usage:5"))
        XCTAssertTrue(
            snapshot.events.contains(
                "agent_artifact:\(recoveredArtifactID)"
            )
        )
        XCTAssertTrue(snapshot.events.contains("output:recovered output"))
    }

    func testClientStopsRetryingForServerProtocolErrors() async throws {
        let address = makeAddress("92")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Rejecting Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "ready",
                "session_id": "session-error"
            ],
            ["type": "ERROR", "message": "Request denied"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )

        await assertRemoteError(.server("Request denied")) {
            _ = try await client.send(
                prompt: "Rejected",
                onUpdate: { _ in },
                onEvent: { _ in }
            )
        }
    }

    func makeResolver(
        handler: @escaping RemoteAgentURLProtocolStub.Handler
    ) -> ConnectOnionEndpointResolver {
        RemoteAgentURLProtocolStub.install(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteAgentURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return ConnectOnionEndpointResolver(
            urlSession: session,
            relayHTTPBaseURL: relayHTTPBaseURL,
            relayWebSocketURL: relayWebSocketURL
        )
    }

    func makeAddress(_ byte: String) -> String {
        "0x" + String(repeating: byte, count: 32)
    }

    func decodeRelayInfo(
        _ object: [String: Any]
    ) throws -> ConnectOnionRelayAgentInfo {
        try JSONDecoder().decode(
            ConnectOnionRelayAgentInfo.self,
            from: makeJSONData(object)
        )
    }

    func assertRemoteError(
        _ expected: ConnectOnionRemoteError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected.errorDescription ?? "remote error")", file: file, line: line)
        } catch let error as ConnectOnionRemoteError {
            XCTAssertEqual(
                error.errorDescription,
                expected.errorDescription,
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func assertValidSignature(
        in message: [String: Any],
        privateKeyData: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let payload = try XCTUnwrap(
            message["payload"] as? [String: Any],
            file: file,
            line: line
        )
        let signatureHex = try XCTUnwrap(
            message["signature"] as? String,
            file: file,
            line: line
        )
        let signature = try XCTUnwrap(
            Data(hexString: signatureHex),
            file: file,
            line: line
        )
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        )
        let canonicalPayload = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        XCTAssertTrue(
            key.publicKey.isValidSignature(signature, for: canonicalPayload),
            file: file,
            line: line
        )
    }
}
