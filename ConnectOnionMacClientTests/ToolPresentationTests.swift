import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

extension ConnectOnionRemoteAgentTests {
    func toolCall(
        name: String,
        args: [String: Any] = [:],
        status: String = "done",
        result: String? = nil,
        timingMS: Double? = nil
    ) throws -> ToolCallExecutionItem {
        var event: [String: Any] = [
            "type": "tool_result",
            "tool_id": "t",
            "name": name,
            "args": args,
            "status": status
        ]
        if let result { event["result"] = result }
        if let timingMS { event["timing_ms"] = NSNumber(value: timingMS) }
        guard case .toolCall(let call) = try XCTUnwrap(
            ConnectOnionRemoteAgentClient.makeExecutionItem(from: event)
        ) else {
            throw XCTSkip("Expected tool call")
        }
        return call
    }

    /// Verifies every built-in tool family maps onto the intended category,
    /// icon, subtitle, and status chip — the behaviour the reference chat shows.
    func testToolPresentationClassifiesBuiltInToolFamilies() throws {
        // Bash: description arg becomes the subtitle, command drives the body,
        // and success renders "EXIT CODE 0".
        let bash = try toolCall(
            name: "bash",
            args: [
                "command": "echo $HOME && ls -la $HOME",
                "description": "Check home directory contents to locate Desktop"
            ],
            result: "/Users/demo\ntotal 1336",
            timingMS: 40
        )
        XCTAssertEqual(bash.category, .shell)
        XCTAssertEqual(bash.category.icon, "terminal")
        XCTAssertEqual(bash.subtitle, "Check home directory contents to locate Desktop")
        XCTAssertEqual(bash.shellCommand, "echo $HOME && ls -la $HOME")
        XCTAssertEqual(bash.statusLabel(timing: "0.0s"), "EXIT CODE 0 (0.0s)")

        // Failed shell parses the appended "Exit code: N" line.
        let failed = try toolCall(
            name: "shell",
            args: ["command": "false"],
            status: "error",
            result: "STDERR:\nboom\n\nExit code: 2"
        )
        XCTAssertEqual(failed.shellExitCode, 2)
        XCTAssertEqual(failed.statusLabel(timing: nil), "EXIT CODE 2")

        // Write (no diff) → fileWrite, filename subtitle, DONE chip.
        let write = try toolCall(
            name: "write",
            args: ["path": "/Users/demo/Desktop/untitled.md", "content": ""],
            result: "Created file"
        )
        XCTAssertEqual(write.category, .fileWrite)
        XCTAssertEqual(write.displayName, "Write")
        XCTAssertEqual(write.subtitle, "untitled.md")
        XCTAssertEqual(write.statusLabel(timing: "0.0s"), "DONE (0.0s)")

        // Each remaining family lands in its bucket.
        XCTAssertEqual(try toolCall(name: "read_file", args: ["path": "a/b/notes.txt"]).category, .fileRead)
        XCTAssertEqual(try toolCall(name: "read_file", args: ["path": "a/b/notes.txt"]).subtitle, "notes.txt")
        XCTAssertEqual(try toolCall(name: "search_emails", args: ["query": "invoices"]).category, .email)
        XCTAssertEqual(try toolCall(name: "read_inbox").category, .email)
        XCTAssertEqual(try toolCall(name: "fetch", args: ["url": "https://x.dev"]).category, .web)
        XCTAssertEqual(try toolCall(name: "create_event", args: ["title": "Sync"]).category, .calendar)
        XCTAssertEqual(try toolCall(name: "write_memory", args: ["key": "k"]).category, .memory)
        XCTAssertEqual(try toolCall(name: "list_memories").category, .memory)
        XCTAssertEqual(try toolCall(name: "add_todo", args: ["task": "ship"]).category, .todo)

        // Unknown custom tool → generic, with a deterministic string subtitle.
        let custom = try toolCall(name: "my_custom_tool", args: ["query": "hello"])
        XCTAssertEqual(custom.category, .generic)
        XCTAssertEqual(custom.category.icon, "wrench.and.screwdriver")
        XCTAssertEqual(custom.subtitle, "hello")
        XCTAssertEqual(custom.displayName, "My Custom Tool")
    }
}
