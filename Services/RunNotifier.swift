import AppKit
import Combine
import ConnectOnionKit
import Foundation
import UserNotifications

/// Tells you about a chat while oo-chat is in the background: a notification when a run finishes
/// or an approval is waiting (with Allow once and Skip), a bounce of the Dock icon, and a Dock badge
/// counting the chats that need you. The wording is the iOS app's.
@MainActor
final class RunNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum ApprovalAnswer {
        case allowOnce, skip
    }

    nonisolated static let chatKey = "conversationID"
    nonisolated static let approvalKey = "approvalID"
    nonisolated static let approvalCategory = "approval"
    nonisolated static let allowOnceAction = "allowOnce"
    nonisolated static let skipAction = "skip"

    private lazy var center = UNUserNotificationCenter.current()
    private weak var appViewModel: AppViewModel?
    private var badgeUpdates: AnyCancellable?
    private var activation: NSObjectProtocol?
    private var deactivation: NSObjectProtocol?
    private var hasAskedPermission = false

    /// Called once the window is up. Tests never call it, so they post nothing.
    func attach(to appViewModel: AppViewModel) {
        guard self.appViewModel == nil else {
            return
        }
        self.appViewModel = appViewModel
        appViewModel.runNotifier = self
        center.delegate = self
        // Both bring oo-chat forward on that chat first, so the answer goes over its live connection.
        let allow = UNNotificationAction(identifier: Self.allowOnceAction, title: "Allow once", options: [.foreground])
        let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, skip], intentIdentifiers: [])
        ])
        // The badge follows the rail's ✋: settled a moment after the chats change, not on every token.
        badgeUpdates = appViewModel.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateBadge()
            }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Back in the app: the chats are in front of you, so the badge goes.
            NSApp.dockTile.badgeLabel = nil
        }
        // Leaving the app: count now, so an approval that arrived while you were here gets a badge too.
        deactivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateBadge()
            }
        }
    }

    /// Asked with the first message sent, not at launch, as on iOS; once per run of the app.
    func askPermissionOnce() {
        guard !hasAskedPermission else {
            return
        }
        hasAskedPermission = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// A reply arrived. VoiceOver hears it either way; away from the app, you get a notification too.
    func runDidFinish(chatID: UUID, agentName: String, reply: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(agentName) replied",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
        guard !NSApp.isActive else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = agentName
        content.body = Self.preview(of: reply)
        content.sound = .default
        content.userInfo = [Self.chatKey: chatID.uuidString]
        center.add(UNNotificationRequest(identifier: "finished-\(chatID.uuidString)", content: content, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// An approval is waiting and oo-chat isn't in front.
    func approvalDidArrive(chatID: UUID, agentName: String, request: ConnectOnionApprovalRequest) {
        guard !NSApp.isActive else {
            return
        }
        let content = Self.approvalContent(chatID: chatID, agentName: agentName, request: request)
        center.add(UNNotificationRequest(identifier: "approval-\(request.id)", content: content, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// The card was answered or went away, so its notification shouldn't linger.
    func removeApprovalNotification(approvalID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(approvalID)"])
    }

    /// "<agent> needs your approval", the one-line summary, and the Allow once / Skip buttons.
    nonisolated static func approvalContent(
        chatID: UUID,
        agentName: String,
        request: ConnectOnionApprovalRequest
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(agentName) needs your approval"
        content.body = OOApprovalDisclosure.summary(tool: request.tool, arguments: request.arguments.objectValue ?? [:])
        content.sound = .default
        content.categoryIdentifier = approvalCategory
        content.userInfo = [chatKey: chatID.uuidString, approvalKey: request.id]
        return content
    }

    /// The reply's first line, at most 100 characters; "Finished." when there's no text.
    nonisolated static func preview(of reply: String) -> String {
        let firstLine = reply
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else {
            return "Finished."
        }
        return firstLine.count > 100 ? String(firstLine.prefix(99)) + "\u{2026}" : firstLine
    }

    /// How many chats need you: the ones the rail marks with ✋, each counted once.
    nonisolated static func attentionCount(statuses: [UUID: SidebarChatStatus], chatIDs: Set<UUID>) -> Int {
        statuses.filter { chatIDs.contains($0.key) && $0.value.needsYou }.count
    }

    private func updateBadge() {
        guard !NSApp.isActive, let appViewModel else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = Self.attentionCount(
            statuses: appViewModel.sidebarStatuses,
            chatIDs: Set(appViewModel.sessions.filter { !$0.isTombstone }.map(\.id))
        )
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Clicking it opens that chat; Allow once and Skip also answer the approval.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let chatID = (info[Self.chatKey] as? String).flatMap(UUID.init(uuidString:)) else {
            return
        }
        let approvalID = info[Self.approvalKey] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            switch (action, approvalID) {
            case (Self.allowOnceAction, let approvalID?):
                self.answer(.allowOnce, approvalID: approvalID, chatID: chatID)
            case (Self.skipAction, let approvalID?):
                self.answer(.skip, approvalID: approvalID, chatID: chatID)
            default:
                self.open(chatID)
            }
        }
    }

    private func open(_ chatID: UUID) {
        NSApp.activate()
        appViewModel?.selectHistoricalSession(chatID)
    }

    /// Only the open chat stays connected, so an answer goes through only while that chat still
    /// holds the same card. Otherwise the chat just opens and the card waits there.
    private func answer(_ answer: ApprovalAnswer, approvalID: String, chatID: UUID) {
        open(chatID)
        guard let chat = appViewModel?.activeChat, chat.session.id == chatID,
              case .approval(let request)? = chat.pendingInteraction, request.id == approvalID else {
            return
        }
        switch answer {
        case .allowOnce:
            chat.submitApproval(.approveOnce)
        case .skip:
            chat.submitApproval(.rejectSoft(feedback: ""))
        }
    }
}
