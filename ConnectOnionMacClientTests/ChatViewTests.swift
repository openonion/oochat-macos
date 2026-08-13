import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

final class ChatViewTests: XCTestCase {
    func testMarkdownNormalizerLeavesPlainAndInvalidImagesUnchanged() {
        XCTAssertEqual(
            MarkdownMessageNormalizer.normalize("Plain **Markdown**"),
            "Plain **Markdown**"
        )
        XCTAssertEqual(
            MarkdownMessageNormalizer.normalize(#"<img alt="Missing source">"#),
            #"<img alt="Missing source">"#
        )
        XCTAssertEqual(
            MarkdownMessageNormalizer.normalize(#"<img src="" alt="Empty source">"#),
            #"<img src="" alt="Empty source">"#
        )
    }

    func testMarkdownNormalizerConvertsLabelsSourcesAndMultipleImages() {
        let content = """
        <IMG SRC='https://example.test/a.png?x=1&amp;y=2' ALT='Folder\\Chart]'>
        <img src="https://example.test/b.png" title="Second">
        <img src="https://example.test/c.png">
        """
        let expected = """
        ![Folder\\\\Chart\\]](https://example.test/a.png?x=1&y=2)
        ![Second](https://example.test/b.png)
        ![Image](https://example.test/c.png)
        """

        XCTAssertEqual(MarkdownMessageNormalizer.normalize(content), expected)
    }

    func testMarkdownMathParserExtractsDisplayMathAndPreservesCodeFences() {
        let content = """
        Before

        $$
        \\frac{a}{b}
        $$

        ```swift
        let price = "$$10"
        ```

        \\[x^2 + y^2 = z^2\\]
        """

        XCTAssertEqual(
            MarkdownMathBlockParser.parse(content),
            [
                .markdown("Before"),
                .displayMath(#"\frac{a}{b}"#),
                .codeBlock(language: "swift", content: "let price = \"$$10\""),
                .displayMath("x^2 + y^2 = z^2")
            ]
        )
    }

    func testMarkdownMathParserExtractsLanguageAndKeepsUnclosedFence() {
        XCTAssertEqual(
            MarkdownMathBlockParser.parse("```python\nprint('ok')\n```"),
            [.codeBlock(language: "python", content: "print('ok')")]
        )
        XCTAssertEqual(
            MarkdownMathBlockParser.parse("Before\n```python\nprint('open')"),
            [.markdown("Before"), .markdown("```python\nprint('open')")]
        )
    }

    func testMarkdownNormalizerWrapsStandaloneUnfencedPython() {
        let source = """
        def calculate_total(prices, discount_percent):
            subtotal = sum(prices)
            return subtotal * (1 - discount_percent / 100)
        """

        let normalized = MarkdownMessageNormalizer.normalize(source)
        XCTAssertEqual(
            normalized,
            """
            ```python
            def calculate_total(prices, discount_percent):
                subtotal = sum(prices)
                return subtotal * (1 - discount_percent / 100)
            ```
            """
        )
        XCTAssertEqual(
            MarkdownMathBlockParser.parse(normalized),
            [
                .codeBlock(
                    language: "python",
                    content: """
                    def calculate_total(prices, discount_percent):
                        subtotal = sum(prices)
                        return subtotal * (1 - discount_percent / 100)
                    """
                )
            ]
        )
    }

    func testMarkdownNormalizerDoesNotWrapProseMixedCodeOrExistingFence() {
        let prose = """
        The corrected function is below.

        def calculate_total(prices):
            return sum(prices)
        """
        let fenced = """
        ```python
        def calculate_total(prices):
            return sum(prices)
        ```
        """

        XCTAssertEqual(MarkdownMessageNormalizer.normalize(prose), prose)
        XCTAssertEqual(MarkdownMessageNormalizer.normalize(fenced), fenced)
    }

    func testMarkdownMathParserKeepsUnclosedFormulaAsMarkdown() {
        XCTAssertEqual(
            MarkdownMathBlockParser.parse("Before\n$$\nx + y"),
            [.markdown("Before"), .markdown("$$\nx + y")]
        )
    }

    func testInlineMathParserAvoidsCodeEscapesAndCurrencyProse() {
        XCTAssertEqual(
            InlineMathParser.parse("Use `$raw$`, pay $20 and CAD $30, then solve $x^2 + y^2$."),
            [
                .text("Use `$raw$`, pay $20 and CAD $30, then solve "),
                .math("x^2 + y^2"),
                .text(".")
            ]
        )
        XCTAssertEqual(
            InlineMathParser.parse(#"Price is \$20"#),
            [.text(#"Price is \$20"#)]
        )
    }

    func testInlineMathListParserRetainsBulletsNumbersAndMarkdown() {
        let content = """
        Introduction

        - **Discount:** $d = s \\times p / 100$
        - Price stays as $20 in prose
        1. Total is $t = s - d$

        Conclusion
        """

        XCTAssertEqual(
            InlineMathListParser.parse(content),
            [
                .markdown("Introduction"),
                .list([
                    InlineMathListItem(
                        marker: "-",
                        content: "**Discount:** $d = s \\times p / 100$",
                        indentation: 0
                    ),
                    InlineMathListItem(
                        marker: "-",
                        content: "Price stays as $20 in prose",
                        indentation: 0
                    ),
                    InlineMathListItem(
                        marker: "1.",
                        content: "Total is $t = s - d$",
                        indentation: 0
                    )
                ]),
                .markdown("Conclusion")
            ]
        )
    }

    @MainActor
    func testMarkdownMessageViewRendersMathAndCopyableCodeBlock() {
        renderView(
            MarkdownMessageView(
                content: """
                Inline formula: $E = mc^2$.

                $$
                \\int_0^1 x^2 \\, dx = \\frac{1}{3}
                $$

                ```swift
                let answer = 42
                ```
                """,
                fontSize: 14
            )
            .frame(width: 620)
        )
    }

    @MainActor
    func testBundledJetBrainsMonoFontsAreAvailable() {
        let fontNames = [
            "JetBrainsMono-Regular",
            "JetBrainsMono-Medium",
            "JetBrainsMono-SemiBold"
        ]

        for fontName in fontNames {
            XCTAssertNotNil(
                NSFont(name: fontName, size: 13),
                "Expected bundled font \(fontName) to be registered"
            )
        }
    }

    @MainActor
    func testChatViewRendersWelcomeState() async {
        let viewModel = makeViewModel()

        render(viewModel)
    }

    @MainActor
    func testChatViewRendersStopAndStoppingStates() async {
        let viewModel = makeViewModel()
        viewModel.service.isAgentRequestActive = true

        XCTAssertTrue(viewModel.canInterruptAgent)
        render(viewModel)

        viewModel.service.isInterruptRequested = true
        XCTAssertFalse(viewModel.canSendMessage)
        render(viewModel)
    }

    @MainActor
    func testChatViewRendersMessagesAttachmentsUsageAndExecutionFlows() async {
        let sessionID = UUID()
        var userMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Inspect the workspace",
            attachments: [
                ChatAttachmentSummary(name: "notes.txt", byteCount: 1_024)
            ]
        )
        userMessage.status = .queued
        let agentMessage = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "The workspace is ready.",
            usage: usage(tokens: 12_500, cost: 0.025, contextPercent: 42)
        )
        let systemMessage = ChatMessage(
            sessionId: sessionID,
            role: .system,
            content: "Connected"
        )
        var detailedRun = ExecutionRun(
            sessionId: sessionID,
            userMessageId: userMessage.id
        )
        detailedRun.items = executionItems()
        var directRun = visibleRun(
            sessionID: sessionID,
            userMessageID: userMessage.id,
            itemID: "direct"
        )
        directRun.startedAt = Date().addingTimeInterval(-4)
        let unlinkedRun = visibleRun(
            sessionID: sessionID,
            userMessageID: nil,
            itemID: "unlinked"
        )
        let viewModel = makeViewModel(
            sessionID: sessionID,
            messages: [systemMessage, userMessage, agentMessage],
            executionRuns: [detailedRun, directRun, unlinkedRun]
        )
        viewModel.pendingAttachments = [
            ConnectOnionInputFile(
                name: "draft.md",
                mimeType: "text/markdown",
                data: Data("draft".utf8)
            )
        ]
        viewModel.attachmentError = "One file could not be attached"
        viewModel.recoveryStatus = "Recovering hosted session"

        render(viewModel)
    }

    @MainActor
    func testGeneratedArtifactCardRendersAvailableAndMissingStates() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let store = GeneratedArtifactStore(rootDirectory: cacheDirectory)
        let reference = GeneratedArtifactReference(
            artifactID: UUID().uuidString,
            name: "report.txt",
            mimeType: "text/plain",
            sizeBytes: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb924"
                + "27ae41e4649b934ca495991b7852b855"
        )
        try store.record(
            GeneratedArtifactPayload(reference: reference, data: Data())
        )
        var message = ChatMessage(
            sessionId: UUID(),
            role: .agent,
            content: "The report is ready."
        )
        message.artifacts = [reference]
        message.artifactWarnings = ["A second file failed its integrity check."]
        let viewModel = makeViewModel(messages: [message])

        renderView(
            MessageView(
                message: message,
                fontSize: 15,
                agentConfiguration: viewModel.configuration,
                conversationWidth: 720,
                canRetry: true,
                artifactStore: store,
                onRetry: {}
            )
            .environment(\.colorScheme, .light)
        )

        store.removeArtifacts([reference])
        renderView(
            MessageView(
                message: message,
                fontSize: 15,
                agentConfiguration: viewModel.configuration,
                conversationWidth: 360,
                canRetry: false,
                artifactStore: store,
                onRetry: {}
            )
            .environment(\.colorScheme, .dark),
            width: 420
        )
    }

    @MainActor
    func testChatViewRendersSpecializedExecutionCardsAndMessageStates() {
        let sessionID = UUID()
        var sendingMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Inspect the project files"
        )
        sendingMessage.status = .sending
        var failedMessage = ChatMessage(
            sessionId: sessionID,
            role: .user,
            content: "Retry this request"
        )
        failedMessage.status = .error
        var imageMessage = ChatMessage(
            sessionId: sessionID,
            role: .agent,
            content: "The browser produced this screenshot."
        )
        imageMessage.imageURL = "file:///definitely-missing-screenshot.png"
        let systemMessage = ChatMessage(
            sessionId: sessionID,
            role: .system,
            content: "Hosted session recovered"
        )
        var run = ExecutionRun(
            sessionId: sessionID,
            userMessageId: sendingMessage.id
        )
        run.items = specializedExecutionItems()
        run.status = .done
        run.startedAt = Date().addingTimeInterval(-12)
        run.endedAt = Date()
        let viewModel = makeViewModel(
            sessionID: sessionID,
            messages: [
                sendingMessage,
                failedMessage,
                imageMessage,
                systemMessage
            ],
            executionRuns: [run],
            tools: ["read_file", "write_file"]
        )

        render(viewModel)
    }

    @MainActor
    func testExpandedExecutionRowsRenderGenericToolDetails() {
        let genericToolItem = ExecutionItem.toolCall(
            ToolCallExecutionItem(
                id: "generic-expanded",
                name: "inspect_environment",
                args: [
                    "enabled": .bool(true),
                    "limit": .number(3),
                    "metadata": .object(["owner": .string("tester")]),
                    "paths": .array([.string("README.md"), .null])
                ],
                status: .done,
                result: "Inspection complete",
                timingMS: 40
            )
        )
        renderView(
            ExecutionItemRow(
                item: genericToolItem,
                messageFontSize: 15,
                completionSummary: nil,
                isExpanded: true
            )
        )

        renderView(
            ExecutionItemRow(
                item: .thinking(
                    ThinkingExecutionItem(
                        id: "expanded-plan",
                        status: .done,
                        kind: "plan",
                        content: "Inspect, update, and verify."
                    )
                ),
                messageFontSize: 15,
                completionSummary: nil,
                isExpanded: true
            )
        )

        renderView(
            ExecutionItemRow(
                item: .eval(
                    EvalExecutionItem(
                        id: "expanded-eval",
                        status: .done,
                        passed: true,
                        summary: "Verified",
                        expected: "All checks pass",
                        evalPath: nil
                    )
                ),
                messageFontSize: 15,
                completionSummary: nil,
                isExpanded: true
            )
        )
    }

    @MainActor
    func testExpandedWelcomeAndApprovalViewsRenderHiddenContent() {
        let welcomeViewModel = makeViewModel(
            tools: ["read_file", "write_file", "web_fetch"]
        )
        renderView(
            WelcomeHomeView(
                configuration: welcomeViewModel.configuration,
                isConnected: true,
                connectionSnapshot: welcomeViewModel.connectionSnapshot,
                areToolsExpanded: true,
                onSelectPrompt: { _ in }
            )
        )

        let approvalViewModel = makeStartedViewModel()
        approvalViewModel.pendingInteraction = .approval(
            ConnectOnionApprovalRequest(
                id: "send-mail-approval",
                tool: "send_mail",
                arguments: .object([
                    "subject": .string("Coverage report"),
                    "to": .string("team@example.test")
                ]),
                description: "Send the coverage report to the team",
                batchRemaining: [.object(["tool": .string("archive_report")])]
            )
        )
        let approvalCard = HostedInteractionCard(
            viewModel: approvalViewModel,
            conversationWidth: 720,
            showsApprovalDetails: true,
            showsApprovalOptions: false
        )
        renderView(approvalCard)
        renderView(
            approvalCard.approvalOptionsPopover,
            width: 340,
            height: 220
        )

        approvalViewModel.pendingInteraction = .approval(
            ConnectOnionApprovalRequest(
                id: "custom-approval",
                tool: "custom_action",
                arguments: .object(["value": .string("example")]),
                description: nil,
                batchRemaining: []
            )
        )
        renderView(
            HostedInteractionCard(
                viewModel: approvalViewModel,
                conversationWidth: 720,
                showsApprovalDetails: true
            )
        )
    }

    @MainActor
    func testChatViewRendersDropTargetAndHandlesFontShortcuts() {
        let viewModel = makeViewModel()
        render(viewModel, isFileDropTargeted: true)

        let chatView = ChatView(
            viewModel: viewModel,
            conversationWidth: 720
        )
        let plainEvent = keyEvent(characters: "a", modifiers: [])
        let unknownCommand = keyEvent(characters: "x", modifiers: [.command])

        XCTAssertTrue(chatView.handleKeyDown(plainEvent) === plainEvent)
        XCTAssertNil(
            chatView.handleKeyDown(
                keyEvent(characters: "=", modifiers: [.command])
            )
        )
        XCTAssertNil(
            chatView.handleKeyDown(
                keyEvent(characters: "-", modifiers: [.command])
            )
        )
        XCTAssertNil(
            chatView.handleKeyDown(
                keyEvent(characters: "0", modifiers: [.command])
            )
        )
        XCTAssertTrue(chatView.handleKeyDown(unknownCommand) === unknownCommand)
    }

    @MainActor
    func testChatViewRendersDisconnectedWelcomeAndSparseInteractions() {
        let welcomeViewModel = makeViewModel(tools: [])
        welcomeViewModel.appViewModel.connectedConfigurationIds.removeAll()
        welcomeViewModel.appViewModel.agentConnectionSnapshots.removeAll()
        render(welcomeViewModel)

        let interactionViewModel = makeStartedViewModel()
        interactionViewModel.interactionError = "The hosted agent rejected the response"
        interactionViewModel.pendingInteraction = .askUser(
            ConnectOnionAskUserRequest(
                id: "free-text",
                question: "Provide more context",
                options: [],
                multiSelect: false,
                fields: []
            )
        )
        render(interactionViewModel)

        interactionViewModel.pendingInteraction = .onboarding(
            ConnectOnionOnboardingRequest(
                id: "payment-only",
                methods: ["payment"],
                paymentAmount: nil,
                paymentAddress: nil
            )
        )
        render(interactionViewModel)
    }

}
