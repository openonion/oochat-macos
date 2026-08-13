import Foundation

/// The `session` object nested inside a hosted history record.
nonisolated struct ConnectOnionHostedConversation: Decodable, Sendable {
    var messages: [ConnectOnionHostedMessage] = []
    var updated: Double?
}

/// One hosted transcript entry; `text` unwraps only plain string content.
nonisolated struct ConnectOnionHostedMessage: Decodable, Sendable {
    var role: String
    /// Tool-call records in ConnectOnion 1.5.11 can omit `content`.
    var content: ConnectOnionJSONValue?
    var isInternal: Bool?

    var text: String? {
        guard case .string(let value)? = content else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case isInternal = "internal"
    }
}

/// A durable session returned by the ConnectOnion host's history endpoint.
/// The native client deliberately ignores internal model/tool messages when it
/// projects this transport shape into its local chat timeline.
nonisolated struct ConnectOnionHostedSession: Decodable, Sendable {
    var sessionID: String
    var status: String
    var prompt: String
    var result: String?
    var conversation: ConnectOnionHostedConversation?
    var created: Double?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case prompt
        case result
        case conversation = "session"
        case created
    }
}

/// Envelope returned by the host's `/sessions` listing.
nonisolated private struct ConnectOnionHostedSessionsResponse: Decodable {
    var sessions: [ConnectOnionHostedSession]
}

/// Reads server-backed history from a directly reachable ConnectOnion host.
nonisolated struct ConnectOnionHistoryClient: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func sessions(from baseURL: URL) async throws -> [ConnectOnionHostedSession] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("sessions")
        )
        request.timeoutInterval = 3

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ConnectOnionRemoteError.directEndpointUnavailable
        }

        do {
            return try JSONDecoder()
                .decode(ConnectOnionHostedSessionsResponse.self, from: data)
                .sessions
        } catch {
            throw ConnectOnionRemoteError.invalidProtocolMessage
        }
    }
}
