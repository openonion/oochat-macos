import ConnectOnionKit
import CryptoKit
import Foundation

/// Turns a hosted session's trace and live llm_result events into usage records. Stateless, so it lives
/// outside the actor's file.
extension ConnectOnionRemoteAgentClient {
    nonisolated static func makeUsageSummary(
        from payload: [String: Any]
    ) -> ChatUsageSummary? {
        guard let session = payload["session"] as? [String: Any],
              let trace = session["trace"] as? [[String: Any]] else {
            return nil
        }

        var latestTokenCount = 0
        var totalCost = 0.0
        var latestContextPercent: Double?

        for entry in trace where entry["type"] as? String == "llm_result" {
            if let usage = entry["usage"] as? [String: Any] {
                let inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
                let outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                latestTokenCount = inputTokens + outputTokens
                totalCost += (usage["cost"] as? NSNumber)?.doubleValue ?? 0
            }

            if let contextPercent = (entry["context_percent"] as? NSNumber)?.doubleValue {
                latestContextPercent = contextPercent
            }
        }

        guard latestTokenCount > 0, let latestContextPercent else {
            return nil
        }

        return ChatUsageSummary(
            tokenCount: latestTokenCount,
            totalCost: totalCost,
            contextPercent: latestContextPercent
        )
    }

    nonisolated static func makeUsageRecords(
        from payload: [String: Any],
        agentAddress: String,
        remoteSessionID: String,
        fallbackModel: String?,
        now: Date = Date()
    ) -> [LLMUsageRecord] {
        guard let session = payload["session"] as? [String: Any],
              let trace = session["trace"] as? [[String: Any]] else {
            return []
        }

        var callModels: [String: String] = [:]
        var latestCallModel: String?
        var records: [LLMUsageRecord] = []

        for (index, entry) in trace.enumerated() {
            let type = entry["type"] as? String
            if type == "llm_call" {
                if let model = normalizedModel(entry["model"] as? String) {
                    latestCallModel = model
                    if let callID = usageCallID(from: entry) {
                        callModels[callID] = model
                    }
                }
                continue
            }

            guard type == "llm_result" else { continue }
            let callID = usageCallID(from: entry)
            let model = normalizedModel(entry["model"] as? String)
                ?? callID.flatMap { callModels[$0] }
                ?? latestCallModel
                ?? normalizedModel(fallbackModel)
                ?? "Unknown model"
            let stableCallID = callID ?? fallbackTraceCallID(
                entry: entry,
                index: index
            )
            records.append(
                makeUsageRecord(
                    from: entry,
                    context: ConnectOnionUsageCallContext(
                        agentAddress: agentAddress,
                        remoteSessionID: remoteSessionID,
                        callID: stableCallID,
                        model: model,
                        now: now
                    )
                )
            )
        }

        return records
    }

    nonisolated static func makeLiveUsageRecord(
        from event: [String: Any],
        agentAddress: String,
        remoteSessionID: String,
        fallbackModel: String?,
        now: Date = Date()
    ) -> LLMUsageRecord? {
        guard event["type"] as? String == "llm_result",
              let callID = usageCallID(from: event) else {
            return nil
        }
        return makeUsageRecord(
            from: event,
            context: ConnectOnionUsageCallContext(
                agentAddress: agentAddress,
                remoteSessionID: remoteSessionID,
                callID: callID,
                model: normalizedModel(event["model"] as? String)
                    ?? normalizedModel(fallbackModel)
                    ?? "Unknown model",
                now: now
            )
        )
    }

    nonisolated private static func makeUsageRecord(
        from entry: [String: Any],
        context: ConnectOnionUsageCallContext
    ) -> LLMUsageRecord {
        let usage = entry["usage"] as? [String: Any]
        let inputTokens = max(
            0,
            intValue(usage?["input_tokens"])
                ?? intValue(usage?["prompt_tokens"])
                ?? 0
        )
        let outputTokens = max(
            0,
            intValue(usage?["output_tokens"])
                ?? intValue(usage?["completion_tokens"])
                ?? 0
        )
        return LLMUsageRecord(
            id: stableUsageID(
                agentAddress: context.agentAddress,
                remoteSessionID: context.remoteSessionID,
                callID: context.callID
            ),
            timestamp: usageTimestamp(from: entry) ?? context.now,
            model: context.model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            agentAddress: context.agentAddress
        )
    }

    nonisolated static func stableUsageID(
        agentAddress: String,
        remoteSessionID: String,
        callID: String
    ) -> String {
        let material = [
            agentAddress.lowercased(),
            remoteSessionID,
            callID
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func usageCallID(
        from entry: [String: Any]
    ) -> String? {
        (entry["call_id"] as? String)
            ?? (entry["llm_call_id"] as? String)
            ?? (entry["id"] as? String)
    }

    nonisolated private static func fallbackTraceCallID(
        entry: [String: Any],
        index: Int
    ) -> String {
        let serialized: String
        if JSONSerialization.isValidJSONObject(entry),
           let data = try? JSONSerialization.data(
               withJSONObject: entry,
               options: [.sortedKeys]
           ) {
            serialized = data.base64EncodedString()
        } else {
            serialized = String(describing: entry)
        }
        let digest = SHA256.hash(data: Data(serialized.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "trace-\(index)-\(digest)"
    }

    nonisolated static func normalizedModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func usageTimestamp(
        from entry: [String: Any]
    ) -> Date? {
        for key in ["timestamp", "created_at", "created", "time"] {
            guard let value = entry[key] else { continue }
            if let number = doubleValue(value) {
                return UnixTime.date(number)
            }
            if let string = value as? String {
                if let number = Double(string) {
                    return UnixTime.date(number)
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withInternetDateTime,
                    .withFractionalSeconds
                ]
                if let date = formatter.date(from: string) {
                    return date
                }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }
}
