import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

extension ChatViewTests {
    @MainActor
    func testUnlinkedRunsIncludeOnlyUserVisibleTraces() async {
        let sessionID = UUID()
        let unlinked = visibleRun(
            sessionID: sessionID,
            userMessageID: nil,
            itemID: "unlinked"
        )
        let linked = visibleRun(
            sessionID: sessionID,
            userMessageID: UUID(),
            itemID: "linked"
        )
        let empty = ExecutionRun(sessionId: sessionID, userMessageId: nil)

        let result = ChatViewPresentation.unlinkedExecutionRuns(
            from: [empty, linked, unlinked]
        )

        XCTAssertEqual(result.map(\.id), [unlinked.id])
    }

    @MainActor
    func testUsageFormatterAbbreviatesTokenCounts() async {
        XCTAssertEqual(
            ChatUsageFormatter.tokenText(for: usage(tokens: 999)),
            "999 tok"
        )
        XCTAssertEqual(
            ChatUsageFormatter.tokenText(for: usage(tokens: 1_500)),
            "1.5k tok"
        )
        XCTAssertEqual(
            ChatUsageFormatter.tokenText(for: usage(tokens: 1_250_000)),
            "1.2M tok"
        )
    }

    @MainActor
    func testUsageFormatterHandlesCostPrecisionAndContextBounds() async {
        XCTAssertEqual(
            ChatUsageFormatter.costText(for: usage(cost: 0.005)),
            "$0.0050"
        )
        XCTAssertEqual(
            ChatUsageFormatter.costText(for: usage(cost: 0.12)),
            "$0.12"
        )
        XCTAssertEqual(
            ChatUsageFormatter.contextText(for: usage(contextPercent: -10)),
            "0% ctx"
        )
        XCTAssertEqual(
            ChatUsageFormatter.contextText(for: usage(contextPercent: 38.6)),
            "39% ctx"
        )
        XCTAssertEqual(
            ChatUsageFormatter.contextText(for: usage(contextPercent: 120)),
            "100% ctx"
        )
    }

    @MainActor
    func visibleRun(
        sessionID: UUID,
        userMessageID: UUID?,
        itemID: String
    ) -> ExecutionRun {
        var run = ExecutionRun(
            sessionId: sessionID,
            userMessageId: userMessageID
        )
        run.items = [
            .thinking(
                ThinkingExecutionItem(
                    id: itemID,
                    status: .done,
                    model: "test-model"
                )
            )
        ]
        return run
    }

    @MainActor
    func usage(
        tokens: Int = 0,
        cost: Double = 0,
        contextPercent: Double = 0
    ) -> ChatUsageSummary {
        ChatUsageSummary(
            tokenCount: tokens,
            totalCost: cost,
            contextPercent: contextPercent
        )
    }

    @MainActor
    func makeStartedViewModel() -> ChatViewModel {
        let sessionID = UUID()
        return makeViewModel(
            sessionID: sessionID,
            messages: [
                ChatMessage(
                    sessionId: sessionID,
                    role: .user,
                    content: "Continue"
                )
            ]
        )
    }

    @MainActor
    func makeViewModel(
        sessionID: UUID = UUID(),
        messages: [ChatMessage] = [],
        executionRuns: [ExecutionRun] = [],
        tools: [String] = ["read_file", "grep", "edit"]
    ) -> ChatViewModel {
        let suiteName = "ChatViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        let appViewModel = AppViewModel(storage: storage)
        let configuration = GeneralAgentConfiguration(
            name: "View Test Agent",
            connectionType: .byAddress,
            addressConfiguration: nil,
            avatarTextColorHex: "#FFFFFF",
            avatarBackgroundColorHex: "#123456"
        )
        let session = ChatSession(agentConfigId: configuration.id, title: "Chat")
        var remappedMessages = messages
        for index in remappedMessages.indices {
            remappedMessages[index].sessionId = session.id
        }
        var remappedRuns = executionRuns
        for index in remappedRuns.indices {
            remappedRuns[index].sessionId = session.id
        }
        appViewModel.configurations = [configuration]
        appViewModel.sessions = [session]
        appViewModel.messages = remappedMessages
        appViewModel.setExecutionRuns(remappedRuns, for: session.id)
        appViewModel.connectedConfigurationIds.insert(configuration.id)
        appViewModel.agentConnectionSnapshots[configuration.id] = AgentConnectionSnapshot(
            state: .online,
            route: .direct,
            remoteName: "View Test Agent",
            tools: tools,
            detail: "Direct endpoint",
            model: "co/gemini-2.5-pro",
            trust: "careful",
            version: "1.2.1"
        )
        return ChatViewModel(
            session: session,
            configuration: configuration,
            service: ConnectOnionService(conversationID: session.id),
            appViewModel: appViewModel
        )
    }

    @MainActor
    func executionItems() -> [ExecutionItem] {
        [
            .intent(
                IntentExecutionItem(
                    id: "intent",
                    status: .understood,
                    ack: "I will inspect the workspace.",
                    isBuild: false
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "model",
                    status: .done,
                    model: "test-model",
                    durationMS: 1_250,
                    usage: usage(tokens: 1_500, cost: 0.005),
                    contextPercent: 25
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "plan",
                    status: .done,
                    kind: "plan",
                    content: "Inspect, edit, and verify."
                )
            ),
            .toolCall(
                ToolCallExecutionItem(
                    id: "tool",
                    name: "read_file",
                    args: ["path": .string("README.md")],
                    status: .done,
                    result: "Documentation",
                    timingMS: 75
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "reflect",
                    status: .done,
                    kind: "reflect",
                    content: "The result is complete."
                )
            ),
            .eval(
                EvalExecutionItem(
                    id: "eval",
                    status: .done,
                    passed: true,
                    summary: "Verified",
                    expected: "Tests pass",
                    evalPath: nil
                )
            )
        ]
    }

    @MainActor
    func specializedExecutionItems() -> [ExecutionItem] {
        let diff = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,3 @@
        -let oldValue = true
        +let newValue = true
         let unchanged = true

        """

        return [
            .intent(
                IntentExecutionItem(
                    id: "empty-intent",
                    status: .analyzing,
                    ack: nil,
                    isBuild: nil
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "running-thinking",
                    status: .running,
                    model: nil
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "failed-thinking",
                    status: .error,
                    model: nil
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "large-usage",
                    status: .done,
                    model: "co/test-model",
                    durationMS: 20,
                    usage: usage(tokens: 1_250_000, cost: 0.25),
                    contextPercent: 90
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "failed-plan",
                    status: .error,
                    kind: "plan",
                    content: "The plan could not be completed."
                )
            ),
            .thinking(
                ThinkingExecutionItem(
                    id: "running-reflection",
                    status: .running,
                    kind: "reflect",
                    content: ""
                )
            ),
            .toolCall(
                ToolCallExecutionItem(
                    id: "updated-file",
                    name: "write_file",
                    args: [
                        "path": .string("/workspace/Sources/App.swift"),
                        "diff": .string(diff)
                    ],
                    status: .done,
                    result: "Updated",
                    timingMS: 250
                )
            ),
            .toolCall(
                ToolCallExecutionItem(
                    id: "created-file",
                    name: "create_file",
                    args: ["path": .string("/workspace/new.txt")],
                    status: .running,
                    result: nil,
                    timingMS: 25
                )
            ),
            .toolCall(
                ToolCallExecutionItem(
                    id: "deleted-file",
                    name: "delete_file",
                    args: ["path": .string("/workspace/old.txt")],
                    status: .error,
                    result: nil,
                    timingMS: 20_000
                )
            ),
            .approval(
                ApprovalExecutionItem(
                    id: "approved",
                    tool: "write_file",
                    target: "/workspace/new.txt",
                    risk: .medium,
                    decision: .approvedForSession
                )
            ),
            .approval(
                ApprovalExecutionItem(
                    id: "rejected",
                    tool: "shell_command",
                    target: nil,
                    risk: .high,
                    decision: .rejectedAndStopped
                )
            ),
            .eval(
                EvalExecutionItem(
                    id: "evaluating",
                    status: .evaluating,
                    passed: nil,
                    summary: nil,
                    expected: nil,
                    evalPath: nil
                )
            ),
            .eval(
                EvalExecutionItem(
                    id: "failed-eval",
                    status: .done,
                    passed: false,
                    summary: nil,
                    expected: "The generated files pass validation",
                    evalPath: "evals/result.json"
                )
            )
        ]
    }

    @MainActor
    func render(
        _ viewModel: ChatViewModel,
        isFileDropTargeted: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        renderView(
            ChatView(
                viewModel: viewModel,
                conversationWidth: 720,
                isFileDropTargeted: isFileDropTargeted
            ),
            file: file,
            line: line
        )
    }

    @MainActor
    func renderView<Content: View>(
        _ view: Content,
        width: CGFloat = 900,
        height: CGFloat = 700,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: view.frame(width: width, height: height)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }

    @MainActor
    func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ) else {
            preconditionFailure("Failed to create keyboard event")
        }
        return event
    }
}
