import Foundation

struct WalletCredentials {
    let publicKey: String
    let jwt: String
}

enum WalletServiceError: LocalizedError, Equatable {
    case commandUnavailable
    case commandFailed
    case balanceMissing
    case recoverySeedMissing
    case credentialMissing

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "The Docker Agent runtime is unavailable. Start Docker Desktop, then try again."
        case .commandFailed:
            return "The Docker Agent account could not be read. Check Docker, then refresh."
        case .balanceMissing:
            return "co status did not return a balance."
        case .recoverySeedMissing:
            return "The Docker Agent recovery phrase was not found."
        case .credentialMissing:
            return "Not connected. Refresh and try again."
        }
    }
}

@MainActor
final class WalletService {
    private let accountProvider: DockerAccountProviding?

    init(
        accountProvider: DockerAccountProviding? = nil
    ) {
        self.accountProvider = accountProvider
    }

    func fetchBalance() async throws -> Decimal {
        let output: String
        do {
            output = try await resolveAccountProvider().accountStatus()
        } catch {
            throw WalletServiceError.commandFailed
        }

        guard let balance = Self.parseBalance(from: output) else {
            throw WalletServiceError.balanceMissing
        }
        return balance
    }

    static func parseBalance(from statusOutput: String) -> Decimal? {
        let ansiEscapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let plainOutput = statusOutput.replacingOccurrences(
            of: ansiEscapePattern,
            with: "",
            options: .regularExpression
        )

        for line in plainOutput.components(separatedBy: .newlines) {
            guard let balanceRange = line.range(of: "Balance:", options: .caseInsensitive) else {
                continue
            }

            let balanceText = String(line[balanceRange.upperBound...])
            guard let match = balanceText.range(
                of: #"\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
                options: .regularExpression
            ) else {
                continue
            }

            let number = String(balanceText[match])
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Decimal(string: number, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    func fetchRecoverySeed() throws -> [String] {
        guard let words = try? resolveAccountProvider().recoveryWords(),
              !words.isEmpty else {
            throw WalletServiceError.recoverySeedMissing
        }
        return words
    }

    func fetchCredentials() async throws -> WalletCredentials {
        return try parseCredentials()
    }

    func parseCredentials() throws -> WalletCredentials {
        let values: [String: String]
        do {
            values = try resolveAccountProvider().credentials()
        } catch {
            throw WalletServiceError.credentialMissing
        }
        guard let publicKey = values["AGENT_ADDRESS"], !publicKey.isEmpty else {
            throw WalletServiceError.credentialMissing
        }
        guard let jwt = values["OPENONION_API_KEY"], !jwt.isEmpty else {
            throw WalletServiceError.credentialMissing
        }
        return WalletCredentials(publicKey: publicKey, jwt: jwt)
    }

    private func resolveAccountProvider() throws -> DockerAccountProviding {
        if let accountProvider {
            return accountProvider
        }
        return try DockerRuntimeManager.shared.makeAccountService()
    }
}
