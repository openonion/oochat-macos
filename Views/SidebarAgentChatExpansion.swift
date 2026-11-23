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
