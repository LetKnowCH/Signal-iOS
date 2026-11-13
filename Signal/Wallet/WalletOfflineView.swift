// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct WalletOfflineView: View {
    @ObservedObject var model: MerchantWalletModel
    let page: WalletPage
    let hidden: Bool
    let chat: Bool
    let signOut: () -> Void
    @State private var currency: String?
    @State private var history: WalletHistory.Snapshot?
    @State private var showActivity = false
    @State private var attempted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(page == .asset ? "Wallet" : page.rawValue).font(.title.bold())
                    Spacer()
                    Button("Sign out", action: signOut).disabled(model.busy)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Image("letknow_bird").resizable().scaledToFit().frame(width: 78, height: 70)
                            .rotationEffect(.degrees(model.busy && !reduceMotion ? -16 : -8))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.busy)
                    }
                    Text("Wallet offline").font(.title.bold())
                    Text(
                        attempted && !model.busy
                            ? "Still offline. Try again when the service is available."
                            : "Reconnect to update your wallet and make payments.")
                    Button {
                        attempted = true
                        Task { await model.load() }
                    } label: {
                        HStack {
                            if model.busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                            Text(model.busy ? "Connecting…" : "Reconnect")
                        }.padding(.horizontal, 14).frame(minHeight: 44).foregroundColor(WalletStyle.purple).background(
                            .white, in: Capsule())
                    }.disabled(model.busy)
                }.padding(18).foregroundStyle(.white).background(
                    LinearGradient(
                        colors: [Color(red: 38 / 255, green: 19 / 255, blue: 67 / 255), WalletStyle.purple],
                        startPoint: .bottomLeading, endPoint: .topTrailing),
                    in: RoundedRectangle(cornerRadius: 24))
                if page == .shops {
                    WalletCard { Text("Reconnect to view your shops.") }
                } else if page == .invoices {
                    WalletCard { Text("Reconnect to create a payment link.") }
                } else {
                    if chat {
                        Picker("Saved wallet data", selection: $showActivity) {
                            Text("Balances").tag(false)
                            Text("Activity").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if page == .activity || showActivity {
                        cachedActivity(nil)
                    } else {
                        if currency != nil { Button("All balances") { currency = nil } }
                        if let portfolio = model.portfolio {
                            Text("Last saved " + portfolio.savedAt.formatted()).font(.caption)
                            ForEach(portfolio.report.balances.filter { currency == nil || $0.currency == currency }) { row in
                                Button {
                                    currency = row.currency
                                } label: {
                                    WalletCard {
                                        Text(portfolio.assets.first { $0.code == row.currency }?.name ?? row.currency).bold()
                                        Text(hidden ? "••••" : row.balance + " " + row.currency)
                                        if !hidden, let fiat = row.balance_eur {
                                            Text("≈ " + fiat + " EUR").font(.subheadline)
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                            if let currency {
                                cachedActivity(currency)
                            } else if portfolio.report.balances.isEmpty {
                                Text("No balances at the last update.")
                            }
                        } else {
                            WalletCard {
                                Text("No saved balances").bold()
                                Text("Open your wallet online to save balances.")
                            }
                        }
                    }
                }
            }.padding(16)
        }.background(WalletStyle.background)
            .onAppear { history = try? model.cachedHistory() }
    }

    @ViewBuilder private func cachedActivity(_ currency: String?) -> some View {
        Text("Cached activity").font(.headline)
        if let history {
            Text("Last saved " + history.date.formatted()).font(.caption)
            let rows = currency.map { code in history.page.data.filter { $0.includes(currency: code) } } ?? history.page.data
            if rows.isEmpty { Text("No matching saved transactions.") }
            ForEach(rows) { row in
                WalletCard {
                    Text(row.operationType.replacingOccurrences(of: "_", with: " ").capitalized).bold()
                    if !hidden {
                        ForEach(row.amounts.indices, id: \.self) { i in Text(row.amounts[i].1 + " " + row.amounts[i].0) }
                    }
                    Text(row.status.capitalized + " · " + Date(timeIntervalSince1970: Double(row.createdAt)).formatted())
                        .font(.caption)
                }
            }
        } else {
            Text("Open Activity online to save transactions.")
        }
    }
}
