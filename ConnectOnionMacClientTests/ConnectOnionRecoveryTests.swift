import CryptoKit
import Foundation
import XCTest
import ConnectOnionKit

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
        // let canonicalPayload = try JSONSerialization.data(
        //     withJSONObject: payload,
        //     options: [.sortedKeys]
        // )

        let canonicalPayload = CanonicalJSON.data(from: payload.mapValues { JSONValue(any: $0) })
        XCTAssertTrue(
            key.publicKey.isValidSignature(signature, for: canonicalPayload),
            file: file,
            line: line
        )
    }

    func testRelaunchedClientResumesTheSameSessionWithItsLastMessageID() async throws {
        let address = makeAddress("93")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        // What the first launch left behind before it was killed.
        UserDefaults.standard.set(
            try makeJSONData([
                "sessionID": "relaunch-session",
                "lastMessageID": "evt-41",
                "executionState": "idle",
                "inputWasSent": false
            ]),
            forKey: storageKey
        )

        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Relaunch Agent", "address": address])
            )
        }

        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "connected",
                "session_id": "relaunch-session"
            ],
            ["type": "OUTPUT", "result": "picked up where we left off"]
        ])

        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )

        let output = try await client.send(
            prompt: "Continue",
            onUpdate: { _ in },
            onEvent: { _ in }
        )

        XCTAssertEqual(output, "picked up where we left off")
        let connect = try XCTUnwrap(try socket.sentJSONObjects().first)
        XCTAssertEqual(connect["type"] as? String, "CONNECT")
        XCTAssertEqual(connect["session_id"] as? String, "relaunch-session")
        XCTAssertEqual(connect["last_msg_id"] as? String, "evt-41")
    }
}

// A turn that finished while the app was quit (or the socket was down) is not replayed by the
// host: CONNECTED says "connected" and the turn is in chat_items. These cover reading it back
// without ever sending the INPUT a second time.
extension ConnectOnionRemoteAgentTests {
    func testRelaunchShowsAReplyThatFinishedWhileTheAppWasQuit() async throws {
        let address = makeAddress("94")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        // What the first launch left behind: INPUT sent, no OUTPUT yet, then the app quit.
        UserDefaults.standard.set(
            try makeJSONData([
                "sessionID": "quit-session",
                "sessionData": try makeJSONData(["turn": 1]).base64EncodedString(),
                "lastMessageID": "evt-7",
                "executionState": "running",
                "activeInputID": "input-quit",
                "inputWasSent": true,
                "activePrompt": "Make him a text file"
            ]),
            forKey: storageKey
        )
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Quit Agent", "address": address])
            )
        }
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "connected",
                "session_id": "quit-session",
                "server_newer": true,
                "session": ["turn": 2],
                "chat_items": [
                    ["id": "msg-0", "type": "user", "content": "Make a smiling man"],
                    ["id": "msg-1", "type": "agent", "content": "  :)"],
                    ["id": "msg-2", "type": "user", "content": "Make him a text file"],
                    ["id": "tool-1", "type": "tool_call", "name": "write", "status": "done"],
                    ["id": "msg-3", "type": "agent", "content": "Created smiley.txt"]
                ]
            ]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()

        await client.recoverIfNeeded(
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.events.contains("output:Created smiley.txt"))
        XCTAssertTrue(snapshot.events.contains("recovery:Recovered completed session"))
        XCTAssertFalse(snapshot.events.contains { $0.hasPrefix("error:") })
        let pendingAfter = await client.hasPendingExecution()
        XCTAssertFalse(pendingAfter)
        let sent = try socket.sentJSONObjects()
        XCTAssertEqual(sent.compactMap { $0["type"] as? String }, ["CONNECT"], "the INPUT was sent again")
        // No turn history goes up, so the host's copy wins and chat_items come back.
        XCTAssertNil(sent.first?["session"] as? [String: Any])
    }

    func testRelaunchNeverShowsAnOlderTurnsReplyOrResends() async throws {
        let address = makeAddress("95")
        let conversationID = UUID()
        let storageKey = "connectonion.remote-session.\(conversationID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        UserDefaults.standard.set(
            try makeJSONData([
                "sessionID": "lost-session",
                "executionState": "running",
                "activeInputID": "input-lost",
                "inputWasSent": true,
                "activePrompt": "Delete the temp folder"
            ]),
            forKey: storageKey
        )
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Lost Agent", "address": address])
            )
        }
        // The INPUT never arrived: the host's last turn is an older message.
        let socket = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "connected",
                "session_id": "lost-session",
                "server_newer": true,
                "chat_items": [
                    ["id": "msg-0", "type": "user", "content": "earlier"],
                    ["id": "msg-1", "type": "agent", "content": "earlier reply"]
                ]
            ]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: conversationID,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()

        await client.recoverIfNeeded(
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertFalse(snapshot.events.contains("output:earlier reply"))
        XCTAssertTrue(snapshot.events.contains(
            "error:" + (ConnectOnionRemoteError.recoveryUnavailable.errorDescription ?? "")
        ))
        XCTAssertEqual(try socket.sentJSONObjects().compactMap { $0["type"] as? String }, ["CONNECT"])
    }

    func testDroppedSocketAfterTheTurnFinishedReturnsTheReplyWithoutResending() async throws {
        let address = makeAddress("96")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Drop Agent", "address": address])
            )
        }
        // First socket: connects, takes the INPUT, then drops before OUTPUT.
        let first = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "new", "session_id": "drop-session"]
        ])
        // By the reconnect the host has finished the turn.
        let second = try ScriptedWebSocketTask(events: [
            [
                "type": "CONNECTED",
                "status": "connected",
                "session_id": "drop-session",
                "server_newer": true,
                "chat_items": [
                    ["id": "msg-0", "type": "user", "content": "Continue"],
                    ["id": "msg-1", "type": "agent", "content": "done"]
                ]
            ]
        ])
        let sockets = [first, second]
        let opened = LockedCounter()
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in sockets[min(opened.increment(), sockets.count) - 1] },
            sleep: { _ in }
        )

        let output = try await client.send(
            prompt: "Continue",
            onUpdate: { _ in },
            onEvent: { _ in }
        )

        XCTAssertEqual(output, "done")
        XCTAssertEqual(opened.value, 2)
        XCTAssertEqual(try first.sentJSONObjects().compactMap { $0["type"] as? String }, ["CONNECT", "INPUT"])
        XCTAssertEqual(try second.sentJSONObjects().compactMap { $0["type"] as? String }, ["CONNECT"])
    }
}
