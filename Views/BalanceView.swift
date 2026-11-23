//
//  BalanceView.swift
//  ConnectOnionMacClient
//
//  Created by hym on 1/7/2026.
//

import SwiftUI
import ConnectOnionKit

/// Displays account balance, wallet credentials, and recovery phrase controls.
struct BalanceView: View {
    private enum CopyTarget: Equatable {
        case walletAddress
        case apiKey
        case recoveryPhrase
    }

    @StateObject private var viewModel: BalanceViewModel
    @ObservedObject var appViewModel: AppViewModel
    @State private var isAPIKeyRevealed = false
    @State private var copiedTarget: CopyTarget?
    @State private var copyFeedbackToken = UUID()

    /// `viewModel` is for tests and previews; the app lets the view make its own.
    init(appViewModel: AppViewModel, viewModel: BalanceViewModel? = nil) {
        self.appViewModel = appViewModel
        _viewModel = StateObject(wrappedValue: viewModel ?? BalanceViewModel())
    }

    /// Wallet amounts are presented consistently as dollar-and-cents values.
    /// The underlying `Decimal` retains the full precision returned by `co status`.
    static func formattedBalance(_ amount: Decimal) -> String {
        var roundedAmount = Decimal()
        var sourceAmount = amount
        NSDecimalRound(&roundedAmount, &sourceAmount, 2, .plain)

        return roundedAmount.formatted(
            .number
                .grouping(.automatic)
                .precision(.fractionLength(2))
        )
    }

    var body: some View {
        SettingsScrollPage {
            balanceBody
        }
    }

    // Stacked, so the twelve-word recovery phrase gets the full width.
    private var balanceBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            balanceCard
            walletCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isShowingRecoverySeed)
        .task {
            async let balance: Void = viewModel.fetchBalance()
            async let credentials: Void = viewModel.fetchCredentials()

            await balance
            await credentials
        }
        .alert(
            "Recovery phrase unavailable",
            isPresented: Binding(
                get: { viewModel.recoverySeedError != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.recoverySeedError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.recoverySeedError = nil
            }
        } message: {
            Text(viewModel.recoverySeedError ?? "")
        }
    }

    /// A plain card like the wallet's, so it sits on the page in light and dark alike.
    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Balance", systemImage: "creditcard")
                    .font(.headline)

                Spacer()

                Button(action: refreshBalance) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .opacity(isLoading ? 0.45 : 1)
                .accessibilityLabel("Refresh balance")
                .help("Refresh balance")
            }

            balanceContent
        }
        .padding(OOSpace.xLarge)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(CardBackground(cornerRadius: OORadius.card))
    }

    @ViewBuilder
    private var balanceContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading\u{2026}")
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(.secondary)
            }

        case .loaded(let amount):
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("$\(Self.formattedBalance(amount))")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("Available credits")
                        .font(.system(size: AppFontSize.footnote))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: addBalance) {
                    Label("Add balance", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Buy credits")
            }

        case .error(let message):
            inlineError(message, retry: refreshBalance)
        }
    }

    /// One line for a failure: what went wrong, and Retry.
    private func inlineError(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OOColor.failureText)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: AppFontSize.body))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
        }
        .accessibilityElement(children: .combine)
    }

    private var walletCard: some View {
        Group {
            if viewModel.isShowingRecoverySeed {
                recoveryPhraseContent
                    .transition(.opacity)
            } else {
                walletContent
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary)
        .padding(OOSpace.xLarge)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CardBackground(cornerRadius: OORadius.card))
    }

    private var walletContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Wallet", systemImage: "wallet.pass")
                    .font(.headline)

                Spacer()

                Button(action: viewModel.refreshCredentials) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isFetchingCredential)
                .opacity(viewModel.isFetchingCredential ? 0.45 : 1)
                .accessibilityLabel("Refresh wallet credentials")
                .help("Refresh wallet credentials")
            }

            walletField(
                title: "Wallet address",
                value: walletAddressText,
                systemImage: "wallet.pass",
                copyValue: viewModel.credentials?.publicKey,
                copyTarget: .walletAddress
            )

            walletField(
                title: "API key",
                value: apiKeyText,
                systemImage: "key.fill",
                copyValue: viewModel.credentials?.jwt,
                copyTarget: .apiKey,
                isSensitive: true
            )

            if let credentialsError = viewModel.credentialsError {
                inlineError(credentialsError, retry: viewModel.refreshCredentials)
            }

            Button(action: viewModel.showRecoverySeed) {
                Label("Show recovery phrase", systemImage: "shield.checkered")
            }
            .padding(.top, 4)
            .help("Show the twelve words that restore this wallet")
        }
    }

    private var recoveryPhraseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recovery phrase", systemImage: "shield.checkered")
                        .font(.headline)

                    Text("Store this phrase offline. It cannot be recovered if lost.")
                        .font(.system(size: AppFontSize.body))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.hideRecoverySeed()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close recovery phrase")
                .help("Close")
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(Array(viewModel.recoveryWords.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: AppFontSize.footnote, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)

                        Text(word)
                            .font(.system(size: AppFontSize.body, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 34)
                    .padding(.horizontal, 10)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    let recoveryPhrase = viewModel.recoveryWords.joined(separator: " ")
                    guard !recoveryPhrase.isEmpty else { return }
                    if SecretPasteboard.copy(recoveryPhrase) {
                        showCopyFeedback(for: .recoveryPhrase)
                    }
                } label: {
                    if copiedTarget == .recoveryPhrase {
                        Label(SecretPasteboard.copiedMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                            .foregroundStyle(OOColor.live)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    } else {
                        Label("Copy Phrase", systemImage: "doc.on.clipboard")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: copiedTarget)

                Button {
                    viewModel.hideRecoverySeed()
                } label: {
                    Text("Done")
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .foregroundStyle(OOColor.onPrimary)
                        .background(OOColor.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func walletField(
        title: String,
        value: String,
        systemImage: String,
        copyValue: String?,
        copyTarget: CopyTarget,
        isSensitive: Bool = false
    ) -> some View {
        let isCopied = copiedTarget == copyTarget
        let copiedMessage = isSensitive ? SecretPasteboard.copiedMessage : "Copied"

        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: AppFontSize.footnote, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)

                Text(
                    isSensitive && !isAPIKeyRevealed && !(copyValue?.isEmpty ?? true)
                        ? "••••••••••••••••••••••••"
                        : value
                )
                    .font(.system(size: AppFontSize.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                    .layoutPriority(1)
                    .truncationMode(.middle)

                Spacer()

                if isSensitive, !(copyValue?.isEmpty ?? true) {
                    Button {
                        isAPIKeyRevealed.toggle()
                    } label: {
                        Image(systemName: isAPIKeyRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isAPIKeyRevealed ? "Hide API key" : "Show API key")
                    .help(isAPIKeyRevealed ? "Hide API key" : "Show API key")
                }

                Button {
                    guard let copyValue, !copyValue.isEmpty else { return }
                    let copied: Bool
                    if isSensitive {
                        copied = SecretPasteboard.copy(copyValue)
                    } else {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(copyValue, forType: .string)
                    }
                    if copied {
                        showCopyFeedback(for: copyTarget)
                    }
                } label: {
                    if isCopied {
                        Label(copiedMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppFontSize.footnote, weight: .semibold))
                            .foregroundStyle(OOColor.live)
                            .fixedSize()
                            .frame(height: 28)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(copyValue?.isEmpty ?? true)
                .opacity((copyValue?.isEmpty ?? true) ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.16), value: isCopied)
                .accessibilityLabel(isCopied ? "\(title) copied" : "Copy \(title)")
                .help(isCopied ? copiedMessage : "Copy \(title)")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            }
        }
    }

    private var walletAddressText: String {
        if viewModel.isFetchingCredential {
            return "Fetching…"
        }

        if viewModel.credentialsError != nil {
            return "Unavailable"
        }

        return viewModel.credentials?.publicKey ?? "Not connected"
    }

    private var apiKeyText: String {
        if viewModel.isFetchingCredential {
            return "Fetching…"
        }

        if viewModel.credentialsError != nil {
            return "Unavailable"
        }

        return viewModel.credentials?.jwt ?? "Not configured"
    }

    private func addBalance() {
        guard let purchaseURL = URL(string: "https://o.openonion.ai/purchase") else { return }
        NSWorkspace.shared.open(purchaseURL)
    }

    private func showCopyFeedback(for target: CopyTarget) {
        let token = UUID()
        copyFeedbackToken = token

        withAnimation(.easeInOut(duration: 0.16)) {
            copiedTarget = target
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard copyFeedbackToken == token else { return }

            withAnimation(.easeInOut(duration: 0.16)) {
                copiedTarget = nil
            }
        }
    }

    private func refreshBalance() {
        viewModel.refresh()
    }

    private var isLoading: Bool {
        if case .loading = viewModel.state {
            return true
        }
        return false
    }
}
