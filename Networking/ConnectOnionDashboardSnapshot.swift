import ConnectOnionKit
import Foundation

/// DASHBOARD_SNAPSHOT: the agent's Control Center page. The host sends one on every connect and every reattach.
extension ConnectOnionRemoteAgentClient {
    /// Passes the page up when the frame is a snapshot for this session.
    func emitDashboardSnapshot(
        _ frame: [String: Any],
        currentSessionID: String?,
        onEvent: @escaping EventHandler
    ) async {
        guard let event = Self.dashboardSnapshotEvent(from: frame, currentSessionID: currentSessionID) else {
            return
        }
        await onEvent(event)
    }

    /// Reads the frame with the kit. A frame without `html` is not a snapshot. Non-matching session ID
    /// is dropped; one that names no session, or arrives before we know ours, is taken.
    /// A page over the cap comes back as `.tooLarge`, not as html.
    nonisolated static func dashboardSnapshotEvent(
        from frame: [String: Any],
        currentSessionID: String?
    ) -> ConnectOnionTransportEvent? {
        guard let fields = JSONValue(any: frame).objectValue,
              case .dashboardSnapshot(let snapshot) = OIPServerFrame.decode(fields) else {
            return nil
        }
        if let named = snapshot.sessionID, let current = currentSessionID, named != current {
            return nil
        }
        return .dashboard(OIPDashboard(html: snapshot.html))
    }

    /// URLSession closes the socket on any message over its 1 MiB default, and a
    /// DASHBOARD_SNAPSHOT may be bigger, so accept up to host limit.
    nonisolated static func defaultWebSocket(urlSession: URLSession) -> WebSocketFactory {
        { url in
            let task = urlSession.webSocketTask(with: url)
            task.maximumMessageSize = OIPDashboard.socketMessageBytes
            return task
        }
    }
}
