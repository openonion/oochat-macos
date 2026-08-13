import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

final class AgentSettingsViewTests: XCTestCase {
    @MainActor
    func testFormValidationRequiresNameAndAddress() async {
        XCTAssertEqual(
            AgentSettingsForm.validationMessage(name: "  ", address: "0x1234"),
            "Display name is required."
        )
        XCTAssertEqual(
            AgentSettingsForm.validationMessage(name: "Agent", address: " \n "),
            "Agent address or Direct URL is required."
        )
    }

    @MainActor
    func testFormValidationAcceptsAddressAndHTTPURL() async {
        let address = "0x" + String(repeating: "AB", count: 32)
        XCTAssertNil(
            AgentSettingsForm.validationMessage(name: "Agent", address: address)
        )
        XCTAssertNil(
            AgentSettingsForm.validationMessage(
                name: "Local Agent",
                address: " http://localhost:8000 "
            )
        )
        XCTAssertEqual(
            AgentSettingsForm.validationMessage(
                name: "Agent",
                address: "not-an-address"
            ),
            "Enter a valid 0x address or HTTP(S) URL."
        )
    }

    @MainActor
    func testFormBuildsHostedConfigurationWithTrimmedAddress() async {
        let configuration = AgentSettingsForm.configuration(
            name: "My Agent",
            address: "  HTTPS://LOCALHOST:8000/  "
        )
        XCTAssertEqual(configuration.name, "My Agent")
        XCTAssertEqual(configuration.connectionType, .byAddress)
        XCTAssertEqual(
            configuration.addressConfiguration?.agentAddress,
            "https://localhost:8000"
        )
    }

    @MainActor
    func testAgentSettingsViewRendersInvalidAndValidForms() async {
        let appViewModel = makeAppViewModel()
        withExtendedLifetime(appViewModel) {
            autoreleasepool {
                render(
                    AgentSettingsView(
                        appViewModel: appViewModel,
                        initialAgentName: "",
                        initialAddress: ""
                    )
                )
                render(
                    AgentSettingsView(
                        appViewModel: appViewModel,
                        initialAgentName: "Hosted Agent",
                        initialAddress: "0x" + String(repeating: "cd", count: 32)
                    )
                )
            }
        }
    }

    @MainActor
    private func makeAppViewModel() -> AppViewModel {
        let suiteName = "AgentSettingsViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        return AppViewModel(storage: storage)
    }

    @MainActor
    private func render(
        _ view: AgentSettingsView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: view.frame(width: 720, height: 760)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 760)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }
}
