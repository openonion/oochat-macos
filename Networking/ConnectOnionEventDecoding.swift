import Foundation

/// Stateless decoding of raw protocol dictionaries into native model values.
extension ConnectOnionRemoteAgentClient {
    nonisolated static func eventDedupeKey(
        for event: [String: Any],
        id: String
    ) -> String {
        let type = (event["type"] as? String) ?? "unknown"
        let status = (event["status"] as? String) ?? "none"
        let sequence = Self.intValue(event["seq"]).map(String.init) ?? "none"
        return "\(type):\(id):\(status):\(sequence)"
    }

    nonisolated static func makeExecutionItem(
        from event: [String: Any]
    ) -> ExecutionItem? {
        guard let type = event["type"] as? String else {
            return nil
        }

        switch type {
        case "intent":
            return makeIntentExecutionItem(from: event)
        case "llm_call":
            return makeThinkingExecutionItem(from: event, status: .running)
        case "llm_result":
            return makeThinkingExecutionItem(
                from: event,
                status: executionStatus(from: event["status"])
            )
        case "thinking":
            return makeThinkingExecutionItem(
                from: event,
                status: executionStatus(from: event["status"]),
                includesContent: true
            )
        case "tool_call":
            return makeToolExecutionItem(from: event, status: .running)
        case "tool_result":
            return makeToolExecutionItem(
                from: event,
                status: executionStatus(from: event["status"])
            )
        case "eval":
            return makeEvalExecutionItem(from: event)
        default:
            return nil
        }
    }

    nonisolated private static func makeIntentExecutionItem(
        from event: [String: Any]
    ) -> ExecutionItem? {
        guard let id = event["id"] as? String,
              let statusValue = event["status"] as? String,
              let status = IntentStatus(rawValue: statusValue) else {
            return nil
        }
        return .intent(
            IntentExecutionItem(
                id: id,
                status: status,
                ack: event["ack"] as? String,
                isBuild: event["is_build"] as? Bool
            )
        )
    }

    nonisolated private static func makeThinkingExecutionItem(
        from event: [String: Any],
        status: ExecutionStatus,
        includesContent: Bool = false
    ) -> ExecutionItem? {
        guard let id = event["id"] as? String else {
            return nil
        }
        return .thinking(
            ThinkingExecutionItem(
                id: id,
                status: status,
                model: event["model"] as? String,
                durationMS: doubleValue(event["duration_ms"]),
                usage: makeExecutionUsageSummary(from: event),
                contextPercent: doubleValue(event["context_percent"]),
                kind: includesContent ? event["kind"] as? String : nil,
                content: includesContent ? event["content"] as? String : nil
            )
        )
    }

    nonisolated private static func makeToolExecutionItem(
        from event: [String: Any],
        status: ExecutionStatus
    ) -> ExecutionItem? {
        guard let id = executionID(from: event) else {
            return nil
        }
        return .toolCall(
            ToolCallExecutionItem(
                id: id,
                name: (event["name"] as? String) ?? "tool",
                args: jsonObjectValue(from: event["args"]),
                status: status,
                result: event["result"].flatMap(stringValue),
                timingMS: doubleValue(event["timing_ms"])
            )
        )
    }

    nonisolated private static func makeEvalExecutionItem(
        from event: [String: Any]
    ) -> ExecutionItem? {
        guard let id = event["id"] as? String,
              let statusValue = event["status"] as? String,
              let status = EvalStatus(rawValue: statusValue) else {
            return nil
        }
        return .eval(
            EvalExecutionItem(
                id: id,
                status: status,
                passed: event["passed"] as? Bool,
                summary: event["summary"] as? String,
                expected: event["expected"] as? String,
                evalPath: event["eval_path"] as? String
            )
        )
    }

    nonisolated private static func executionID(from event: [String: Any]) -> String? {
        (event["tool_id"] as? String) ?? (event["id"] as? String)
    }

    nonisolated private static func executionStatus(from value: Any?) -> ExecutionStatus {
        switch value as? String {
        case "running":
            return .running
        case "error":
            return .error
        default:
            return .done
        }
    }

    nonisolated private static func makeExecutionUsageSummary(
        from event: [String: Any]
    ) -> ChatUsageSummary? {
        guard let usage = event["usage"] as? [String: Any] else {
            return nil
        }

        let inputTokens = Self.intValue(usage["input_tokens"])
            ?? Self.intValue(usage["prompt_tokens"])
            ?? 0
        let outputTokens = Self.intValue(usage["output_tokens"])
            ?? Self.intValue(usage["completion_tokens"])
            ?? 0
        let totalTokens = Self.intValue(usage["total_tokens"])
            ?? (inputTokens + outputTokens)

        guard totalTokens > 0 else {
            return nil
        }

        return ChatUsageSummary(
            tokenCount: totalTokens,
            totalCost: Self.doubleValue(usage["cost"]) ?? 0,
            contextPercent: Self.doubleValue(event["context_percent"]) ?? 0
        )
    }

    nonisolated private static func jsonObjectValue(from value: Any?) -> [String: JSONValue] {
        guard let object = value as? [String: Any] else {
            return [:]
        }
        return object.mapValues(Self.jsonValue)
    }

    nonisolated private static func jsonValue(from value: Any) -> JSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as [String: Any]:
            return .object(value.mapValues(Self.jsonValue))
        case let value as [Any]:
            return .array(value.map(Self.jsonValue))
        default:
            return .null
        }
    }

    nonisolated private static func stringValue(from value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    nonisolated static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    nonisolated static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    nonisolated static func validatedAgentImageURL(
        from event: [String: Any]
    ) throws -> String {
        guard let value = event["image"] as? String,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        return value
    }

    nonisolated static func makeGeneratedArtifactPayload(
        from value: Any
    ) throws -> GeneratedArtifactPayload {
        guard let artifact = value as? [String: Any],
              let artifactID = artifact["artifact_id"] as? String,
              let name = artifact["name"] as? String,
              let mimeType = artifact["mime_type"] as? String,
              let sizeBytes = intValue(artifact["size_bytes"]),
              sizeBytes >= 0,
              sizeBytes <= GeneratedArtifactStore.maximumPayloadBytes,
              let sha256 = artifact["sha256"] as? String,
              let encoded = artifact["data_base64"] as? String,
              encoded.utf8.count <= 12 * 1_024 * 1_024,
              let data = Data(base64Encoded: encoded) else {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
        return GeneratedArtifactPayload(
            reference: GeneratedArtifactReference(
                artifactID: artifactID,
                name: name,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                sha256: sha256
            ),
            data: data
        )
    }

    nonisolated static func generatedArtifacts(in session: Any?) -> Any? {
        (session as? [String: Any])?["generated_artifacts"]
    }

    nonisolated static func sessionWithoutArtifactPayloads(
        _ value: Any
    ) -> Any {
        guard var session = value as? [String: Any],
              let artifacts = session["generated_artifacts"] as? [Any] else {
            return value
        }
        session["generated_artifacts"] = artifacts.map { item in
            guard var artifact = item as? [String: Any] else {
                return item
            }
            artifact.removeValue(forKey: "data_base64")
            return artifact
        }
        return session
    }
}
