import Foundation

/// Where a configured target actually resolved: a verified direct `/ws`
/// endpoint with its `/info` payload, or the shared relay socket when no
/// direct route answered.
nonisolated struct ConnectOnionResolvedEndpoint {
    let agentAddress: String
    let webSocketURL: URL
    let httpBaseURL: URL?
    let isDirect: Bool
    let info: ConnectOnionAgentInfo?
}

/// Payload of an agent's `/info` endpoint. Its `address` doubles as proof
/// that a direct endpoint really serves the agent we meant to reach.
nonisolated struct ConnectOnionAgentInfo: Decodable {
    typealias FileInputCapabilities = ConnectOnionFileInputCapabilities

    let name: String
    let address: String
    let tools: [String]?
    let model: String?
    let trust: String?
    let version: String?
    let acceptedInputs: AcceptedInputs?

    nonisolated struct AcceptedInputs: Decodable {
        let text: Bool?
        let images: Bool?
        let files: FileInputCapabilities?
    }

    enum CodingKeys: String, CodingKey {
        case name
        case address
        case tools
        case model
        case trust
        case version
        case acceptedInputs = "accepted_inputs"
    }
}

/// File-upload limits advertised under `accepted_inputs.files`. Agents may
/// publish either a bare boolean or a full limits object, so decoding
/// accepts both shapes.
nonisolated struct ConnectOnionFileInputCapabilities:
    Decodable,
    Equatable,
    Sendable {
    let isSupported: Bool
    let maxFileSizeMB: Int?
    let maxFilesPerRequest: Int?

    static let protocolDefault = ConnectOnionFileInputCapabilities(
        isSupported: true,
        maxFileSizeMB: 10,
        maxFilesPerRequest: 10
    )

    init(
        isSupported: Bool,
        maxFileSizeMB: Int? = nil,
        maxFilesPerRequest: Int? = nil
    ) {
        self.isSupported = isSupported
        self.maxFileSizeMB = maxFileSizeMB
        self.maxFilesPerRequest = maxFilesPerRequest
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let isSupported = try? singleValue.decode(Bool.self) {
            self.init(isSupported: isSupported)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isSupported: true,
            maxFileSizeMB: try container.decodeIfPresent(
                Int.self,
                forKey: .maxFileSizeMB
            ),
            maxFilesPerRequest: try container.decodeIfPresent(
                Int.self,
                forKey: .maxFilesPerRequest
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case maxFileSizeMB = "max_file_size_mb"
        case maxFilesPerRequest = "max_files_per_request"
    }
}

/// Relay registry entry for an address: the direct endpoints worth probing,
/// plus enough liveness hints to decide whether a relay fallback can work.
nonisolated struct ConnectOnionRelayAgentInfo: Decodable {
    let online: Bool?
    let endpoints: [String]
    let relay: ConnectOnionJSONValue?
    let lastSeen: String?

    var isReachable: Bool {
        if let online {
            return online
        }
        if !endpoints.isEmpty {
            return true
        }
        guard let relay else {
            return false
        }

        switch relay {
        case .string(let value):
            return !value.isEmpty
        case .object(let value):
            return !value.isEmpty
        case .array(let value):
            return !value.isEmpty
        case .bool(let value):
            return value
        case .number:
            return true
        case .null:
            return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case online
        case endpoints
        case relay
        case lastSeen = "last_seen"
    }
}

/// Validates and lowercases 66-character `0x` public-key addresses so
/// identity comparisons are byte-for-byte.
nonisolated enum ConnectOnionAddress {
    static func normalized(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count == 66, candidate.hasPrefix("0x") else {
            return nil
        }

        let hex = candidate.dropFirst(2)
        guard hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return "0x" + hex.lowercased()
    }
}

/// Accepts either agent identity the app supports, a `0x` address or an
/// HTTP(S) Direct URL, and normalizes it into one canonical string.
nonisolated enum ConnectOnionAgentTarget {
    static func normalized(_ value: String) -> String? {
        if let address = ConnectOnionAddress.normalized(value) {
            return address
        }
        return directURL(from: value)?.absoluteString
    }

    static func directURL(from value: String) -> URL? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        if components.path == "/" {
            components.path = ""
        }
        return components.url
    }
}

/// Resolves a configured target to something connectable, preferring a
/// direct `/ws` endpoint whose `/info` address matches and falling back to
/// the relay socket only while the agent still looks reachable there.
nonisolated struct ConnectOnionEndpointResolver {
    private let urlSession: URLSession
    private let relayHTTPBaseURL: URL
    private let relayWebSocketURL: URL

    init(
        urlSession: URLSession = .shared,
        relayHTTPBaseURL: URL = URL(string: "https://oo.openonion.ai")!,
        relayWebSocketURL: URL = URL(string: "wss://oo.openonion.ai/ws/input")!
    ) {
        self.urlSession = urlSession
        self.relayHTTPBaseURL = relayHTTPBaseURL
        self.relayWebSocketURL = relayWebSocketURL
    }

    func resolve(_ configuredTarget: String) async throws -> ConnectOnionResolvedEndpoint {
        if let address = ConnectOnionAddress.normalized(configuredTarget) {
            return try await resolveAddress(address)
        }

        guard let directBaseURL = ConnectOnionAgentTarget.directURL(
            from: configuredTarget
        ) else {
            throw ConnectOnionRemoteError.invalidAgentTarget
        }

        let info = try await fetchInfo(from: directBaseURL)
        guard let address = ConnectOnionAddress.normalized(info.address) else {
            throw ConnectOnionRemoteError.invalidAgentInfo
        }

        return ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try webSocketURL(from: directBaseURL),
            httpBaseURL: directBaseURL,
            isDirect: true,
            info: info
        )
    }

    func isOnline(_ configuredTarget: String) async -> Bool {
        do {
            _ = try await resolve(configuredTarget)
            return true
        } catch {
            return false
        }
    }

    private func resolveAddress(_ address: String) async throws -> ConnectOnionResolvedEndpoint {
        let relayInfo = try await fetchRelayInfo(for: address)

        for endpoint in relayInfo.endpoints where endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://") {
            guard let baseURL = URL(string: endpoint) else { continue }

            do {
                let info = try await fetchInfo(from: baseURL)
                guard ConnectOnionAddress.normalized(info.address) == address else {
                    continue
                }

                return ConnectOnionResolvedEndpoint(
                    agentAddress: address,
                    webSocketURL: try webSocketURL(from: baseURL),
                    httpBaseURL: baseURL,
                    isDirect: true,
                    info: info
                )
            } catch {
                continue
            }
        }

        guard relayInfo.isReachable else {
            throw ConnectOnionRemoteError.agentOffline
        }

        return ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: relayWebSocketURL,
            httpBaseURL: nil,
            isDirect: false,
            info: nil
        )
    }

    private func fetchRelayInfo(for address: String) async throws -> ConnectOnionRelayAgentInfo {
        let url = relayHTTPBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("agents")
            .appendingPathComponent(address)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ConnectOnionRemoteError.agentNotFound
        }

        do {
            return try JSONDecoder().decode(ConnectOnionRelayAgentInfo.self, from: data)
        } catch {
            throw ConnectOnionRemoteError.invalidRelayResponse
        }
    }

    private func fetchInfo(from baseURL: URL) async throws -> ConnectOnionAgentInfo {
        let infoURL = baseURL.appendingPathComponent("info")
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 3

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ConnectOnionRemoteError.directEndpointUnavailable
        }

        do {
            return try JSONDecoder().decode(ConnectOnionAgentInfo.self, from: data)
        } catch {
            throw ConnectOnionRemoteError.invalidAgentInfo
        }
    }

    private func webSocketURL(from baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ConnectOnionRemoteError.invalidAgentTarget
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            throw ConnectOnionRemoteError.invalidAgentTarget
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/ws" : "/\(basePath)/ws"

        guard let url = components.url else {
            throw ConnectOnionRemoteError.invalidAgentTarget
        }
        return url
    }

}
