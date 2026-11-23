import ConnectOnionKit
import Foundation

/// Hosted History projected into chat messages.
extension AppViewModel {
    static func projectMessages(
        from hosted: ConnectOnionHostedSession,
        sessionID: UUID
    ) -> [ChatMessage] {
        let source = hosted.conversation?.messages ?? []
        let baseDate = hosted.createdDate ?? Date()
        var projected: [ChatMessage] = []

        for (index, message) in source.enumerated() {
            guard message.isInternal != true,
                  let text = message.text?.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ),
                  !text.isEmpty else {
                continue
            }
            guard let turnRole = message.turnRole else { continue }
            let role: MessageRole = turnRole == .user ? .user : .agent
            projected.append(
                ChatMessage(
                    sessionId: sessionID,
                    role: role,
                    content: text,
                    timestamp: baseDate.addingTimeInterval(Double(index))
                )
            )
        }

        if !projected.contains(where: { $0.role == .user }) {
            let prompt = hosted.prompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !prompt.isEmpty {
                projected.insert(
                    ChatMessage(
                        sessionId: sessionID,
                        role: .user,
                        content: prompt,
                        timestamp: baseDate
                    ),
                    at: 0
                )
            }
        }
        if let result = hosted.result?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           !result.isEmpty,
           projected.last(where: { $0.role == .agent })?.content != result {
            projected.append(
                ChatMessage(
                    sessionId: sessionID,
                    role: .agent,
                    content: result,
                    timestamp: hosted.conversation?.updatedDate ?? baseDate
                )
            )
        }
        return collapsingIntermediateAgentMessages(projected)
    }

    /// Older hosts persisted the user-visible intent acknowledgement as an
    /// ordinary assistant message immediately before the real answer. The live
    /// client renders that acknowledgement in the execution trace, so keeping
    /// both history records produces two avatar replies for a single turn.
    /// Retain only the final message in each consecutive assistant sequence.
    static func collapsingIntermediateAgentMessages(
        _ messages: [ChatMessage]
    ) -> [ChatMessage] {
        var collapsed: [ChatMessage] = []
        var lastMessageIndexBySession: [UUID: Int] = [:]
        for message in messages {
            if message.role == .agent,
               let lastIndex = lastMessageIndexBySession[message.sessionId],
               collapsed[lastIndex].role == .agent {
                collapsed[lastIndex] = message
            } else {
                collapsed.append(message)
                lastMessageIndexBySession[message.sessionId] = collapsed.count - 1
            }
        }
        return collapsed
    }

    /// A chat from the host is named the same way: its first real message, never a /command.
    static func title(for messages: [ChatMessage]) -> String {
        messages.lazy
            .filter { $0.role == .user }
            .compactMap { ChatTitle.from($0.content) }
            .first ?? ChatSession.defaultTitle
    }
}
