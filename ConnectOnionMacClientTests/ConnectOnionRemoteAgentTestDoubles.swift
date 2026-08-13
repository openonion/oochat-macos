import CryptoKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

actor RemoteProtocolRecorder {
    var updates: [String] = []
    var events: [String] = []
    var failures: [String] = []

    func record(_ update: ConnectOnionTransportUpdate) {
        updates.append("\(update.status):\(update.detail ?? "none")")
    }

    func record(_ event: ConnectOnionTransportEvent) {
        switch event {
        case .output(let value):
            events.append("output:\(value)")
        case .usage(let value):
            events.append("usage:\(value.tokenCount)")
        case .executionItem:
            events.append("execution_item")
        case .agentImage:
            events.append("agent_image")
        case .agentArtifact(let payload):
            events.append("agent_artifact:\(payload.reference.artifactID)")
        case .artifactTransferFailed(let value):
            events.append("artifact_error:\(value)")
        case .runtimeInputAcknowledged(let localMessageID):
            events.append("runtime_ack:\(localMessageID.uuidString)")
        case .askUser:
            events.append("ask_user")
        case .approvalRequired:
            events.append("approval")
        case .onboardingRequired:
            events.append("onboarding")
        case .onboardingSucceeded(let value):
            events.append("onboarding_success:\(value)")
        case .modeChanged(let value):
            events.append("mode:\(value.rawValue)")
        case .planReviewRequired:
            events.append("plan_review")
        case .ulwCheckpointRequired:
            events.append("ulw_checkpoint")
        case .recoveryState(let value):
            events.append("recovery:\(value)")
        case .interrupted:
            events.append("interrupted")
        case .error(let value):
            events.append("error:\(value)")
        }
    }

    func recordFailure(_ error: Error) {
        failures.append(error.localizedDescription)
    }

    struct Snapshot {
        let updates: [String]
        let events: [String]
        let failures: [String]
    }

    func snapshot() -> Snapshot {
        Snapshot(updates: updates, events: events, failures: failures)
    }
}

func recordProtocolFailure(
    _ recorder: RemoteProtocolRecorder,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
    } catch {
        await recorder.recordFailure(error)
    }
}

nonisolated final class ScriptedWebSocketTask:
    ConnectOnionWebSocketTasking,
    @unchecked Sendable {
    private let lock = NSLock()
    private var inboundMessages: [URLSessionWebSocketTask.Message]
    private var outboundMessages: [URLSessionWebSocketTask.Message] = []
    let receiveError: Error?
    private var resumed = false
    var cancelled = false

    init(events: [[String: Any]]) throws {
        inboundMessages = try events.enumerated().map { index, event in
            let data = try makeJSONData(event)
            if index.isMultiple(of: 2) {
                return .string(
                    try XCTUnwrap(String(bytes: data, encoding: .utf8))
                )
            }
            return .data(data)
        }
        receiveError = nil
    }

    init(receiveError: Error) {
        inboundMessages = []
        self.receiveError = receiveError
    }

    var wasResumed: Bool {
        withLock { resumed }
    }

    var wasCancelled: Bool {
        withLock { cancelled }
    }

    func resume() {
        withLock {
            resumed = true
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        withLock {
            outboundMessages.append(message)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try nextInboundMessage()
    }

    func cancel(
        with _: URLSessionWebSocketTask.CloseCode,
        reason _: Data?
    ) {
        withLock {
            cancelled = true
        }
    }

    func sentJSONObjects() throws -> [[String: Any]] {
        let messages = withLock { outboundMessages }
        return try messages.map { message in
            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let value):
                data = value
            @unknown default:
                throw ConnectOnionRemoteError.invalidProtocolMessage
            }
            guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw ConnectOnionRemoteError.invalidProtocolMessage
            }
            return object
        }
    }

    private func nextInboundMessage() throws -> URLSessionWebSocketTask.Message {
        try withLock {
            if !inboundMessages.isEmpty {
                return inboundMessages.removeFirst()
            }
            throw receiveError ?? ConnectOnionRemoteError.connectionClosed
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

final class RemoteAgentURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static var receivedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.url)
    }

    static func install(handler: @escaping Handler) {
        lock.lock()
        Self.handler = handler
        requests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestHandler: Handler?
        Self.lock.lock()
        Self.requests.append(request)
        requestHandler = Self.handler
        Self.lock.unlock()

        guard let requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeHTTPResponse(
    for request: URLRequest,
    statusCode: Int
) -> HTTPURLResponse {
    guard let url = request.url,
          let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    ) else {
        preconditionFailure("Failed to create HTTP response")
    }
    return response
}

// MARK: - Tool presentation (thought-chain compatibility)

func makeJSONData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            append(byte)
            index = nextIndex
        }
    }
}
