import Foundation
import Combine

/// Loading lifecycle for the wallet balance display.
enum BalanceState {
    case idle
    case loading
    case loaded(Decimal)
    case error(String)
}

/// Backs the wallet pane: balance and credential fetches and the
/// recovery-seed reveal flow.
@MainActor
class BalanceViewModel: ObservableObject {
    @Published var state: BalanceState = .idle
    @Published var credentials: WalletCredentials?
    @Published var credentialsError: String?
    @Published var isFetchingCredential = false
    @Published var recoveryWords: [String] = []
    @Published var recoverySeedError: String?
    @Published var isShowingRecoverySeed = false

    let service: WalletService

    init(service: WalletService? = nil) {
        self.service = service ?? WalletService()
    }

    func fetchBalance() async {
        state = .loading
        do {
            state = .loaded(try await service.fetchBalance())
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func fetchCredentials() async {
        isFetchingCredential = true
        credentialsError = nil

        do {
            credentials = try await service.fetchCredentials()
        } catch {
            credentials = nil
            credentialsError = error.localizedDescription
        }

        isFetchingCredential = false
    }

    func showRecoverySeed() {
        do {
            recoveryWords = try service.fetchRecoverySeed()
            recoverySeedError = nil
            isShowingRecoverySeed = true
        } catch {
            recoveryWords = []
            recoverySeedError = error.localizedDescription
        }
    }

    func hideRecoverySeed() {
        isShowingRecoverySeed = false
    }

    func refresh() {
        Task { await fetchBalance() }
    }

    func refreshCredentials() {
        Task { await fetchCredentials() }
    }
}
