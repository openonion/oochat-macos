//
//  AgentBalanceNotice.swift
//  ConnectOnionMacClient
//
//  Created by Kevin Chin on 2/11/2026.
//

import SwiftUI
import ConnectOnionKit

struct AgentBalanceNotice: View {
    let balanceUSD: Double?
    let agentAddress: String?

    private var notice: AgentBalance.Notice? {
        AgentBalance.notice(for: balanceUSD)
    }

    private var message: String? {
        guard let notice else { return nil }
        return AgentBalance.message(for: notice)
    }

    private var purchaseURL: URL? {
        guard let agentAddress else { return nil }
        return AgentBalance.topUpURL(agentAddress: agentAddress)
    }

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OOColor.failureText)
                    .fixedSize(horizontal: false, vertical: true)

                if let purchaseURL {
                    Link("Add credits", destination: purchaseURL)
                        .font(.system(size: 11, weight: .semibold))
                        .underline()
                        .foregroundStyle(OOColor.failureText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(OOColor.failureFill)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(OOColor.failureLine)
                    .frame(height: 1)
            }
        }
    }
}
