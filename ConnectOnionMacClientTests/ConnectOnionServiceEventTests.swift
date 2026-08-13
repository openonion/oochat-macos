import Combine
import CryptoKit
import XCTest
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
        case .modeChanged(let value):
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
