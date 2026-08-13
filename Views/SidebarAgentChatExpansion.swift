import SwiftUI

nonisolated struct SidebarAgentChatExpansionState: Equatable {
    private(set) var collapsedAgentIDs: Set<UUID> = []

    func isExpanded(_ agentID: UUID) -> Bool {
        !collapsedAgentIDs.contains(agentID)
    }

    mutating func toggle(_ agentID: UUID) {
        if collapsedAgentIDs.contains(agentID) {
            collapsedAgentIDs.remove(agentID)
        } else {
            collapsedAgentIDs.insert(agentID)
        }
    }

    mutating func remove(_ agentID: UUID) {
        collapsedAgentIDs.remove(agentID)
    }
}

struct AgentChatDisclosureButton: View {
    let agentName: String
    let hasChats: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        if hasChats {
            Button(action: action) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 12, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded
                    ? "Collapse chats for \(agentName)"
                    : "Expand chats for \(agentName)"
            )
            .help(
                isExpanded
                    ? "Collapse \(agentName) chats"
                    : "Expand \(agentName) chats"
            )
        } else {
            Color.clear
                .frame(width: 12, height: 24)
        }
    }
}
