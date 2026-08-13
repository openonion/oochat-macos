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
    private func render(
        _ viewModel: BalanceViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(
            rootView: BalanceAndAddressView(viewModel: viewModel)
                .frame(width: 900, height: 360)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 360)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0, file: file, line: line)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }
}
