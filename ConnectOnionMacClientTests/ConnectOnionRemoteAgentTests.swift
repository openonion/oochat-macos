import ConnectOnionKit
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
        let value = JSONValue(
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
            try JSONDecoder().decode(JSONValue.self, from: encoded),
            value
        )
        XCTAssertTrue(value.displayText.contains("\"boolean\" : true"))
        XCTAssertEqual(JSONValue(any: NSNull()), .null)
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
        XCTAssertEqual(AgentExecutionMode.safe.helpText, "Review each action and approve safe work automatically.")
        XCTAssertEqual(AgentExecutionMode.plan.helpText, "Ask before any change.")
        XCTAssertTrue(AgentExecutionMode.accept.helpText.contains("turns shown"))
        XCTAssertEqual(AgentExecutionMode.safe.systemImage, "checkmark.shield.fill")
        XCTAssertEqual(AgentExecutionMode.plan.systemImage, "list.clipboard.fill")
        XCTAssertEqual(AgentExecutionMode.accept.systemImage, "bolt.shield.fill")
        XCTAssertEqual(AgentExecutionMode.safe.confirmationText, "Auto enabled")
        XCTAssertEqual(AgentExecutionMode.plan.confirmationText, "Read only enabled")
        XCTAssertEqual(
            AgentExecutionMode.accept.confirmationText,
            "Full access enabled"
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
            ConnectOnionULWCheckpointDecision.continueTurns.message["turns"] as? Int,
            AgentExecutionMode.acceptTurns
        )
        XCTAssertEqual(
            ConnectOnionULWCheckpointDecision.returnToSafe.message["mode"] as? String,
            "safe"
        )
    }

    func testApprovalRequestsExplainEverySupportedOperation() {
        func request(
            _ tool: String,
            arguments: [String: JSONValue] = [:]
        ) -> ConnectOnionApprovalRequest {
            ConnectOnionApprovalRequest(
                id: UUID().uuidString,
                tool: tool,
                arguments: .object(arguments),
                description: nil,
                batchRemaining: []
            )
        }

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
            laterTarget.kitSummary.contains("person@example.test")
        )
        XCTAssertEqual(
            request("reply_to_message").kitSummary,
            "Send information to an external recipient."
        )

        let explanations = [
            request(
                "delete_file",
                arguments: ["path": .string("/tmp/report.txt")]
            ).kitSummary,
            request("remove_item").kitSummary,
            request(
                "write_file",
                arguments: ["filename": .string("/tmp/output.txt")]
            ).kitSummary,
            request("write_file").kitSummary,
            request(
                "edit_file",
                arguments: ["filepath": .string("/tmp/source.swift")]
            ).kitSummary,
            request("patch_resource").kitSummary,
            request(
                "create_file",
                arguments: ["target": .string("/tmp/new.txt")]
            ).kitSummary,
            request("create_resource").kitSummary,
            request(
                "rename_file",
                arguments: ["file_path": .string("/tmp/old.txt")]
            ).kitSummary,
            request("move_resource").kitSummary,
            request(
                "upload_file",
                arguments: ["url": .string("https://uploads.test")]
            ).kitSummary,
            request("upload_file").kitSummary,
            request("click_element").kitSummary,
            request("custom_tool").kitSummary
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
                approval.kitSummary.contains(expectedText),
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
                description: "Enter a valid 0x address or HTTP(S) Direct URL",
                isRetryable: false
            ),
            .init(
                error: .agentNotFound,
                description: "The relay could not find this agent",
                isRetryable: false
            ),
            .init(
                error: .agentOffline,
                description: "The agent is offline",
                isRetryable: false
            ),
            .init(
                error: .invalidRelayResponse,
                description: "The relay returned an invalid response",
                isRetryable: false
            ),
            .init(
                error: .directEndpointUnavailable,
                description: "The agent's direct endpoint is unavailable",
                isRetryable: true
            ),
            .init(
                error: .invalidAgentInfo,
                description: "The agent endpoint did not return a matching agent address",
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
            ),
            .init(
                error: .incompatibleProtocol(
                    OIPHandshake.Incompatibility(neededVersion: "0.2", appVersion: "0.1")
                ),
                description: "This agent needs OIP 0.2. This app speaks OIP 0.1. Update the app to connect.",
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

    func testIdentityStoreReplaceChangesAddressAndSignsWithTheNewKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)
        let original = try store.loadOrCreateIdentity()
        let newKey = Curve25519.Signing.PrivateKey()
        let payload: [String: Any] = ["type": "INPUT", "prompt": "hi"]

        try store.replacePrivateKey(with: newKey.rawRepresentation)

        let replaced = try store.loadOrCreateIdentity()
        XCTAssertNotEqual(replaced.address, original.address)
        XCTAssertEqual(replaced.address, "0x" + Hex.encode(newKey.publicKey.rawRepresentation))
        let signature = try XCTUnwrap(Data(hexString: try replaced.signature(for: payload)))
        XCTAssertTrue(newKey.publicKey.isValidSignature(signature, for: try replaced.canonicalJSON(for: payload)))
        XCTAssertEqual(
            try ConnectOnionIdentityStore(identityFileURL: identityURL).loadOrCreateIdentity().address,
            replaced.address
        )
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: identityURL.path)[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
    }

    func testIdentityStoreRejectsAMalformedReplacementAndKeepsItsKey() throws {
        let store = makeEphemeralIdentityStore()
        let original = try store.loadOrCreateIdentity()

        XCTAssertThrowsError(try store.replacePrivateKey(with: Data([0x01, 0x02])))

        XCTAssertEqual(try store.loadOrCreateIdentity().address, original.address)
        XCTAssertFalse(store.isLinked)
    }

    func testIdentityStoreLinkedFlagIsFalseOnAFreshStore() throws {
        let store = makeEphemeralIdentityStore()
        XCTAssertFalse(store.isLinked)
        _ = try store.loadOrCreateIdentity()
        XCTAssertFalse(store.isLinked)
    }

    func testIdentityStoreLinkedFlagIsSetByReplaceAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }

        try ConnectOnionIdentityStore(identityFileURL: identityURL)
            .replacePrivateKey(with: Curve25519.Signing.PrivateKey().rawRepresentation)

        XCTAssertTrue(ConnectOnionIdentityStore(identityFileURL: identityURL).isLinked)
    }

    func testIdentityStoreLinkedFlagIsSetByMarkLinkedAndKeepsTheKey() throws {
        let store = makeEphemeralIdentityStore()
        let address = try store.loadOrCreateIdentity().address

        try store.markLinked()

        XCTAssertTrue(store.isLinked)
        XCTAssertEqual(try store.loadOrCreateIdentity().address, address)
    }

    // A Giving Device with no key must not make one up to send or to mark linked.
    func testIdentityStoreWithNoKeyGivesNothingAndCreatesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)

        XCTAssertNil(try store.loadPrivateKey())
        XCTAssertThrowsError(try store.markLinked())
        XCTAssertFalse(FileManager.default.fileExists(atPath: identityURL.path))
    }

    // The key is what a link changes: a flag that can't be written must not undo or fail the replace.
    func testIdentityStoreReplaceSucceedsWhenTheLinkedFlagCannotBeWritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)
        let original = try store.loadOrCreateIdentity().address
        try FileManager.default.createDirectory(
            at: identityURL.appendingPathExtension("linked"),
            withIntermediateDirectories: true
        )
        let newKey = Curve25519.Signing.PrivateKey()

        XCTAssertNoThrow(try store.replacePrivateKey(with: newKey.rawRepresentation))

        let replaced = try store.loadOrCreateIdentity().address
        XCTAssertNotEqual(replaced, original)
        XCTAssertEqual(replaced, "0x" + Hex.encode(newKey.publicKey.rawRepresentation))
        XCTAssertFalse(store.isLinked)
    }

    func testIdentityStoreLinkedFlagWithUnexpectedContentReadsUnlinked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)
        _ = try store.loadOrCreateIdentity()

        try Data("not an address".utf8).write(to: identityURL.appendingPathExtension("linked"))

        XCTAssertFalse(store.isLinked)
    }

    func testIdentityStoreLinkedFlagGoesWithALostKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let linked = ConnectOnionIdentityStore(identityFileURL: identityURL)
        _ = try linked.loadOrCreateIdentity()
        try linked.markLinked()
        XCTAssertTrue(ConnectOnionIdentityStore(identityFileURL: identityURL).isLinked)

        try FileManager.default.removeItem(at: identityURL)
        XCTAssertFalse(ConnectOnionIdentityStore(identityFileURL: identityURL).isLinked)

        let fresh = ConnectOnionIdentityStore(identityFileURL: identityURL)
        _ = try fresh.loadOrCreateIdentity()
        XCTAssertFalse(fresh.isLinked)
    }
    // The Kit's link flow drives this store: a Receiving Device takes on the giver's key, a Giving
    // Device keeps its own; both end linked. The link runs in memory, so no socket opens.
    @MainActor
    func testTheLinkFlowReplacesThisStoresKeyOnTheReceivingDevice() async throws {
        let store = makeEphemeralIdentityStore()
        let giverKey = Curve25519.Signing.PrivateKey()
        let giverStore = InMemoryPrivateKeyStore(rawKey: giverKey.rawRepresentation)
        var replaced = false
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { _ in replaced = true }, receive: { receiver, accept in
            let giver = try DeviceLinkGiver(scanning: receiver.offer, keyStore: giverStore)
            let identity = try receiver.accept(try giver.seal(for: try giver.verify(try receiver.start())))
            guard await accept(identity) else { throw DeviceLinkError.cancelled }
            return identity
        })
        let giverAddress = "0x" + Hex.encode(giverKey.publicKey.rawRepresentation)

        flow.start()
        try await waitForStep(of: flow) { if case .confirmingReplace = $0 { true } else { false } }
        XCTAssertFalse(store.isLinked, "nothing changes before the person accepts")
        flow.confirm()
        try await waitForStep(of: flow) { $0 == .done(address: giverAddress) }

        XCTAssertEqual(try store.loadOrCreateIdentity().address, giverAddress)
        XCTAssertTrue(store.isLinked)
        XCTAssertTrue(replaced)
    }

    @MainActor
    func testTheLinkFlowMarksThisStoreLinkedOnTheGivingDevice() async throws {
        let store = makeEphemeralIdentityStore()
        let address = try store.loadOrCreateIdentity().address
        let receiver = try DeviceLinkReceiver()
        var linked = false
        let flow = DeviceLinkFlow(
            role: .giving,
            keyStore: store,
            onLinked: { linked = true },
            ownerCheck: { true },
            give: { giver, approve in
                let verified = try giver.verify(try receiver.start())
                guard await approve() else { throw DeviceLinkError.cancelled }
                _ = try receiver.accept(try giver.seal(for: verified))
            }
        )

        flow.start()
        flow.submit(receiver.offer.linkCode)
        try await waitForStep(of: flow) { $0 == .confirmingSend }
        flow.confirm()
        try await waitForStep(of: flow) { $0 == .done(address: address) }

        XCTAssertTrue(store.isLinked)
        XCTAssertTrue(linked, "the app hears it, to start its viewers")
        XCTAssertEqual(try store.loadOrCreateIdentity().address, address, "the giver keeps its key")
    }

    // The Mac giver opens on its own code; a receiver types it, and the Mac ends linked as before.
    @MainActor
    func testAGiverThatShowsItsCodeMarksThisStoreLinked() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectOnionRemoteAgentTests-\(UUID().uuidString)")
        let identityURL = directory.appendingPathComponent("identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectOnionIdentityStore(identityFileURL: identityURL)
        let address = try store.loadOrCreateIdentity().address
        var linked = false
        let flow = DeviceLinkFlow(
            role: .giving,
            keyStore: store,
            displaysCode: true,
            onLinked: { linked = true },
            ownerCheck: { true },
            give: { giver, approve in
                let typed = try DeviceLinkOffer(linkCode: giver.offer.linkCode, displayer: .giving, now: Date())
                let receiver = try DeviceLinkReceiver(scanning: typed)
                let verified = try giver.verify(try receiver.start())
                guard await approve() else { throw DeviceLinkError.cancelled }
                _ = try receiver.accept(try giver.seal(for: verified))
            }
        )

        flow.start()
        guard case .showingCode = flow.step else { return XCTFail("the giver shows its code first") }
        try await waitForStep(of: flow) { $0 == .confirmingSend }
        XCTAssertFalse(store.isLinked, "nothing is linked before the owner says yes")
        flow.confirm()
        try await waitForStep(of: flow) { $0 == .done(address: address) }

        XCTAssertTrue(ConnectOnionIdentityStore(identityFileURL: identityURL).isLinked, "the flag is on disk")
        XCTAssertTrue(linked, "the app hears it, to start its viewers")
    }

    @MainActor
    private func waitForStep(of flow: DeviceLinkFlow, _ matches: (DeviceLinkFlow.Step) -> Bool) async throws {
        for _ in 0..<400 where !matches(flow.step) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(matches(flow.step), "stuck at \(flow.step)")
    }

}

extension ConnectOnionRemoteAgentTests {
    func testDefaultSocketAcceptsTheHostsLargestMessage() throws {
        let socketURL = try XCTUnwrap(URL(string: "wss://agent.test/ws"))
        let task = URLSession.shared.webSocketTask(with: socketURL)
        defer { task.cancel() }
        XCTAssertEqual(
            task.maximumMessageSize,
            1_048_576,
            "URLSession's default, which a large snapshot would exceed"
        )
        let made = ConnectOnionRemoteAgentClient.defaultWebSocket(urlSession: .shared)(socketURL)
        let configured = try XCTUnwrap(made as? URLSessionWebSocketTask)
        defer { configured.cancel() }
        XCTAssertEqual(configured.maximumMessageSize, OIPDashboard.socketMessageBytes)
    }

    func testDashboardSnapshotsReachTheChatAndAnOversizedOneIsTooLarge() async throws {
        let address = makeAddress("a5")
        let resolver = makeResolver { request in
            (
                makeHTTPResponse(for: request, statusCode: 200),
                try makeJSONData(["name": "Dashboard Agent", "address": address])
            )
        }
        let oversized = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)
        let socket = try ScriptedWebSocketTask(events: [
            ["type": "CONNECTED", "status": "connected", "session_id": "dashboard-session"],
            ["type": "DASHBOARD_SNAPSHOT", "html": "<h1>Hi</h1>"],
            ["type": "DASHBOARD_SNAPSHOT", "html": oversized],
            ["type": "OUTPUT", "result": "done"]
        ])
        let client = ConnectOnionRemoteAgentClient(
            configuredTarget: "https://agent.test",
            conversationID: nil,
            resolver: resolver,
            identityStore: makeEphemeralIdentityStore(),
            webSocketFactory: { _ in socket },
            sleep: { _ in }
        )
        let recorder = RemoteProtocolRecorder()
        let output = try await client.send(
            prompt: "Show me",
            onUpdate: { await recorder.record($0) },
            onEvent: { await recorder.record($0) }
        )

        XCTAssertEqual(output, "done", "a page over the cap must not end the run")

        let events = await recorder.snapshot().events

        XCTAssertTrue(events.contains("dashboard:11"))
        XCTAssertTrue(events.contains("dashboard_too_large:\(OIPDashboard.clientCapBytes + 1)"))
    }
}

// Link a freshly set up Mac to a phone: the phone's agent arrives under its name, History Restore fills the
// sidebar with the phone's chat, then a turn sent on the phone plays here. Both devices run the Kit's link
// flow with in-memory key stores, joined in memory.
extension ConnectOnionRemoteAgentTests {
    @MainActor
    func testALinkedMacRestoresThePhonesChatThenWatchesATurnSentOnThePhone() async throws {
        let phone = InMemoryPrivateKeyStore()
        let mac = InMemoryPrivateKeyStore()
        let phoneAddress = try OIPSigner(keyStore: phone).address()
        let sessionID = UUID().uuidString.lowercased()
        // The host returns its Hosted History only to the Address that signed for it.
        RemoteAgentURLProtocolStub.install { request in
            let owned: [[String: Any]] = request.value(forHTTPHeaderField: "x-co-from") == phoneAddress ? [[
                "session_id": sessionID, "status": "done", "prompt": "Hi", "created": 1_700_000_000,
                "session": ["messages": [["role": "user", "content": "Hi"], ["role": "assistant", "content": "Hello"]]]
            ]] : []
            return (makeHTTPResponse(for: request, statusCode: 200), try makeJSONData(["sessions": owned]))
        }
        let agentAddress = makeAddress("a7")
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: agentAddress,
            webSocketURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:8000/ws")),
            httpBaseURL: URL(string: "http://127.0.0.1:8000"),
            isDirect: true,
            info: nil
        )
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [RemoteAgentURLProtocolStub.self]
        let appViewModel = AppViewModel(
            storage: try XCTUnwrap(UserDefaults(suiteName: "linked-mac-\(UUID())")),
            localAgentDefinitions: [],
            historyURLSession: URLSession(configuration: urlConfiguration),
            historyKeyStore: mac,
            resolveAgentEndpoint: { _ in endpoint }
        )
        XCTAssertTrue(appViewModel.configurations.isEmpty)
        XCTAssertFalse(phone.isLinked)
        XCTAssertFalse(mac.isLinked)

        let link = InMemoryLink()
        let macFlow = DeviceLinkFlow(
            role: .receiving,
            keyStore: mac,
            onReplaced: { appViewModel.adoptReplacedIdentity(previousAddress: $0) },
            onAgentNames: appViewModel.applyLinkedAgentNames,
            receive: { try await link.receive($0, $1) }
        )
        let phoneFlow = DeviceLinkFlow(
            role: .giving,
            keyStore: phone,
            agentNames: { [DeviceLinkAgentName(address: agentAddress, name: "Bot")].compactMap { $0 } },
            ownerCheck: { true },
            give: { try await link.give($0, $1) }
        )
        macFlow.start()
        guard case .showingCode(let offer) = macFlow.step else { return XCTFail("the Mac shows its code") }
        await eventually { link.isWaiting }
        phoneFlow.start()
        phoneFlow.submit(try offer.qrPayload)
        await eventually { phoneFlow.step == .confirmingSend }
        phoneFlow.confirm()
        await eventually { if case .confirmingReplace = macFlow.step { true } else { false } }
        macFlow.confirm()
        await eventually { macFlow.step == .done(address: phoneAddress) && phoneFlow.step == .done(address: phoneAddress) }

        XCTAssertTrue(phone.isLinked)
        XCTAssertTrue(mac.isLinked)
        let configuration = try XCTUnwrap(appViewModel.configurations.first)
        XCTAssertEqual(appViewModel.configurations.count, 1)
        XCTAssertEqual(configuration.name, "Bot")
        XCTAssertEqual(configuration.agentAddress, agentAddress)
        // No refresh: the link itself brings the phone's chats in.
        await eventually { appViewModel.sessions.count == 1 }
        let restored = try XCTUnwrap(appViewModel.sessions.first)
        XCTAssertEqual(restored.remoteSessionID, sessionID)
        XCTAssertEqual(appViewModel.findMessages(for: restored.id).map(\.content), ["Hi", "Hello"])

        let stub = await StubRemoteAgentClient(endpoint: endpoint)
        await stub.setObservedEvents([.mirroredUserMessage("One more?"), .output("Sure")])
        let service = ConnectOnionService(
            isLinked: { mac.isLinked },
            linkNotifications: NotificationCenter(),
            remoteAgentFactory: { _, _, _ in stub }
        )
        let chat = ChatViewModel(session: restored, configuration: configuration, service: service, appViewModel: appViewModel)
        chat.connectIfNeeded()
        await eventually { chat.messages.count == 4 && !service.isMirroredTurn }

        XCTAssertEqual(chat.messages.map(\.content), ["Hi", "Hello", "One more?", "Sure"])
        let sent = await stub.sentRequestSnapshot()
        XCTAssertTrue(sent.isEmpty, "the turn was the phone's")
    }

    // Mac to Mac: the receiver renames the agent both have, adds the one it lacks and keeps its own; the
    // giver sends 0x agents and Direct URL agents it knows the Address of, and changes nothing.
    @MainActor
    func testALinkGivesTheReceiverTheGiversAgentNames() async throws {
        let giverKeys = InMemoryPrivateKeyStore()
        let receiverKeys = InMemoryPrivateKeyStore()
        let giverAddress = try OIPSigner(keyStore: giverKeys).address()
        let giver = makeOfflineAppViewModel()
        var knownURL = makeAgent("Giver D", target: "http://agent-d.test")
        knownURL.resolvedAddress = makeAddress("dd")
        giver.configurations = [
            makeAgent("Giver A", target: "0x" + String(repeating: "AA", count: 32)),
            makeAgent("Giver B", target: makeAddress("bb")),
            knownURL,
            makeAgent("Giver E", target: "http://agent-e.test")
        ]
        let giverAgents = giver.configurations
        let receiver = makeOfflineAppViewModel()
        receiver.configurations = [makeAgent("Mine A", target: makeAddress("aa")), makeAgent("Mine C", target: makeAddress("cc"))]
        let receiverAgents = receiver.configurations

        XCTAssertEqual(giver.agentNamesForLink().map(\.address), [makeAddress("aa"), makeAddress("bb"), makeAddress("dd")])
        let link = InMemoryLink()
        let receiverFlow = DeviceLinkFlow(
            role: .receiving,
            keyStore: receiverKeys,
            onReplaced: { receiver.adoptReplacedIdentity(previousAddress: $0) },
            onAgentNames: receiver.applyLinkedAgentNames,
            receive: { try await link.receive($0, $1) }
        )
        let giverFlow = DeviceLinkFlow(
            role: .giving, keyStore: giverKeys, agentNames: giver.agentNamesForLink, ownerCheck: { true },
            give: { try await link.give($0, $1) }
        )
        receiverFlow.start()
        guard case .showingCode(let offer) = receiverFlow.step else { return XCTFail("the receiver shows its code") }
        await eventually { link.isWaiting }
        giverFlow.start()
        giverFlow.submit(try offer.qrPayload)
        await eventually { giverFlow.step == .confirmingSend }
        giverFlow.confirm()
        await eventually { if case .confirmingReplace = receiverFlow.step { true } else { false } }
        receiverFlow.confirm()
        await eventually { receiverFlow.step == .done(address: giverAddress) }

        XCTAssertEqual(receiver.configurations.map(\.name), ["Giver A", "Mine C", "Giver B", "Giver D"])
        XCTAssertEqual(receiver.configurations.map(\.id).prefix(2), receiverAgents.map(\.id).prefix(2))
        XCTAssertEqual(receiver.configurations.map(\.agentAddress), ["aa", "cc", "bb", "dd"].map(makeAddress))
        XCTAssertEqual(giver.configurations, giverAgents, "the giver adopts nothing")
    }

    // Saving the agents is best-effort: the key is what must not fail.
    @MainActor
    func testAReceiverThatCannotSaveTheAgentsKeepsTheNewIdentity() async throws {
        struct SaveFailed: Error {}
        let store = makeEphemeralIdentityStore()
        let giverStore = InMemoryPrivateKeyStore()
        let giverAddress = try OIPSigner(keyStore: giverStore).address()
        var replaced = false
        let flow = DeviceLinkFlow(
            role: .receiving,
            keyStore: store,
            onReplaced: { _ in replaced = true },
            onAgentNames: { _ in throw SaveFailed() },
            receive: { receiver, accept in
                let names = [DeviceLinkAgentName(address: self.makeAddress("aa"), name: "A")].compactMap { $0 }
                let giver = try DeviceLinkGiver(scanning: receiver.offer, keyStore: giverStore, agentNames: names)
                let identity = try receiver.accept(try giver.seal(for: try giver.verify(try receiver.start())))
                guard await accept(identity) else { throw DeviceLinkError.cancelled }
                return identity
            }
        )

        flow.start()
        await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()
        await eventually { flow.step == .done(address: giverAddress) }

        XCTAssertEqual(try store.loadOrCreateIdentity().address, giverAddress)
        XCTAssertTrue(replaced, "old chats are still stamped")
    }

    @MainActor
    private func makeOfflineAppViewModel() -> AppViewModel {
        AppViewModel(
            storage: UserDefaults(suiteName: "agent-names-\(UUID())") ?? .standard,
            localAgentDefinitions: [],
            historyKeyStore: InMemoryPrivateKeyStore(),
            resolveAgentEndpoint: { _ in throw ConnectOnionRemoteError.agentOffline }
        )
    }

    private func makeAgent(_ name: String, target: String) -> GeneralAgentConfiguration {
        GeneralAgentConfiguration(
            name: name, connectionType: .byAddress, addressConfiguration: AgentAddressConfiguration(agentAddress: target)
        )
    }

    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}

/// Two devices' link flows joined in memory: the receiver's side waits here and the giver's side plays
/// the exchange against it, so no socket opens.
@MainActor
private final class InMemoryLink {
    private var receiver: DeviceLinkReceiver?
    private var accept: (@Sendable (DeviceLinkIdentity) async -> Bool)?
    private var finish: CheckedContinuation<DeviceLinkIdentity, Error>?
    var isWaiting: Bool { finish != nil }

    func receive(
        _ receiver: DeviceLinkReceiver,
        _ accept: @escaping @Sendable (DeviceLinkIdentity) async -> Bool
    ) async throws -> DeviceLinkIdentity {
        try await withCheckedThrowingContinuation { finish in
            self.receiver = receiver
            self.accept = accept
            self.finish = finish
        }
    }

    func give(_ giver: DeviceLinkGiver, _ approve: @escaping @Sendable () async -> Bool) async throws {
        guard let receiver, let accept, let finish else { throw DeviceLinkError.cancelled }
        do {
            let verified = try giver.verify(try receiver.start())
            guard await approve() else { throw DeviceLinkError.cancelled }
            let identity = try receiver.accept(try giver.seal(for: verified))
            guard await accept(identity) else { throw DeviceLinkError.cancelled }
            finish.resume(returning: identity)
        } catch {
            finish.resume(throwing: error)
            throw error
        }
    }
}

/// The Mac card titles approvals with the Kit summary, so these tests check that the Kit keeps
/// the sentences the Mac app used to build itself.
extension ConnectOnionApprovalRequest {
    var kitSummary: String {
        OOApprovalDisclosure.summary(tool: tool, arguments: arguments.objectValue ?? [:])
    }
}
