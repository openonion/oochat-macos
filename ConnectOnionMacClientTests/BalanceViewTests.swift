import AppKit
import SwiftUI
import XCTest
@testable import ConnectOnionMacClient

final class BalanceViewTests: XCTestCase {
    @MainActor
    func testBalanceViewRendersIdleLoadingLoadedAndErrorStates() async throws {
        let viewModel = makeViewModel()
        viewModel.state = .idle
        render(viewModel)
        viewModel.state = .loading
        render(viewModel)
        viewModel.state = .loaded(try XCTUnwrap(Decimal(string: "125.50")))
        render(viewModel)
        viewModel.state = .error("Balance unavailable")
        render(viewModel)
    }

    @MainActor
    func testBalanceViewRendersCredentialsAndCredentialErrors() async throws {
        let viewModel = makeViewModel()
        viewModel.state = .loaded(try XCTUnwrap(Decimal(string: "8.25")))
        viewModel.credentials = WalletCredentials(
            publicKey: "0x" + String(repeating: "ab", count: 32),
            jwt: "test-jwt"
        )
        render(viewModel)
        viewModel.credentials = nil
        viewModel.credentialsError = "Not authenticated"
        render(viewModel)
        viewModel.credentialsError = nil
        viewModel.isFetchingCredential = true
        render(viewModel)
    }

    @MainActor
    func testBalanceViewRendersRecoveryPhrase() async {
        let viewModel = makeViewModel()
        viewModel.state = .loaded(0)
        viewModel.recoveryWords = [
            "apple", "bridge", "candle", "drift",
            "ember", "forest", "globe", "harbor",
            "island", "jungle", "kitten", "lemon"
        ]
        viewModel.isShowingRecoverySeed = true
        render(viewModel)
    }

    @MainActor
    private func makeViewModel() -> BalanceViewModel {
        BalanceViewModel(
            service: WalletService(accountProvider: StubDockerAccountProvider())
        )
    }

    @MainActor
    func testSecretCopyIsConcealedAndClearsWhenUnchanged() async throws {
        let pasteboard = NSPasteboard(name: .init("BalanceViewTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(SecretPasteboard.copy("seed words", to: pasteboard, clearAfter: .milliseconds(50)))
        XCTAssertEqual(pasteboard.string(forType: .string), "seed words")
        XCTAssertNotNil(pasteboard.data(forType: SecretPasteboard.concealedType))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testSecretCopyLeavesLaterClipboardContentAlone() async throws {
        let pasteboard = NSPasteboard(name: .init("BalanceViewTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        SecretPasteboard.copy("api key", to: pasteboard, clearAfter: .milliseconds(50))
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(pasteboard.string(forType: .string), "something else")
    }

    // The timer can't run after quit, so quitting clears a secret that's still there.
    @MainActor
    func testQuitClearsASecretStillOnTheClipboard() {
        let pasteboard = NSPasteboard(name: .init("BalanceViewTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        SecretPasteboard.copy("seed words", to: pasteboard, clearAfter: .seconds(600))
        SecretPasteboard.clearPending()
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(SecretPasteboard.copiedMessage, "Copied \u{00B7} clears in 60 s")
    }

    @MainActor
    private func makeAppViewModel() -> AppViewModel {
        let suiteName = "BalanceViewTests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: suiteName)
        return AppViewModel(storage: storage, localAgentDefinitions: [])
    }

    @MainActor
    private func render(
        _ viewModel: BalanceViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: BalanceView(
                appViewModel: makeAppViewModel(),
                viewModel: viewModel
            )
                .frame(width: 900, height: 360)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }
}
