// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

enum WalletPage: String, CaseIterable, Identifiable {
    case wallets = "Wallets"
    case deposit = "Deposit"
    case withdraw = "Withdraw"
    case exchange = "Exchange"
    case send = "Send"
    case account = "Account"
    case asset = "Asset"
    case activity = "Activity"
    case invoices = "Invoices"
    case shops = "Shops"
    var id: String { rawValue }
    static let actions: [Self] = [.deposit, .withdraw, .exchange, .send]
}

enum WalletStyle {
    static let purple = Color(red: 112 / 255, green: 47 / 255, blue: 171 / 255)
    static let pearl = LinearGradient(
        colors: [
            Color(red: 222 / 255, green: 205 / 255, blue: 235 / 255),
            Color(red: 199 / 255, green: 169 / 255, blue: 223 / 255),
        ],
        startPoint: .top, endPoint: .bottom)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let charcoal = Color(red: 55 / 255, green: 56 / 255, blue: 62 / 255)
    static let silver = LinearGradient(colors: [.gray, Color(white: 0.75)], startPoint: .top, endPoint: .bottom)
    static func exactAmount(_ raw: String) -> String {
        guard let value = try? MerchantWalletAPI.decimal(raw) else { return raw }
        return NSDecimalNumber(decimal: value).stringValue
    }

    static func formatted(_ raw: String?, money: Bool = false) -> String {
        guard let raw, let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let digits = money ? 2 : raw.split(separator: ".").dropFirst().first?.count ?? 0
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? raw
    }

}

struct WalletSkeleton: View {
    let sample: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Text(verbatim: sample).redacted(reason: .placeholder)
            .opacity(reduceMotion || !pulse ? 0.75 : 0.35)
            .onAppear {
                if !reduceMotion { withAnimation(.easeInOut(duration: 0.85).repeatForever()) { pulse = true } }
            }
            .accessibilityHidden(true)
    }
}

struct WalletCoin: View {
    let code: String
    var size: CGFloat = 32
    var body: some View {
        let ticker = code.hasPrefix("USDT") ? "USDT" : code
        let colors: [String: UInt32] = [
            "BTC": 0xF7931A, "ETH": 0x62688F, "XRP": 0x23292F,
            "USDT": 0x419C84, "TRX": 0xCA3036, "USDC": 0x2775CA,
        ]
        let rgb = colors[ticker] ?? 0x685581
        ZStack {
            Circle().fill(
                Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255))
            if ["ETH", "XRP", "USDT", "TRX"].contains(ticker) {
                Image("wallet_" + ticker.lowercased()).resizable().scaledToFit().padding(size * 0.16)
            } else {
                Text(verbatim: ["BTC": "₿", "EUR": "€", "USD": "$", "USDC": "$"][ticker] ?? String(ticker.prefix(4)))
                    .font(.caption.bold()).foregroundColor(.white)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct WalletOptions: View {
    let title: String
    let options: [String]
    let selection: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                ForEach(options, id: \.self) { option in
                    Button {
                        choose(option)
                        dismiss()
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if selection == option { Image(systemName: "checkmark") }
                        }.frame(minHeight: 48)
                    }
                    Divider()
                }
            }.padding(20)
        }
    }
}

struct WalletOverview: View {
    let portfolio: MerchantWalletAPI.Portfolio?
    let loading: Bool
    let offline: Bool
    @Binding var fiat: String
    @Binding var hidden: Bool
    var initials: String = ""
    var select: (WalletPage, String?) -> Void
    var refresh: () async -> Void
    @State private var category = "Crypto"
    @State private var funded = false
    private enum Sheet: String, Identifiable {
        case reporting, filter
        var id: Self { self }
    }
    @State private var sheet: Sheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            select(.account, nil)
                        } label: {
                            Group {
                                if initials.isEmpty {
                                    Image(systemName: "person.circle")
                                } else {
                                    Text(initials).font(.headline)
                                }
                            }
                            .frame(width: 44, height: 44).foregroundColor(
                                Color(red: 7 / 255, green: 54 / 255, blue: 142 / 255)
                            )
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 171 / 255, green: 217 / 255, blue: 1),
                                        Color(red: 64 / 255, green: 131 / 255, blue: 236 / 255),
                                    ],
                                    startPoint: .top, endPoint: .bottom), in: Circle())
                        }.accessibilityLabel("Wallet account")
                        Spacer()
                        Text("Wallets").font(.headline)
                        Spacer()
                        roundButton("bell", "Wallet activity") { select(.activity, nil) }
                    }
                    HStack {
                        Text(
                            loading
                                ? (portfolio == nil ? "Loading balances…" : "Updating balances…") : "Total balance report")
                        if loading { ProgressView().tint(.white) }
                    }.padding(.top, 12)
                    HStack {
                        Button {
                            sheet = .reporting
                        } label: {
                            HStack(spacing: 5) {
                                if loading, portfolio == nil, !hidden {
                                    WalletSkeleton(sample: "00,000.00")
                                } else {
                                    let raw =
                                        fiat == "EUR"
                                        ? portfolio?.report.total_balance_eur : portfolio?.report.total_balance_usd
                                    Text(verbatim: hidden ? "••••" : WalletStyle.formatted(raw, money: true))
                                }
                                Spacer(minLength: 4)
                                Text(fiat).fontWeight(.regular)
                                Image(systemName: "chevron.down").font(.caption)
                            }
                        }.font(.title2.bold()).accessibilityLabel("Reporting currency, " + fiat)
                        Spacer()
                        Button {
                            hidden.toggle()
                        } label: {
                            Image(systemName: hidden ? "eye" : "eye.slash").frame(width: 44, height: 44)
                        }.accessibilityLabel(hidden ? "Show balances" : "Hide balances")
                    }
                    if loading && portfolio == nil {
                        WalletSkeleton(sample: "Rates updated  2026.11.11  11:15 UTC+03:00").font(.caption2)
                    } else if offline, let saved = portfolio?.savedAt {
                        Text("Last saved " + saved.formatted()).font(.caption)
                    } else if let rates = portfolio?.report.rates_updated_at {
                        Text("Rates updated  " + Date(timeIntervalSince1970: Double(rates)).formatted()).font(.caption)
                    }
                    WalletActionTiles(
                        gradient: WalletStyle.pearl,
                        enabled: { action in
                            !loading && !offline
                                && portfolio?.assets.contains { $0.isCrypto || ($0.isFiat && action != .withdraw) } == true
                        }
                    ) {
                        select($0, nil)
                    }.padding(.top, 8)
                }.padding(16).foregroundColor(.white)
                    .background(WalletStyle.purple, in: WalletHeaderShape())
                HStack {
                    HStack(spacing: 0) {
                        ForEach(["All", "Crypto", "Fiat"], id: \.self) { option in
                            Button {
                                category = option
                            } label: {
                                Text(option).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .foregroundColor(category == option ? .white : .primary)
                                    .background(category == option ? WalletStyle.purple : .clear, in: Capsule())
                                    .frame(minHeight: 44)
                            }.accessibilityAddTraits(category == option ? .isSelected : [])
                        }
                    }.padding(.horizontal, 4).background(WalletStyle.card, in: Capsule())
                    Spacer()
                    Button {
                        sheet = .filter
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Balance filter")
                }.padding(.horizontal, 16)
                if portfolio == nil && loading {
                    ForEach(0..<3) { _ in
                        WalletAssetCard(row: nil, asset: nil, fiat: fiat, hidden: hidden)
                            .padding(.horizontal, 16).accessibilityLabel("Loading wallet balance")
                    }
                } else if let portfolio {
                    let rows = portfolio.report.balances.filter { row in
                        let asset = portfolio.assets.first { $0.code == row.currency }
                        return (category == "All" || (category == "Crypto" ? asset?.isCrypto : asset?.isFiat) == true)
                            && (!funded || Decimal(string: row.balance) != 0)
                    }
                    ForEach(rows) { row in
                        Button {
                            select(.asset, row.currency)
                        } label: {
                            WalletAssetCard(
                                row: row, asset: portfolio.assets.first { $0.code == row.currency }, fiat: fiat,
                                hidden: hidden)
                        }.padding(.horizontal, 16)
                    }
                    if rows.isEmpty { Text("No wallets match these filters.").foregroundColor(.secondary).padding() }
                }
            }.padding(.bottom)
        }.buttonStyle(.plain).background(WalletStyle.background, ignoresSafeAreaEdges: [.horizontal, .bottom])
            .background(WalletStyle.purple.ignoresSafeArea(edges: .top))
            .refreshable { await refresh() }
            .sheet(item: $sheet) { sheet in
                if sheet == .reporting {
                    WalletOptions(title: "Reporting currency", options: ["EUR", "USD"], selection: fiat) { fiat = $0 }
                } else {
                    let filter = funded ? "Show zero balances" : "Hide zero balances"
                    WalletOptions(title: "Wallet options", options: [filter, "Shops", "Refresh balances"], selection: "") {
                        choice in
                        if choice == filter {
                            funded.toggle()
                        } else if choice == "Shops" {
                            select(.shops, nil)
                        } else {
                            Task { await refresh() }
                        }
                    }
                }
            }
    }

    private func roundButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 44, height: 44)
                .foregroundColor(.black).background(WalletStyle.pearl, in: Circle())
        }.accessibilityLabel(label)
    }

}

struct WalletActionTiles: View {
    let gradient: LinearGradient
    let enabled: (WalletPage) -> Bool
    let select: (WalletPage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WalletPage.actions) { item in
                Button {
                    select(item)
                } label: {
                    VStack(spacing: 5) {
                        Image("wallet_" + item.rawValue.lowercased()).renderingMode(.template).resizable()
                            .scaledToFit().frame(width: 24, height: 24)
                        Text(item.rawValue).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                    }.foregroundColor(.black).frame(maxWidth: .infinity, minHeight: 58)
                        .background(gradient, in: RoundedRectangle(cornerRadius: 19))
                }.disabled(!enabled(item))
            }
        }.buttonStyle(.plain)
    }
}

struct WalletHeaderShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect, byRoundingCorners: [.bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: 26, height: 26)
            ).cgPath)
    }
}

private struct WalletAssetCard: View {
    let row: MerchantWalletAPI.Balance?
    let asset: MerchantWalletAPI.Asset?
    let fiat: String
    let hidden: Bool

    var body: some View {
        let code = row?.currency ?? ""
        let name = asset?.name ?? code
        let networkID = (code + name).uppercased().filter { $0.isLetter || $0.isNumber }
        let network = ["TRC20", "ERC20"].first { networkID.contains($0) }
        let ticker = network != nil && code.hasPrefix("USDT") ? "USDT" : code
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if row != nil {
                    ZStack(alignment: .bottomTrailing) {
                        WalletCoin(code: ticker)
                        if let network { WalletCoin(code: network == "TRC20" ? "TRX" : "ETH", size: 16).offset(x: 3, y: 2) }
                    }
                    Text(ticker == "USDT" ? network.map { "USDT (" + $0 + ")" } ?? name : name).font(.headline)
                    Spacer()
                    if asset?.isCrypto == true {
                        Text("24h / —").font(.caption).foregroundStyle(.secondary).accessibilityLabel(
                            "24-hour change unavailable")
                    }
                } else {
                    Circle().fill(Color.secondary.opacity(0.2)).frame(width: 32, height: 32)
                    WalletSkeleton(sample: "Bitcoin")
                    Spacer()
                    WalletSkeleton(sample: "24h / —")
                }
            }
            if let row {
                Text(verbatim: (hidden ? "••••" : WalletStyle.formatted(row.balance)) + " " + ticker).font(.headline)
                if !hidden, let value = fiat == "EUR" ? row.balance_eur : row.balance_usd {
                    Text(verbatim: "≈ " + (fiat == "EUR" ? "€" : "$") + WalletStyle.formatted(value, money: true))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                WalletSkeleton(sample: "0.00000000 BTC").font(.headline)
                if !hidden { WalletSkeleton(sample: "≈ €000.00").font(.subheadline) }
            }
        }.padding(14).background(WalletStyle.card, in: RoundedRectangle(cornerRadius: 26))
    }
}

struct WalletAssetHeader: View {
    let asset: MerchantWalletAPI.Asset?
    let row: MerchantWalletAPI.Balance?
    let code: String
    @Binding var fiat: String
    @Binding var hidden: Bool
    let rates: Int?
    let available: Bool
    let back: () -> Void
    let select: (WalletPage) -> Void
    @State private var choosingFiat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                        .foregroundColor(.black).background(WalletStyle.silver, in: Circle())
                }.accessibilityLabel("Back")
                Spacer()
                Text(asset?.name ?? code).font(.headline)
                Spacer()
                WalletCoin(code: code, size: 44)
            }
            Text("Balance").foregroundStyle(.secondary)
            HStack {
                Text(verbatim: (hidden ? "••••" : WalletStyle.formatted(row?.balance)) + " " + code).font(.title2.bold())
                Spacer()
                Button {
                    hidden.toggle()
                } label: {
                    Image(systemName: hidden ? "eye" : "eye.slash").frame(width: 44, height: 44)
                }
                .accessibilityLabel(hidden ? "Show balances" : "Hide balances")
            }
            if !hidden, let value = fiat == "EUR" ? row?.balance_eur : row?.balance_usd {
                Button {
                    choosingFiat = true
                } label: {
                    Text(verbatim: "≈ " + (fiat == "EUR" ? "€" : "$") + WalletStyle.formatted(value, money: true))
                }.font(.subheadline).accessibilityLabel("Change reporting currency, " + fiat)
            }
            if let rates { Text("Rates updated  " + Date(timeIntervalSince1970: Double(rates)).formatted()).font(.caption) }
            WalletActionTiles(
                gradient: WalletStyle.silver,
                enabled: { item in
                    available && (asset?.isCrypto == true || (asset?.isFiat == true && item != .withdraw))
                }, select: select)
        }.padding(16).foregroundColor(.white).background(WalletStyle.charcoal, in: WalletHeaderShape())
            .sheet(isPresented: $choosingFiat) {
                WalletOptions(title: "Reporting currency", options: ["EUR", "USD"], selection: fiat) { fiat = $0 }
            }
    }
}

struct WalletCurrencyPicker: View {
    let assets: [MerchantWalletAPI.Asset]
    let balances: [MerchantWalletAPI.Balance]
    let selection: String
    let choose: (MerchantWalletAPI.Asset) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var filter = "All"
    private var visibleAssets: [MerchantWalletAPI.Asset] {
        assets.filter { asset in
            switch filter {
            case "All": return true
            case "Crypto": return asset.isCrypto
            case "Fiat": return asset.isFiat
            default: return asset.code.hasPrefix(filter)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Choose currency").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                Picker("Currency category", selection: $filter) {
                    ForEach(["All", "Crypto", "Fiat", "USDT", "USDC"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                if visibleAssets.isEmpty { Text("No currencies in this category.").foregroundStyle(.secondary) }
                ForEach(visibleAssets, id: \.code) { asset in
                    Button {
                        choose(asset)
                        dismiss()
                    } label: {
                        HStack {
                            WalletCoin(code: asset.code)
                            VStack(alignment: .leading) {
                                Text(asset.name).font(.headline)
                                if let balance = balances.first(where: { $0.currency == asset.code }) {
                                    Text(verbatim: WalletStyle.formatted(balance.balance) + " " + asset.code).font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(asset.code).font(.footnote)
                                }
                            }
                            Spacer()
                            if selection == asset.code { Image(systemName: "checkmark") }
                        }.frame(minHeight: 50)
                    }.buttonStyle(.plain)
                    Divider()
                }
            }.padding(20)
        }
    }
}
