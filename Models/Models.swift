import Foundation

/// How a saved configuration reaches its agent. Only `byAddress` is live; the
/// legacy case exists so older configurations still decode and can be removed.
nonisolated enum AgentConnectionType: String, Codable, Hashable {
    case byAddress
    /// Decodes configurations created by older builds so they can be removed
    /// without restoring the retired direct-provider execution path.
    case legacyByApi = "byApi"
}

/// A saved agent connection the user manages from Settings.
/// Persisted in `UserDefaults` by `AppViewModel`.
nonisolated struct GeneralAgentConfiguration: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var connectionType: AgentConnectionType
    var addressConfiguration: AgentAddressConfiguration?
    var avatarTextColorHex: String?
    var avatarBackgroundColorHex: String?

    /// Stable identity: normalized 0x address or Direct URL. Used to keep
    /// sessions attached to the same agent even if its local UUID changes.
    var agentIdentity: String? {
        guard let raw = addressConfiguration?.agentAddress else { return nil }
        return ConnectOnionAgentTarget.normalized(raw)
    }
}

/// Connection details for a `byAddress` configuration: either a `0x…` agent
/// address or a Direct URL, normalised by `ConnectOnionAgentTarget`.
nonisolated struct AgentAddressConfiguration: Codable, Hashable {
    var agentAddress: String
}

/// One conversation thread. Sessions are grouped per agent in the sidebar and
/// may mirror a host-side session shared with the hosted web client.
nonisolated struct ChatSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var agentConfigId: UUID
    /// Stable agent identity captured when the session was created. Missing in
    /// older data; used as a fallback anchor when the config UUID no longer
    /// matches a live configuration.
    var agentIdentity: String?
    /// Stable ConnectOnion host session identifier shared by native and web
    /// clients. Older locally-only conversations decode this as `nil`.
    var remoteSessionID: String?
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

/// Who produced a `ChatMessage`.
nonisolated enum MessageRole: String, Codable {
    case user
    case agent
    case system
}

/// Metadata for a file the agent exported, without its bytes. Safe to persist
/// and to render; the payload is fetched separately and verified against
/// `sha256`.
nonisolated struct GeneratedArtifactReference:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    var artifactID: String
    var name: String
    var mimeType: String
    var sizeBytes: Int
    var sha256: String

    var id: String { artifactID }
}

/// An exported file together with its bytes, used only while transferring it
/// into `GeneratedArtifactStore`. Never persisted in a message.
nonisolated struct GeneratedArtifactPayload: Hashable, Sendable {
    var reference: GeneratedArtifactReference
    var data: Data
}

/// A single turn in a conversation, covering both user input and agent output.
/// Optional fields stay `nil` for conversations written by older builds.
nonisolated struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var sessionId: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date = Date()
    var status: MessageStatus = .sent
    var attachments: [ChatAttachmentSummary]?
    var imageURL: String?
    var usage: ChatUsageSummary?
    var replyToMessageID: UUID?
    var artifacts: [GeneratedArtifactReference]?
    var artifactWarnings: [String]?
}

/// Token, cost and context figures reported by the host for one agent turn.
nonisolated struct ChatUsageSummary: Codable, Hashable, Sendable {
    var tokenCount: Int
    var totalCost: Double
    var contextPercent: Double
}

/// Lifecycle of an `ExecutionRun`.
nonisolated enum ExecutionRunStatus: String, Codable, Hashable, Sendable {
    case running
    case done
    case error
}

/// The trace of one agent turn: the ordered execution items the host streamed
/// while answering a single user message.
///
/// `userMessageId` is `nil` for a run recovered without its originating
/// message, which the chat view renders as an unlinked trace.
nonisolated struct ExecutionRun: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sessionId: UUID
    var userMessageId: UUID?
    var items: [ExecutionItem] = []
    var status: ExecutionRunStatus = .running
    var startedAt: Date = Date()
    var endedAt: Date?

    var isDirectAnswerTrace: Bool {
        !items.isEmpty && items.allSatisfy { item in
            guard case .thinking(let thinking) = item else { return false }
            return thinking.kind == nil
        }
    }

    var hasUserVisibleTrace: Bool {
        isDirectAnswerTrace || items.contains { item in
            switch item {
            case .thinking(let thinking):
                return thinking.kind != nil
            case .intent, .toolCall, .approval, .eval:
                return true
            }
        }
    }
}

/// One step inside an `ExecutionRun`. The associated values carry the
/// step-specific payload; `id` is the host-assigned identifier used to
/// deduplicate repeated stream events.
nonisolated enum ExecutionItem: Identifiable, Codable, Hashable, Sendable {
    case intent(IntentExecutionItem)
    case thinking(ThinkingExecutionItem)
    case toolCall(ToolCallExecutionItem)
    case approval(ApprovalExecutionItem)
    case eval(EvalExecutionItem)

    var id: String {
        switch self {
        case .intent(let item):
            return item.id
        case .thinking(let item):
            return item.id
        case .toolCall(let item):
            return item.id
        case .approval(let item):
            return item.id
        case .eval(let item):
            return item.id
        }
    }
}

/// Lifecycle shared by the execution items that can still be in flight.
nonisolated enum ExecutionStatus: String, Codable, Hashable, Sendable {
    case running
    case done
    case error
}

/// The host's opening acknowledgement, shown before any tool runs.
nonisolated struct IntentExecutionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var status: IntentStatus
    var ack: String?
    var isBuild: Bool?
}

/// Whether the host is still parsing the request or has understood it.
nonisolated enum IntentStatus: String, Codable, Hashable, Sendable {
    case analyzing
    case understood
}

/// A model reasoning step. A `nil` `kind` marks a plain direct answer, which
/// the chat view renders as prose instead of a collapsible trace row.
nonisolated struct ThinkingExecutionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var status: ExecutionStatus
    var model: String?
    var durationMS: Double?
    var usage: ChatUsageSummary?
    var contextPercent: Double?
    var kind: String?
    var content: String?
}

/// A single tool invocation with its arguments and result. Presentation is
/// derived from `name` via `ToolCategory`.
nonisolated struct ToolCallExecutionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var args: [String: JSONValue]
    var status: ExecutionStatus
    var result: String?
    var timingMS: Double?
}

/// What a file-mutating tool did to a path.
nonisolated enum FileChangeOperation: String, Codable, Hashable, Sendable {
    case created
    case updated
    case deleted

    var displayName: String { rawValue.capitalized }
}

/// A file mutation lifted out of a tool result so it can be shown as a diff
/// card rather than raw tool output.
nonisolated struct FileChangeSummary: Codable, Hashable, Sendable {
    var operation: FileChangeOperation
    var path: String
    var additions: Int
    var deletions: Int
    var diff: String?
}

/// How dangerous the host considered a tool call needing approval.
nonisolated enum ApprovalRiskLevel: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high

    var displayName: String { rawValue.capitalized }
}

/// What the user decided about an approval request.
nonisolated enum ApprovalRecordDecision: String, Codable, Hashable, Sendable {
    case approvedOnce
    case approvedForSession
    case skipped
    case rejectedAndStopped

    var displayName: String {
        switch self {
        case .approvedOnce: return "Approved once"
        case .approvedForSession: return "Approved for session"
        case .skipped: return "Skipped"
        case .rejectedAndStopped: return "Rejected and stopped"
        }
    }

    var isApproved: Bool {
        self == .approvedOnce || self == .approvedForSession
    }
}

/// A recorded approval prompt and its outcome, kept in the trace so the
/// decision remains auditable after the turn ends.
nonisolated struct ApprovalExecutionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var tool: String
    var target: String?
    var risk: ApprovalRiskLevel
    var decision: ApprovalRecordDecision
}

/// The result of the agent's self-evaluation step for a turn.
nonisolated struct EvalExecutionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var status: EvalStatus
    var passed: Bool?
    var summary: String?
    var expected: String?
    var evalPath: String?
}

/// Whether self-evaluation is still running or has finished.
nonisolated enum EvalStatus: String, Codable, Hashable, Sendable {
    case evaluating
    case done
}

/// A schema-free JSON value, used for tool arguments whose shape depends on
/// the tool. Decoding probes concrete types in order and fails rather than
/// silently dropping an unsupported value.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension ExecutionItem {
    func mergingDisplayFields(from previous: ExecutionItem) -> ExecutionItem {
        switch (self, previous) {
        case (.thinking(var current), .thinking(let existing)):
            current.model = current.model ?? existing.model
            current.durationMS = current.durationMS ?? existing.durationMS
            current.usage = current.usage ?? existing.usage
            current.contextPercent = current.contextPercent ?? existing.contextPercent
            current.kind = current.kind ?? existing.kind
            current.content = current.content ?? existing.content
            return .thinking(current)

        case (.toolCall(var current), .toolCall(let existing)):
            if current.name == "tool" {
                current.name = existing.name
            }
            if current.args.isEmpty {
                current.args = existing.args
            }
            current.result = current.result ?? existing.result
            current.timingMS = current.timingMS ?? existing.timingMS
            return .toolCall(current)

        case (.approval, .approval):
            return self

        case (.intent(var current), .intent(let existing)):
            current.ack = current.ack ?? existing.ack
            current.isBuild = current.isBuild ?? existing.isBuild
            return .intent(current)

        case (.eval(var current), .eval(let existing)):
            current.passed = current.passed ?? existing.passed
            current.summary = current.summary ?? existing.summary
            current.expected = current.expected ?? existing.expected
            current.evalPath = current.evalPath ?? existing.evalPath
            return .eval(current)

        default:
            return self
        }
    }
}

extension ToolCallExecutionItem {
    /// Best-effort upgrade for common file mutation tools. Unknown payloads
    /// deliberately fall back to the generic tool row.
    var fileChangeSummary: FileChangeSummary? {
        let normalizedName = name.lowercased()
        let mutationTerms = [
            "write", "edit", "update", "patch", "create", "delete", "remove",
            "unlink", "rename", "move"
        ]
        guard mutationTerms.contains(where: normalizedName.contains),
              let path = firstStringArgument(
                named: ["path", "file_path", "filepath", "filename", "target"]
              ) else {
            return nil
        }

        let operation: FileChangeOperation
        if ["delete", "remove", "unlink"].contains(where: normalizedName.contains) {
            operation = .deleted
        } else if ["create", "new_file"].contains(where: normalizedName.contains) {
            operation = .created
        } else {
            operation = .updated
        }

        let diff = firstStringArgument(named: ["diff", "patch"])
            ?? result.flatMap(Self.unifiedDiff(from:))
        let counts = Self.diffCounts(diff)
        return FileChangeSummary(
            operation: operation,
            path: path,
            additions: counts.additions,
            deletions: counts.deletions,
            diff: diff
        )
    }

    private func firstStringArgument(named keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = args[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func unifiedDiff(from result: String) -> String? {
        let startsWithHeader = result.hasPrefix("--- ") && result.contains("\n+++ ")
        let embeddedHeader = result.contains("\n--- ") && result.contains("\n+++ ")
        let hasHunk = result.hasPrefix("@@") || result.contains("\n@@")
        return (startsWithHeader || embeddedHeader || hasHunk) ? result : nil
    }

    private static func diffCounts(
        _ diff: String?
    ) -> (additions: Int, deletions: Int) {
        guard let diff else { return (0, 0) }
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                additions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }
        return (additions, deletions)
    }
}

/// Presentation family for an execution tool call. Maps every ConnectOnion
/// built-in tool (docs.connectonion.com/useful-tools) — and any unknown custom
/// tool — onto a small set of consistent thought-chain treatments.
nonisolated enum ToolCategory: String, Hashable, Sendable {
    case shell        // Shell, Terminal, Bash
    case fileRead     // read_file, FileTools read
    case fileWrite    // write / edit / patch (also upgraded to FileChangeCard)
    case web          // WebFetch.fetch, web search
    case email        // Gmail / Outlook: search_emails, send, reply
    case calendar     // Google / Microsoft calendar
    case memory       // Memory: write_memory, search
    case todo         // Todo list
    case generic      // custom / unknown tools

    /// SF Symbol shown beside the tool name in the trace header.
    var icon: String {
        switch self {
        case .shell: return "terminal"
        case .fileRead: return "doc.text"
        case .fileWrite: return "square.and.pencil"
        case .web: return "globe"
        case .email: return "envelope"
        case .calendar: return "calendar"
        case .memory: return "brain"
        case .todo: return "checklist"
        case .generic: return "wrench.and.screwdriver"
        }
    }
}

extension ToolCallExecutionItem {
    /// Classifies the tool by name keywords. Order matters: more specific
    /// families are matched before the generic web/search bucket.
    var category: ToolCategory {
        let name = self.name.lowercased()
        func matches(_ terms: [String]) -> Bool {
            terms.contains { name.contains($0) }
        }

        if matches(["shell", "bash", "terminal", "command", "cmd", "execute", "exec", "run_command"]) {
            return .shell
        }
        if matches(["email", "mail", "gmail", "outlook", "smtp", "imap", "inbox", "reply"]) {
            return .email
        }
        if matches(["calendar", "meeting", "schedule"]) || name.contains("event") {
            return .calendar
        }
        if matches(["memor", "remember", "recall", "knowledge"]) {
            return .memory
        }
        if matches(["todo", "task"]) {
            return .todo
        }
        if matches(["read_file", "readfile", "open_file", "cat"]) || name == "read" {
            return .fileRead
        }
        if matches(["write", "edit", "patch", "diff", "append", "create_file", "delete", "unlink", "rename", "move"]) {
            return .fileWrite
        }
        if matches(["fetch", "web", "http", "url", "scrape", "crawl", "browse", "search"]) {
            return .web
        }
        return .generic
    }

    /// Title-cased tool name for the header ("search_emails" → "Search Emails").
    var displayName: String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        let words = spaced.split(separator: " ")
        guard !words.isEmpty else { return name }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Human-readable secondary label rendered in gray next to the name.
    var subtitle: String? {
        // A model-authored description (shell/bash tools ship one) wins.
        if let described = stringArgument(["description", "summary", "reason"]) {
            return described
        }
        switch category {
        case .shell:
            return shellCommand
        case .fileRead, .fileWrite:
            return fileArgument.map { ($0 as NSString).lastPathComponent }
        case .web:
            return stringArgument(["url", "query", "q", "link", "prompt"])
        case .email:
            return stringArgument(["to", "recipient", "query", "subject", "q"])
        case .calendar:
            return stringArgument(["title", "summary", "query", "event"])
        case .memory:
            return stringArgument(["key", "query", "content", "text"])
        case .todo:
            return stringArgument(["task", "title", "content", "text"])
        case .generic:
            return firstStringArgumentValue()
        }
    }

    /// Reconstructed shell command line for the terminal-style body.
    var shellCommand: String? {
        stringArgument(["command", "cmd", "script", "input"])
    }

    /// Trailing status chip, e.g. "EXIT CODE 0 (0.4s)" for shell tools or
    /// "DONE (0.4s)" otherwise. ConnectOnion emits no structured exit code; the
    /// bash/shell tools instead append "Exit code: N" to the result on failure,
    /// so success implies 0.
    func statusLabel(timing: String?) -> String {
        let base: String
        switch status {
        case .running:
            base = "RUNNING"
        case .error:
            base = category == .shell ? "EXIT CODE \(shellExitCode ?? 1)" : "ERROR"
        case .done:
            base = category == .shell ? "EXIT CODE \(shellExitCode ?? 0)" : "DONE"
        }
        if let timing, !timing.isEmpty {
            return "\(base) (\(timing))"
        }
        return base
    }

    /// Non-zero exit code parsed from the "Exit code: N" line the bash/shell
    /// tools append to their result. Absent on success.
    var shellExitCode: Int? {
        guard let result else { return nil }
        for line in result.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Exit code:") {
                let value = trimmed
                    .dropFirst("Exit code:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private var fileArgument: String? {
        stringArgument(["path", "file_path", "filepath", "filename", "target", "file"])
    }

    private func stringArgument(_ keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = args[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Deterministic fallback: the first string argument in sorted key order.
    private func firstStringArgumentValue() -> String? {
        for key in args.keys.sorted() {
            if case .string(let value)? = args[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// Delivery state of a `ChatMessage`, driving the composer's send affordances.
nonisolated enum MessageStatus: String, Codable {
    case sending
    case queued
    case sent
    case error
}

/// Name and size of a file the user attached, retained for display after the
/// bytes themselves have been sent.
nonisolated struct ChatAttachmentSummary: Codable, Hashable {
    var name: String
    var byteCount: Int
}

/// A file selected or dropped by the user, held in memory until it is sent.
/// `protocolObject` renders it as the data-URL form the host protocol expects.
nonisolated struct ConnectOnionInputFile: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var mimeType: String
    var data: Data

    var byteCount: Int {
        data.count
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    var protocolObject: [String: String] {
        [
            "name": name,
            "data": dataURL
        ]
    }
}

/// Everything needed to resend a message, keeping the text shown to the user
/// separate from the text sent to the agent.
nonisolated struct ChatRetryRequest: Hashable, Sendable {
    let displayContent: String
    let requestContent: String
    let files: [ConnectOnionInputFile]

    var attachmentByteCount: Int {
        files.reduce(0) { $0 + $1.byteCount }
    }
}
