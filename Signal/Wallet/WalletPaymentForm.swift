// SPDX-License-Identifier: AGPL-3.0-only

import SignalUI
import SwiftUI

struct WalletCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WalletStyle.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct WalletPaymentForm: View {
    @ObservedObject var model: MerchantWalletModel
    let page: WalletPage
    @State var fiat: String
    let initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var coin = ""
    @State private var fiatDeposit = false
    @State private var fiatInput = false
    @State private var pairs: [MerchantWalletAPI.ExchangePair] = []
    @State private var target = ""
    @State private var banks: MerchantWalletAPI.BankList?
    @State private var bankId = 0
    @State private var deposit: MerchantWalletAPI.DepositAddress?
    @State private var policy: MerchantWalletAPI.WithdrawalPolicy?
    @State private var estimate: MerchantWalletAPI.WithdrawalEstimate?
    @State private var amount = ""
    @State private var address = ""
    @State private var tag = ""
    @State private var comment = ""
    @State private var agree = false
    @State private var code = ""
    @State private var otp = ""
    @State private var sentCode = false
    @State private var quote: MerchantWalletAPI.Operation?
    @State private var review: MerchantWalletAPI.Operation?
    @State private var message = ""
    @State private var error = ""
    @State private var loading = true
    @State private var estimating = false
    @State private var working = false
    @State private var finished = false
    @State private var retry = 0
    private enum PickerSheet: String, Identifiable {
        case source, target, bank, addressQR, tagQR, showTag, shareDeposit, reporting
        var id: Self { self }
    }
    @State private var picker: PickerSheet?
    @State private var qrImage: UIImage?
    @State private var lastQRAddress: String?
    private var assetBalance: MerchantWalletAPI.Balance? { model.balances?.first { $0.currency == coin } }
    private var insufficient: Bool {
        guard page == .exchange, let number = try? MerchantWalletAPI.decimal(normalized), let balance,
            let available = try? MerchantWalletAPI.decimal(balance)
        else { return false }
        return number > available
    }

    private var assets: [MerchantWalletAPI.Asset] {
        let catalog = model.portfolio?.assets ?? []
        if page == .exchange {
            var seen = Set<String>()
            return pairs.compactMap { pair in
                guard seen.insert(pair.source).inserted else { return nil }
                return catalog.first { $0.code == pair.source }
                    ?? MerchantWalletAPI.Asset(code: pair.source, name: pair.source, isFiat: false, isCrypto: false)
            }
        }
        return catalog.filter {
            if page == .withdraw { return $0.isCrypto }
            return fiatDeposit ? $0.isFiat : $0.isCrypto
        }
    }
    private var bank: MerchantWalletAPI.Bank? { banks?.banks.first { $0.id == bankId } }
    private var assetName: String { assets.first { $0.code == coin }?.name ?? coin }
    private var balance: String? { model.balances?.first { $0.currency == coin }?.balance }
    private var pair: MerchantWalletAPI.ExchangePair? { pairs.first { $0.source == coin && $0.target == target } }
    private var normalized: String { amount.replacingOccurrences(of: ",", with: ".") }
    private var lookupKey: String { [coin, String(fiatDeposit), String(retry)].joined(separator: "|") }
    private var estimateKey: String {
        [lookupKey, target, normalized, String(fiatInput), String(bankId), fiat].joined(separator: "|")
    }
    @State private var estimatedKey = ""
    private var validEstimate: Bool { estimatedKey == estimateKey && !estimating }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(review == nil ? "Close" : "Back") { if review != nil { review = nil } else { dismiss() } }
                Spacer()
                Text(review?.title ?? page.rawValue).font(.headline)
                Spacer()
                Text("Close").hidden()
            }.padding(16)
            ScrollView {
                VStack(spacing: 12) {
                    if finished {
                        WalletCard {
                            Label(message, systemImage: "checkmark.circle.fill").font(.title3.bold())
                            Text("Check Activity for the final status.")
                        }
                    } else if let review {
                        WalletCard {
                            ForEach(review.details.indices, id: \.self) { i in
                                let field = review.details[i]
                                Text(field.0).font(.caption).foregroundColor(.secondary)
                                Text(verbatim: field.1).textSelection(.enabled)
                            }
                        }
                        if page == .withdraw { verification }
                    } else if page == .exchange {
                        exchangeInput
                        exchangeDestination
                    } else {
                        if page == .deposit {
                            Picker("Deposit type", selection: $fiatDeposit) {
                                Text("Crypto").tag(false)
                                Text("Fiat").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        WalletCard {
                            Text(page == .exchange ? "You pay" : "Choose currency").font(.subheadline)
                            Button {
                                picker = .source
                            } label: {
                                HStack {
                                    if coin.isEmpty && loading {
                                        WalletSkeleton(sample: "Bitcoin  BTC")
                                    } else {
                                        WalletCoin(code: coin)
                                        Text(assetName).bold()
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                }
                            }.disabled(assets.isEmpty)
                            if let balance { Text("Available: " + balance + " " + coin).font(.footnote) }
                        }
                        if page == .deposit && !fiatDeposit {
                            cryptoDeposit
                        } else {
                            if page == .deposit { bankSelection }
                            amountEntry
                            if page == .withdraw { withdrawal }
                            if estimating && page != .withdraw {
                                WalletCard {
                                    WalletSkeleton(sample: "Fee   0.00000000")
                                    WalletSkeleton(sample: "Total   0.00000000")
                                }
                            } else if validEstimate, let quote {
                                WalletCard {
                                    ForEach(quote.details.prefix(3).indices, id: \.self) { i in
                                        Text(quote.details[i].0 + "   " + quote.details[i].1)
                                    }
                                }
                            }
                        }
                    }
                    if !error.isEmpty {
                        WalletCard {
                            Text(error).foregroundColor(.red)
                            if review == nil { Button("Try again") { retry += 1 } }
                        }
                    }
                    if !finished && !message.isEmpty { Text(message).font(.footnote) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
            if page == .withdraw && !finished && review == nil { withdrawalFees }
            if finished {
                footer("Done", true) {
                    model.acknowledgeHistory()
                    dismiss()
                }
            } else if let review {
                let codesValid =
                    page != .withdraw || (sixDigits(code) && (policy?.requiresEmailCode == false || sixDigits(otp)))
                footer(review.confirm, codesValid && !model.uncertain) { Task { await submit(review) } }
            } else if page != .deposit || fiatDeposit {
                let valid =
                    validEstimate
                    && (page == .withdraw
                        ? (agree && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && estimate != nil
                            && policy != nil) : quote != nil)
                footer(page == .deposit ? "Bank instructions" : "Review " + page.rawValue.lowercased(), valid) {
                    Task { await prepareReview() }
                }
            } else {
                footer("Close", true) { dismiss() }
            }
        }.background(WalletStyle.background).tint(WalletStyle.purple)
            .disabled(working).interactiveDismissDisabled(working)
            .onChange(of: model.uncertain) { if $0 { dismiss() } }
            .onChange(of: coin) { _ in
                guard page == .withdraw else { return }
                address = ""
                tag = ""
                comment = ""
                agree = false
                code = ""
                otp = ""
                sentCode = false
                fiatInput = false
            }
            .sheet(item: $picker) { item in sheet(item) }
            .task {
                if page == .deposit, let initial {
                    fiatDeposit = model.portfolio?.assets.first { $0.code == initial }?.isFiat == true
                }
                coin = initial ?? ""
            }
            .task(id: lookupKey) { await loadCurrency() }
            .task(id: estimateKey) { await updateEstimate() }
    }

    private func sixDigits(_ value: String) -> Bool { value.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil }
    private func footer(_ title: String, _ enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if !finished && (page != .deposit || fiatDeposit) {
                Button(review == nil ? "Cancel" : "Edit") { if review != nil { review = nil } else { dismiss() } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Button(action: action) {
                if working {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    Text(title).bold().frame(maxWidth: .infinity, minHeight: 48)
                }
            }.buttonStyle(.borderedProminent).disabled(!enabled || working)
        }.padding(.horizontal, 16).padding(.vertical, 8).background(WalletStyle.card)
    }

    private var amountEntry: some View {
        WalletCard {
            Text("Amount (" + (fiatInput ? fiat : coin) + ")").font(.headline)
            if page != .deposit, let assetBalance {
                HStack {
                    ForEach([25, 50, 75, 100], id: \.self) { percent in
                        Button(percent == 100 ? "MAX" : String(percent) + "%") {
                            fiatInput = false
                            var value = WalletSendAmount(reportingCurrency: fiat)
                            value.selectPercent(percent, balance: assetBalance, isFiat: false)
                            amount = value.text
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            HStack {
                TextField("0.0", text: $amount).keyboardType(.decimalPad).font(.title2).accessibilityLabel("Amount")
                if page == .withdraw {
                    Button {
                        amount = (fiatInput ? estimate?.cryptoAmount : estimate?.fiatAmount) ?? ""
                        fiatInput.toggle()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }.accessibilityLabel("Switch amount currency")
                }
            }
            if page == .withdraw {
                HStack {
                    if validEstimate, let estimate {
                        Text("≈ " + (fiatInput ? estimate.cryptoAmount + " " + coin : estimate.fiatAmount + " " + fiat))
                    } else if estimating {
                        WalletSkeleton(sample: "≈ 00.00")
                    } else {
                        Text("—")
                    }
                    Spacer()
                    Button(fiat) { picker = .reporting }
                }
            }
        }
    }

    private var exchangeInput: some View {
        VStack(spacing: 4) {
            WalletCard {
                Text("You pay").font(.subheadline).foregroundStyle(WalletStyle.purple)
                exchangeCurrency(code: coin, canChoose: initial == nil && assets.count > 1) { picker = .source }
                HStack {
                    TextField("0", text: $amount).keyboardType(.decimalPad).font(.title2)
                        .accessibilityLabel("Amount to exchange").disabled(coin.isEmpty)
                    Button("Max") { amount = balance ?? "" }.disabled(balance == nil)
                }
                if loading && coin.isEmpty {
                    WalletSkeleton(sample: "Available: 000.00 EUR")
                } else {
                    Text(balance.map { "Available: " + $0 + " " + coin } ?? "Balance unavailable").font(.caption)
                }
                if insufficient { Text("Insufficient balance.").foregroundColor(.red) }
            }
            Button {
                let previous = coin
                if validEstimate, let receive = quote?.receiveAmount { amount = receive }
                coin = target
                target = previous
            } label: {
                Image("wallet_exchange").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 22, height: 22).rotationEffect(.degrees(90)).frame(width: 44, height: 44)
                    .background(WalletStyle.card, in: Circle())
            }.accessibilityLabel("Reverse exchange")
                .disabled(initial != nil || !pairs.contains { $0.source == target && $0.target == coin })
        }
    }

    private func exchangeCurrency(code: String, canChoose: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                if code.isEmpty && loading {
                    WalletSkeleton(sample: "Currency name  BTC")
                } else if !code.isEmpty {
                    WalletCoin(code: code)
                    Text(model.portfolio?.assets.first { $0.code == code }?.name ?? code).bold()
                    Text(code).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if canChoose { Image(systemName: "chevron.down") }
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).disabled(!canChoose)
    }

    private var exchangeDestination: some View {
        WalletCard {
            Text("You receive").font(.subheadline).foregroundStyle(WalletStyle.purple)
            exchangeCurrency(code: target, canChoose: pairs.filter { $0.source == coin }.count > 1) { picker = .target }
            if let quote, validEstimate {
                Text(verbatim: quote.receiveAmount ?? "—").font(.title2.bold())
                Divider()
                ForEach(quote.details.dropFirst(2).indices, id: \.self) { i in
                    Text(quote.details[i].0 + "   " + quote.details[i].1).font(.subheadline)
                }
            } else if estimating {
                WalletSkeleton(sample: "0.00000000").font(.title2.bold())
                Divider()
                WalletSkeleton(sample: "1 BTC ≈ 000.000000 EUR")
                WalletSkeleton(sample: "Processing fee: 0.00 EUR").font(.footnote)
            } else {
                Text("Estimated amount").foregroundStyle(.secondary)
            }
        }
    }

    private var withdrawalFees: some View {
        WalletCard {
            let total = try? estimate.map {
                try MerchantWalletAPI.decimal($0.cryptoAmount) + MerchantWalletAPI.decimal($0.fee)
                    + MerchantWalletAPI.decimal($0.networkFee)
            }
            feeRow("Network fee", estimate?.networkFee)
            feeRow("Processing fee", estimate?.fee)
            Divider()
            feeRow("Total", total.map { NSDecimalNumber(decimal: $0).stringValue })
        }
    }

    private func feeRow(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if estimating {
                WalletSkeleton(sample: "0.00000000 BTC")
            } else {
                Text(verbatim: value.map { $0 + " " + coin } ?? "—")
            }
        }.font(.subheadline)
    }

    @ViewBuilder private var bankSelection: some View {
        WalletCard {
            Text("Settlement account").font(.headline)
            if loading {
                WalletSkeleton(sample: "Bank account number")
            } else if let bank {
                Button(bank.bankName) { picker = .bank }
            } else {
                Text("No bank accounts available for this currency.")
            }
        }
    }

    @ViewBuilder private var cryptoDeposit: some View {
        WalletCard {
            let current = deposit.flatMap { $0.currency == coin ? $0 : nil }
            WalletDepositQR(encoded: current?.qrCodeSvgBase64, waiting: loading) { image in
                lastQRAddress = current?.address
                qrImage = image
            }
            .id(coin)
            if let deposit = current {
                if let network = deposit.network { Text("Network: " + network) }
                copyField("Wallet address", deposit.address)
                Button {
                    picker = .shareDeposit
                } label: {
                    Label("Share deposit details", systemImage: "square.and.arrow.up")
                }
                if let second = deposit.address2, !second.isEmpty { copyField("Secondary address", second) }
                if let tag = deposit.destinationTag, !tag.isEmpty {
                    Divider()
                    copyField("Destination tag", tag)
                    Button {
                        picker = .showTag
                    } label: {
                        Label("Show destination tag QR code", systemImage: "qrcode")
                    }
                    Label("Include this tag so the deposit reaches your wallet.", systemImage: "info.circle").font(.footnote)
                }
            } else if loading {
                WalletSkeleton(sample: "Wallet address")
            }
        }
    }

    private func copyField(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.caption)
            HStack {
                Text(verbatim: value).textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Copy " + name.lowercased())
            }
        }
    }

    private var withdrawal: some View {
        WalletCard {
            HStack {
                TextField("Withdrawal address", text: $address)
                Button("Scan") { picker = .addressQR }
            }
            HStack {
                TextField("Destination tag (optional)", text: $tag)
                Button("Scan") { picker = .tagQR }
            }
            TextField("Comment (optional)", text: $comment)
            if let policy {
                Link("Terms and conditions", destination: policy.terms)
                Toggle("I agree to the terms", isOn: $agree)
            } else if loading {
                WalletSkeleton(sample: "Terms and conditions")
            }
        }.textInputAutocapitalization(.never).disableAutocorrection(true)
    }

    private var verification: some View {
        WalletCard {
            SecureField("Authenticator code", text: $code).keyboardType(.numberPad)
            if policy?.requiresEmailCode == true {
                Button(sentCode ? "Send another email code" : "Send email code") {
                    Task {
                        guard !working, let review else { return }
                        working = true
                        defer { working = false }
                        do {
                            try await model.requestWithdrawalCode(review)
                            sentCode = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
                SecureField("Email code", text: $otp).keyboardType(.numberPad)
            }
        }
    }

    @ViewBuilder private func sheet(_ item: PickerSheet) -> some View {
        switch item {
        case .source:
            let choices = page == .deposit ? (model.portfolio?.assets ?? []).filter { $0.isFiat || $0.isCrypto } : assets
            WalletCurrencyPicker(assets: choices, balances: model.balances ?? [], selection: coin) { asset in
                if page == .deposit { fiatDeposit = !asset.isCrypto }
                coin = asset.code
                amount = ""
            }
        case .target:
            let targets = Set(pairs.filter { $0.source == coin }.map(\.target))
            WalletCurrencyPicker(
                assets: (model.portfolio?.assets ?? []).filter { targets.contains($0.code) },
                balances: model.balances ?? [], selection: target
            ) {
                target = $0.code
                amount = ""
            }
        case .reporting:
            WalletOptions(title: "Reporting currency", options: ["EUR", "USD"], selection: fiat) {
                if fiatInput && fiat != $0 { amount = "" }
                fiat = $0
            }
        case .showTag:
            if let tag = deposit?.destinationTag { WalletDestinationTag(tag: tag) }
        case .shareDeposit:
            if let deposit {
                WalletDepositShare(
                    name: assetName, deposit: deposit, image: lastQRAddress == deposit.address ? qrImage : nil)
            }
        case .bank:
            VStack {
                Button("Close") { picker = nil }
                List(banks?.banks ?? []) { bank in
                    Button(bank.bankName + " · " + (bank.iban ?? String(bank.id))) {
                        bankId = bank.id
                        picker = nil
                    }
                }
            }
        case .addressQR, .tagQR:
            VStack {
                Button("Close") { picker = nil }.padding()
                WalletQRScanner { value in
                    if let value { if item == .addressQR { address = value } else { tag = value } }
                    picker = nil
                }
            }
        }
    }

    @MainActor private func loadCurrency() async {
        loading = true
        deposit = nil
        banks = nil
        policy = nil
        agree = false
        error = ""
        do {
            if page == .exchange && pairs.isEmpty {
                pairs = try await model.read { try await model.api.exchangePairs($0) }.filter {
                    initial == nil || $0.source == initial
                }
            }
            try Task.checkCancellation()
            if !assets.contains(where: { $0.code == coin }) {
                if let first = assets.first {
                    coin = first.code
                    return
                }
                error = "No currencies available."
                loading = false
                return
            }
            if page == .exchange, pair == nil { target = pairs.first { $0.source == coin }?.target ?? "" }
            if page == .deposit {
                if fiatDeposit {
                    let value = try await model.read { try await model.api.depositBanks($0, currency: coin) }
                    banks = value
                    bankId = value.banks.first?.id ?? 0
                } else {
                    deposit = try await model.read { try await model.api.depositAddress($0, currency: coin) }
                }
            } else if page == .withdraw {
                policy = try await model.read { try await model.api.withdrawalPolicy($0) }
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func updateEstimate() async {
        quote = nil
        estimate = nil
        estimatedKey = ""
        estimating = false
        guard !insufficient, let number = try? MerchantWalletAPI.decimal(normalized), number > 0 else { return }
        let key = estimateKey
        estimating = true
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            switch page {
            case .exchange:
                if let pair {
                    quote = try await model.read { try await model.api.exchangeQuote($0, pair: pair, amount: normalized) }
                }
            case .deposit:
                if fiatDeposit, let bank {
                    quote = try await model.read {
                        try await model.api.bankQuote($0, bank: bank, reference: banks?.referenceNumber, amount: normalized)
                    }
                }
            case .withdraw:
                estimate = try await model.read {
                    try await model.api.withdrawalEstimate($0, coin: coin, fiat: fiat, amount: number, fiatInput: fiatInput)
                }
            default: break
            }
            try Task.checkCancellation()
            estimatedKey = key
            error = ""
            estimating = false
            if page == .exchange && quote != nil {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                if estimateKey == key && review == nil {
                    quote = nil
                    estimatedKey = ""
                    error = "Estimate expired."
                }
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        estimating = false
    }

    @MainActor private func prepareReview() async {
        guard validEstimate, !working else { return }
        error = ""
        working = true
        defer { working = false }
        do {
            let operation: MerchantWalletAPI.Operation
            if page == .withdraw, let estimate {
                let debit = try MerchantWalletAPI.decimal(estimate.cryptoAmount)
                operation = try await model.read {
                    try await model.api.withdrawalReview(
                        $0, coin: coin, fiat: fiat, amount: debit,
                        address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                        tag: tag.trimmingCharacters(in: .whitespacesAndNewlines), comment: comment, acceptedTerms: agree)
                }
            } else if page == .exchange, let pair {
                operation = try await model.read { try await model.api.exchangeQuote($0, pair: pair, amount: normalized) }
            } else if page == .deposit, let bank {
                operation = try await model.read {
                    try await model.api.bankQuote($0, bank: bank, reference: banks?.referenceNumber, amount: normalized)
                }
            } else {
                return
            }
            try model.approve(operation)
            review = operation
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func submit(_ operation: MerchantWalletAPI.Operation) async {
        guard !working, !finished, review?.id == operation.id else { return }
        working = true
        error = ""
        defer { working = false }
        var extra: [String: String] = [:]
        if page == .withdraw {
            extra["code"] = code
            if !otp.isEmpty { extra["otp"] = otp }
        }
        do {
            try await model.execute(operation, extra: extra)
            finished = true
            message =
                page == .deposit ? "Deposit reported" : page == .withdraw ? "Withdrawal submitted" : "Exchange submitted"
            await model.load()
        } catch {
            self.error = error.localizedDescription
            review = nil
        }
    }
}

private struct WalletQRScanner: UIViewControllerRepresentable {
    let scanned: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned) }
    func makeUIViewController(context: Context) -> QRCodeScanViewController {
        let controller = QRCodeScanViewController(appearance: .framed)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QRCodeScanViewController, context: Context) {}
    final class Coordinator: NSObject, QRCodeScanDelegate {
        let scanned: (String?) -> Void
        init(_ scanned: @escaping (String?) -> Void) { self.scanned = scanned }
        func qrCodeScanViewScanned(qrCodeData: Data?, qrCodeString: String?) -> QRCodeScanOutcome {
            guard let qrCodeString, !qrCodeString.isEmpty else { return .continueScanning }
            scanned(qrCodeString)
            return .stopScanning
        }
        func qrCodeScanViewDismiss(_ qrCodeScanViewController: QRCodeScanViewController) { scanned(nil) }
    }
}
