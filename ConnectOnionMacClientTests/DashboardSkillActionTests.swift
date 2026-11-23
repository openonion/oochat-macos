import ConnectOnionKit
import Foundation
import XCTest
@testable import ConnectOnionMacClient

// a Control Center press reaches the agent as an ordinary prompt.
extension ConnectOnionServiceTests {
    private struct SkillChat {
        let stub: StubRemoteAgentClient
        let service: ConnectOnionService
        let chat: ChatViewModel
    }

    @MainActor
    private func makeSkillChat() async throws -> SkillChat {
        let address = "0x" + String(repeating: "31", count: 32)
        let endpoint = ConnectOnionResolvedEndpoint(
            agentAddress: address,
            webSocketURL: try XCTUnwrap(URL(string: "wss://agent.test/ws")),
            httpBaseURL: try XCTUnwrap(URL(string: "https://agent.test")),
            isDirect: true,
            info: nil
        )
        let stub = await StubRemoteAgentClient(endpoint: endpoint)
        let service = ConnectOnionService(remoteAgentFactory: { _, _, _ in stub })
        let configuration = GeneralAgentConfiguration(
            name: "Skill Agent",
            connectionType: .byAddress,
            addressConfiguration: AgentAddressConfiguration(agentAddress: address)
        )
        let chat = ChatViewModel(
            session: ChatSession(agentConfigId: configuration.id, title: "Skills"),
            configuration: configuration,
            service: service,
            appViewModel: AppViewModel(storage: makeIsolatedDefaults())
        )
        service.connect(with: configuration)
        await waitUntil { service.isHostedAgentStatusLive }
        return SkillChat(stub: stub, service: service, chat: chat)
    }

    /// An AGENT_PROFILE as the kit decodes it, the same route the real frame takes.
    private static func profile(skills names: [String]) -> OIPAgentProfile {
        let frame: [String: JSONValue] = [
            "type": .string("AGENT_PROFILE"),
            "skills": .array(names.map { JSONValue.string($0) })
        ]
        guard case .agentProfile(let profile) = OIPServerFrame.decode(frame) else {
            preconditionFailure("AGENT_PROFILE did not decode")
        }
        return profile
    }

    @MainActor
    func testAControlCenterPressReachesTheAgentAsAPrompt() async throws {
        let fixture = try await makeSkillChat()

        fixture.chat.runControlCenterSkill("/deploy to staging")

        XCTAssertEqual(fixture.chat.messages.last?.content, "/deploy to staging")
        await waitUntil { await fixture.stub.sentRequests.map(\.prompt) == ["/deploy to staging"] }
    }

    @MainActor
    func testAPressOnASkillFromTheProfileFlowsThroughTheCheckerToTheAgent() async throws {
        let fixture = try await makeSkillChat()
        fixture.chat.handleIncomingEvent(.agentProfile(Self.profile(skills: ["deploy"])))

        let outcome = SkillActionChecker.check(
            skill: "deploy",
            args: "  to\n  staging ",
            availableSkills: fixture.chat.agentProfile?.skills
        )
        guard case .send(let line) = outcome else {
            return XCTFail("the checker refused a skill the profile lists")
        }
        fixture.chat.runControlCenterSkill(line)

        await waitUntil { await fixture.stub.sentRequests.map(\.prompt) == ["/deploy to staging"] }
    }

    @MainActor
    func testAPressOnASkillTheProfileDoesNotListIsRefusedBeforeAnythingIsSent() async throws {
        let fixture = try await makeSkillChat()
        fixture.chat.handleIncomingEvent(.agentProfile(Self.profile(skills: ["deploy"])))

        let outcome = SkillActionChecker.check(
            skill: "nuke",
            args: nil,
            availableSkills: fixture.chat.agentProfile?.skills
        )

        XCTAssertEqual(outcome, .refused(.unknownSkill("nuke")))
        XCTAssertTrue(fixture.chat.messages.isEmpty)
        let sentCount = await fixture.stub.sentRequests.count
        XCTAssertEqual(sentCount, 0)
    }
}
