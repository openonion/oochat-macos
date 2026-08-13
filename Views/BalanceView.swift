//
//  BalanceView.swift
//  ConnectOnionMacClient
//
//  Created by hym on 1/7/2026.
//

import SwiftUI

/// Displays account balance, wallet credentials, and recovery phrase controls.
struct BalanceAndAddressView: View {
    private enum CopyTarget: Equatable {
        case walletAddress
        case apiKey
        case recoveryPhrase
    }

    @StateObject private var viewModel: BalanceViewModel
    @State private var isAPIKeyRevealed = false
    @State private var copiedTarget: CopyTarget?
    @State private var copyFeedbackToken = UUID()

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

    init(viewModel: BalanceViewModel? = nil) {
        _viewModel = StateObject(
            wrappedValue: viewModel ?? BalanceViewModel()
        )
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                balanceCard
                walletCard
                    .frame(minWidth: 300)
            }

            VStack(alignment: .leading, spacing: 24) {
                balanceCard
                walletCard
            }
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
            "Recovery Phrase Unavailable",
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

    private var balanceCard: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                Color(red: 0.090, green: 0.090, blue: 0.090)
            )
            .frame(width: 320, height: 300)
            .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
            .overlay {
                // Hairline edge so the card stays visible on the dark-mode
                // background, which shares the same near-black fill.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .overlay {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("BALANCE", systemImage: "creditcard.fill")
                            .font(.system(size: AppFontSize.caption, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.65))

                        Spacer()

                        Button(action: refreshBalance) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                        .opacity(refreshButtonOpacity)
                        .accessibilityLabel("Refresh balance")
                        .help("Refresh balance")
                    }

                    balanceContent
                }
                .padding(28)
            }
    }

    private var refreshButtonOpacity: Double {
        if isLoading {
            return 0.45
        } else {
            return 1
        }
    }

    @ViewBuilder
    private var balanceContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .loading:
            VStack(spacing: 6) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)

                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let amount):
            VStack(alignment: .leading, spacing: 0) {
                Text("$\(Self.formattedBalance(amount))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text("AVAILABLE CREDITS")
                    .font(.system(size: AppFontSize.footnote, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 6)

                Spacer()

                Divider()
                    .overlay(.white.opacity(0.16))
                    .padding(.bottom, 18)

                Button(action: addBalance) {
                    Label("Add Balance", systemImage: "plus")
                        .font(.system(size: AppFontSize.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(Color.black.opacity(0.88))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add balance")
                .help("Purchase ConnectOnion credits")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .error(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.red)

                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)

                Button("Retry", action: refreshBalance)
                    .font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var walletCard: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(AppPalette.surface)
            .frame(maxWidth: .infinity, minHeight: 300)
            .overlay(alignment: .topLeading) {
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
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
    }

    private var walletContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Wallet & API", systemImage: "key.horizontal.fill")
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

            Button(action: backupSeed) {
                Label("Backup Seed", systemImage: "shield.checkered")
                    .font(.system(size: AppFontSize.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityLabel("Backup seed")
            .help("Backup seed")
        }
    }

    private var recoveryPhraseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recovery Phrase", systemImage: "shield.checkered")
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
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(recoveryPhrase, forType: .string) {
                        showCopyFeedback(for: .recoveryPhrase)
                    }
                } label: {
                    if copiedTarget == .recoveryPhrase {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                            .foregroundStyle(AppPalette.success)
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
                        .foregroundStyle(AppPalette.primaryActionForeground)
                        .background(AppPalette.primaryAction)
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
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(copyValue, forType: .string) {
                        showCopyFeedback(for: copyTarget)
                    }
                } label: {
                    if isCopied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppFontSize.footnote, weight: .semibold))
                            .foregroundStyle(AppPalette.success)
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
                .help(isCopied ? "Copied" : "Copy \(title)")
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

        if let credentialsError = viewModel.credentialsError {
            return credentialsError
        }

        return viewModel.credentials?.publicKey ?? "Not connected"
    }

    private var apiKeyText: String {
        if viewModel.isFetchingCredential {
            return "Fetching…"
        }

        if let credentialsError = viewModel.credentialsError {
            return credentialsError
        }

        return viewModel.credentials?.jwt ?? "Not configured"
    }

    private func backupSeed() {
        viewModel.showRecoverySeed()
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
