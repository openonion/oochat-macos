import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

extension ChatViewTests {
    @MainActor
    func testChatViewRendersAskUserInteraction() async {
        let viewModel = makeStartedViewModel()
        viewModel.pendingInteraction = .askUser(
            ConnectOnionAskUserRequest(
                id: "ask",
                question: "How should the task continue?",
                options: ["Use tests", "Use previews"],
                multiSelect: true,
                fields: [
                    ConnectOnionAskUserField(
                        name: "username",
                        label: "Username",
                        type: "text"
                    ),
                    ConnectOnionAskUserField(
                        name: "secret",
                        label: "Secret",
                        type: "password"
                    )
                ]
            )
        )

        render(viewModel)
    }

    @MainActor
    func testChatViewRendersApprovalInteraction() async {
        let viewModel = makeStartedViewModel()
        viewModel.pendingInteraction = .approval(
            ConnectOnionApprovalRequest(
                id: "approval",
                tool: "write",
                arguments: .object(["path": .string("README.md")]),
                description: "Update the project documentation",
                batchRemaining: [.object(["tool": .string("test")])]
            )
        )

        render(viewModel)
    }

    @MainActor
    func testFileMutationBuildsStructuredDiffPresentation() {
        let item = ToolCallExecutionItem(
            id: "write-1",
            name: "write_file",
            args: [
                "path": .string("/workspace/Sources/App.swift"),
                "diff": .string(
                    """
                    --- a/Sources/App.swift
                    +++ b/Sources/App.swift
                    @@ -1,2 +1,2 @@
                    -let title = "Old"
                    +let title = "New"
                    """
                )
            ],
            status: .done,
            result: "Updated file",
            timingMS: 250
        )

        let change = item.fileChangeSummary
        XCTAssertEqual(change?.operation, .updated)
        XCTAssertEqual(change?.path, "/workspace/Sources/App.swift")
        XCTAssertEqual(change?.additions, 1)
        XCTAssertEqual(change?.deletions, 1)
        XCTAssertNotNil(change?.diff)
    }

    @MainActor
    func testNonFileToolFallsBackToGenericPresentation() {
        let item = ToolCallExecutionItem(
            id: "status-1",
            name: "get_system_info",
            args: [:],
            status: .done,
            result: "macOS",
            timingMS: 5
        )

        XCTAssertNil(item.fileChangeSummary)
    }

    func testCollapsedTraceKeepsOnlyFinalLLMMetadataBetweenToolCalls() {
        func meta(_ id: String) -> ExecutionItem {
            .thinking(ThinkingExecutionItem(id: id, status: .done))
        }
        func tool(_ id: String) -> ExecutionItem {
            .toolCall(ToolCallExecutionItem(id: id, name: "grep", args: [:], status: .done))
        }

        let items: [ExecutionItem] = [
            .thinking(ThinkingExecutionItem(id: "ack", status: .done, kind: "intent", content: "Got it.")),
            meta("m1"), tool("t1"),
            meta("m2"), tool("t2"),
            meta("m3"),  // final metadata — the only one that should survive
            .eval(EvalExecutionItem(id: "e1", status: .done, passed: true))
        ]

        let collapsed = ChatViewPresentation.collapsedTraceItems(items).map(\.id)

        // Intent, both tools, the final metadata, and eval remain — in order —
        // while the intermediate m1/m2 metadata rows are dropped.
        XCTAssertEqual(collapsed, ["ack", "t1", "t2", "m3", "e1"])
    }

    func testCollapsedTracePreservesToolOnlyRuns() {
        let items: [ExecutionItem] = [
            .toolCall(ToolCallExecutionItem(id: "t1", name: "open", args: [:], status: .done)),
            .toolCall(ToolCallExecutionItem(id: "t2", name: "close", args: [:], status: .done))
        ]
        XCTAssertEqual(
            ChatViewPresentation.collapsedTraceItems(items).map(\.id),
            ["t1", "t2"]
        )
    }

    @MainActor
    func testApprovalPresentationClassifiesRiskAndTarget() {
        let request = ConnectOnionApprovalRequest(
            id: "delete-1",
            tool: "delete_file",
            arguments: .object(["path": .string("/workspace/secret.txt")]),
            description: nil,
            batchRemaining: []
        )

        XCTAssertEqual(request.riskLevel, .high)
        XCTAssertEqual(request.targetSummary, "/workspace/secret.txt")
        XCTAssertEqual(request.plainEnglishExplanation, "Delete secret.txt.")
    }

    @MainActor
    func testApprovalPresentationExplainsFileWritesAndShellCommands() {
        let write = ConnectOnionApprovalRequest(
            id: "write-explanation",
            tool: "write",
            arguments: .object([
                "path": .string("~/Desktop/hi.md"),
                "content": .string("hi")
            ]),
            description: nil,
            batchRemaining: []
        )
        XCTAssertEqual(
            write.plainEnglishExplanation,
            "Create or replace hi.md with the content supplied by the agent."
        )

        let command = ConnectOnionApprovalRequest(
            id: "command-explanation",
            tool: "run_command",
            arguments: .object(["command": .string("git status --short")]),
            description: nil,
            batchRemaining: []
        )
        XCTAssertEqual(command.commandText, "git status --short")
        XCTAssertEqual(
            command.plainEnglishExplanation,
            "Run a Git status operation in the repository."
        )
    }

    @MainActor
    func testOnlyApprovalInteractionsAreRoutedToComposerArea() {
        let approval = ConnectOnionApprovalRequest(
            id: "composer-approval",
            tool: "write",
            arguments: .object(["path": .string("notes.md")]),
            description: nil,
            batchRemaining: []
        )

        XCTAssertEqual(
            ChatViewPresentation.approvalRequest(from: .approval(approval)),
            approval
        )
        XCTAssertNil(
            ChatViewPresentation.approvalRequest(
                from: .planReview(
                    ConnectOnionPlanReviewRequest(id: "plan", content: "Review")
                )
            )
        )
        XCTAssertNil(ChatViewPresentation.approvalRequest(from: nil))
    }

    @MainActor
    func testApprovalDecisionIsRetainedInExecutionTrace() {
        let viewModel = makeStartedViewModel()
        viewModel.pendingInteraction = .approval(
            ConnectOnionApprovalRequest(
                id: "approval-record",
                tool: "write_file",
                arguments: .object(["path": .string("README.md")]),
                description: nil,
                batchRemaining: []
            )
        )

        viewModel.submitApproval(.approveOnce)

        let approvalItems = viewModel.executionRuns
            .flatMap(\.items)
            .compactMap { item -> ApprovalExecutionItem? in
                guard case .approval(let approval) = item else { return nil }
                return approval
            }
        XCTAssertEqual(approvalItems.count, 1)
        XCTAssertEqual(approvalItems.first?.decision, .approvedOnce)
        XCTAssertEqual(approvalItems.first?.target, "README.md")
        XCTAssertNil(viewModel.pendingInteraction)
    }

    @MainActor
    func testChatViewRendersPlanAndCheckpointInteractions() async {
        let viewModel = makeStartedViewModel()
        viewModel.pendingInteraction = .planReview(
            ConnectOnionPlanReviewRequest(
                id: "plan",
                content: "1. Inspect the code\n2. Add tests"
            )
        )
        render(viewModel)

        viewModel.pendingInteraction = .ulwCheckpoint(
            ConnectOnionULWCheckpointRequest(
                id: "checkpoint",
                turnsUsed: 10,
                maxTurns: 10
            )
        )
        render(viewModel)
    }

    @MainActor
    func testChatViewRendersOnboardingInteraction() async {
        let viewModel = makeStartedViewModel()
        viewModel.pendingInteraction = .onboarding(
            ConnectOnionOnboardingRequest(
                id: "onboarding",
                methods: ["invite_code", "payment"],
                paymentAmount: 2.50,
                paymentAddress: "0x1234"
            )
        )

        render(viewModel)
    }

    @MainActor
    func testConversationStartsOnlyAfterNonSystemMessage() async {
        let sessionID = UUID()
        let systemMessage = ChatMessage(
            sessionId: sessionID,
            role: .system,
            content: "Connected"
        )
        let userMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Hello"
        )

        XCTAssertFalse(ChatViewPresentation.hasStartedConversation([]))
        XCTAssertFalse(ChatViewPresentation.hasStartedConversation([systemMessage]))
        XCTAssertTrue(
            ChatViewPresentation.hasStartedConversation([systemMessage, userMessage])
        )
    }

    @MainActor
    func testHistoricalChatTargetsItsLastUserMessage() async {
        let sessionID = UUID()
        let firstUserMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "First question"
        )
        let agentMessage = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "First answer"
        )
        let lastUserMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Latest question"
        )
        let finalAgentMessage = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "Latest answer"
        )

        XCTAssertEqual(
            ChatViewPresentation.lastUserMessageID(
                in: [firstUserMessage, agentMessage, lastUserMessage, finalAgentMessage]
            ),
            lastUserMessage.id
        )
        XCTAssertNil(ChatViewPresentation.lastUserMessageID(in: [agentMessage]))
    }

    @MainActor
    func testExecutionRunsAreLinkedOnlyToUserMessages() async {
        let sessionID = UUID()
        let userMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Run a tool"
        )
        let agentMessage = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "Done"
        )
        let linkedRun = visibleRun(
            sessionID: sessionID,
            userMessageID: userMessage.id,
            itemID: "linked"
        )

        XCTAssertEqual(
            ChatViewPresentation.executionRuns(
                for: userMessage,
                from: [linkedRun]
            ).map(\.id),
            [linkedRun.id]
        )
        XCTAssertTrue(
            ChatViewPresentation.executionRuns(
                for: agentMessage,
                from: [linkedRun]
            ).isEmpty
        )
    }

    @MainActor
    func testExecutionRunsHideEmptyAndUnrelatedTraces() async {
        let sessionID = UUID()
        let message = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Explain"
        )
        let visible = visibleRun(
            sessionID: sessionID,
            userMessageID: message.id,
            itemID: "visible"
        )
        let unrelated = visibleRun(
            sessionID: sessionID,
            userMessageID: UUID(),
            itemID: "unrelated"
        )
        let empty = ExecutionRun(
            sessionId: sessionID,
            userMessageId: message.id
        )

        let result = ChatViewPresentation.executionRuns(
            for: message,
            from: [empty, unrelated, visible]
        )

        XCTAssertEqual(result.map(\.id), [visible.id])
    }

}
