// SPDX-License-Identifier: AGPL-3.0-only

import SignalServiceKit
import SwiftUI

private enum WalletBrand {
    static let plum = Color(red: 78 / 255, green: 36 / 255, blue: 115 / 255)
    static let orchid = Color(red: 120 / 255, green: 67 / 255, blue: 128 / 255)
    static let gradient = LinearGradient(colors: [plum, orchid], startPoint: .bottomLeading, endPoint: .topTrailing)
}

private struct WalletSignInButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// Fold lines echo the geometry of the LetKnow mark.
private struct WalletFolds: Shape {
    func path(in rect: CGRect) -> Path {
        let crease = CGPoint(x: rect.width * 0.77, y: rect.height * 0.64)
        var path = Path()
        for (x, y) in [(0.48, -0.2), (0.90, -0.2), (1.18, 0.28), (1.06, 1.15), (0.61, 1.1)] {
            path.move(to: crease)
            path.addLine(to: CGPoint(x: rect.width * x, y: rect.height * y))
        }
        return path
    }
}

struct MerchantWalletView: View {
    @StateObject var model = MerchantWalletModel()
    @Environment(\.colorScheme) private var scheme
    @State private var choosingContact = false
    @State private var choosingSendCurrency = false
    @State private var choosingSendReporting = false
    private enum Field { case email, password, recipient, amount }
    @State private var page = WalletPage.wallets
    @State private var presentedForm: WalletPage?
    @State private var selectedAsset: String?
    @State private var reporting = "EUR"
    @State private var hidden = false
    @State private var initials = ""
    @State private var confirmSignOut = false
    @State private var confirmHistory = false
    @FocusState private var focus: Field?
    var closeWallet: (() -> Void)? = nil
    var walletTabVisible: ((Bool) -> Void)? = nil
    var chatName: String? = nil
    var chatPhone: String? = nil
    var chatACI: String? = nil
    var sendReceipt: (@MainActor (String) async -> Bool)? = nil

    private var panel: Color { scheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : .white }

    var body: some View {
        Group {
            if model.sessionExpired {
                WalletCard {
                    Text("Your wallet session expired.").font(.title2.bold())
                    Button("Sign in again") {
                        model.sessionExpired = false
                        page = .wallets
                    }
                }.padding()
            } else if model.uncertain {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Result unknown").font(.title.bold())
                        Text("Check Activity before starting another transaction.")
                        WalletHistory(model: model, hidden: false)
                        Button("I checked transaction history") { confirmHistory = true }
                    }.padding()
                }
            } else if let accepted = model.accepted, model.transferResult == nil || presentedForm == nil && chatName == nil {
                ScrollView {
                    WalletCard {
                        Label(accepted, systemImage: "checkmark.circle.fill").font(.title2.bold())
                        Text("Check Activity for the final status.")
                        Button("Done") { model.acknowledgeHistory() }.buttonStyle(.borderedProminent)
                    }.padding()
                }
            } else if model.offline {
                WalletOfflineView(
                    model: model, page: page, hidden: hidden, chat: chatName != nil, signOut: { confirmSignOut = true })
            } else if chatName == nil && page == .wallets && (model.session != nil || model.restoring) {
                VStack(spacing: 0) {
                    WalletOverview(
                        portfolio: model.portfolio, loading: model.busy || model.restoring,
                        offline: model.offline, fiat: $reporting, hidden: $hidden, initials: initials, select: select
                    ) {
                        await model.load(linkWallet: true)
                    }
                    if let message = model.message {
                        HStack {
                            Text(message).font(.footnote)
                            Button("Try again") { Task { await model.load() } }.disabled(model.busy)
                        }.padding(8)
                    }
                }
            } else if page == .asset, chatName == nil, model.session != nil, let code = selectedAsset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        WalletAssetHeader(
                            asset: model.portfolio?.assets.first { $0.code == code },
                            row: model.balances?.first { $0.currency == code }, code: code,
                            fiat: $reporting, hidden: $hidden, rates: model.portfolio?.report.rates_updated_at,
                            available: !model.offline && !model.busy, back: { select(.wallets, nil) }
                        ) { select($0, code) }
                        Text("Wallet activity").font(.headline).padding(.horizontal, 16)
                        WalletHistory(model: model, currency: code, hidden: hidden).padding(.horizontal, 16)
                    }
                }.background(WalletStyle.background).refreshable { await model.load() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if chatName == nil && page == .account {
                            Button {
                                page = .wallets
                                selectedAsset = nil
                            } label: {
                                Label("Wallets", systemImage: "chevron.left")
                            }
                        }
                        if chatName == nil && page != .wallets && model.session != nil {
                            Text(page == .account ? "Wallet account" : page.rawValue).font(.title2.bold())
                        }
                        if model.restoring {
                            WalletSkeleton(sample: "Checking wallet account")
                        } else if let receipt = model.transferResult {
                            result(receipt)
                        } else if let review = model.review {
                            reviewScreen(review)
                        } else if model.challenge != nil {
                            card {
                                Text("Two-factor authentication").font(.title2.bold())
                                SecureField("Authenticator code", text: $model.code).keyboardType(.numberPad)
                                    .textContentType(.oneTimeCode)
                                Button("Verify") { Task { await model.load(linkWallet: true) } }
                                    .disabled(model.code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) == nil)
                                Button("Use another account") {
                                    model.challenge = nil
                                    model.code = ""
                                }
                            }
                        } else if model.session == nil {
                            signIn
                        } else if chatName != nil || page == .send {
                            entryScreen
                        } else if page == .invoices {
                            WalletInvoices(model: model)
                        } else if page == .shops {
                            WalletShops(model: model)
                        } else if page == .activity {
                            WalletHistory(model: model, hidden: hidden)
                        } else {
                            walletDetails
                        }
                        if let message = model.message { Text(message).font(.footnote) }
                        if model.busy && (model.session != nil || model.challenge != nil) {
                            ProgressView(model.submitting ? "Submitting transfer…" : "Updating wallet…")
                        }
                    }.frame(maxWidth: 580).padding(16).frame(maxWidth: .infinity)
                }.background(WalletStyle.background)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chatName != nil && model.session != nil && !model.offline && !model.uncertain && model.transferResult == nil
                && model.accepted == nil
            {
                transferControls
            }
            if chatName == nil && model.session != nil && model.accepted == nil && !model.uncertain
                && (model.offline || [.wallets, .invoices, .shops, .activity].contains(page))
            {
                HStack(spacing: 2) {
                    ForEach([WalletPage.wallets, .invoices, .shops, .activity]) { item in
                        let symbol = [
                            WalletPage.wallets: "wallet.pass", .invoices: "doc.text", .shops: "building.2",
                            .activity: "clock",
                        ][item]!
                        Button {
                            page = item
                            selectedAsset = nil
                        } label: {
                            VStack {
                                Image(systemName: symbol)
                                Text(item.rawValue).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(page == item ? WalletStyle.purple.opacity(0.14) : Color.clear, in: Capsule())
                        }.accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                    if let closeWallet {
                        Button(action: closeWallet) {
                            VStack {
                                Image(systemName: "arrow.right")
                                Text("Back").font(.caption2)
                            }.frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                }.buttonStyle(.plain).padding(4).background(.regularMaterial, in: Capsule()).padding(.horizontal, 10)
            }
        }
        .tint(WalletStyle.purple)
        .navigationTitle(chatName != nil ? "Send money" : page.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(chatName == nil)
        .task {
            initials = SSKEnvironment.shared.databaseStorageRef.read { tx in
                let name = SSKEnvironment.shared.profileManagerRef.localUserProfile(tx: tx)?.filteredFullName ?? ""
                return name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first).map(String.init)
                    .joined().uppercased()
            }
            await model.open(chatACI: chatACI)
        }
        .onAppear { walletTabVisible?(model.session != nil) }
        .onChange(of: model.session != nil) { signedIn in
            walletTabVisible?(signedIn)
            if !signedIn {
                presentedForm = nil
                selectedAsset = nil
                page = .wallets
            }
        }
        .onDisappear {
            walletTabVisible?(false)
            model.leave()
        }
        .sheet(item: $presentedForm) { item in
            if item == .send {
                VStack(spacing: 0) {
                    HStack {
                        Button("Close") { presentedForm = nil }
                        Spacer()
                        Text(model.review == nil ? "Send" : "Review transfer").font(.headline)
                        Spacer()
                        Text("Close").hidden()
                    }.padding(16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let receipt = model.transferResult {
                                result(receipt)
                            } else if let review = model.review {
                                reviewScreen(review)
                            } else {
                                entryScreen
                            }
                            if let message = model.message { Text(message).foregroundStyle(.secondary) }
                        }.padding(16)
                    }
                    if model.transferResult == nil { transferControls }
                }.background(WalletStyle.background).interactiveDismissDisabled(model.busy)
                    .onChange(of: model.uncertain) { if $0 { presentedForm = nil } }
            } else {
                WalletPaymentForm(model: model, page: item, fiat: reporting, initial: selectedAsset)
            }
        }
        .sheet(isPresented: $confirmSignOut) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Sign out of your wallet?").font(.title2.bold())
                    Text("Your Signal account will stay signed in.")
                    Button("Sign out", role: .destructive) {
                        confirmSignOut = false
                        page = .wallets
                        Task { await model.signOut() }
                    }
                    Button("Cancel") { confirmSignOut = false }
                }.padding()
            }
        }
        .sheet(isPresented: $confirmHistory) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Have you checked Activity?").font(.title2.bold())
                    Text("The previous payment may have succeeded.")
                    Button("I checked Activity") {
                        model.acknowledgeHistory()
                        confirmHistory = false
                    }
                    Button("Cancel") { confirmHistory = false }
                }.padding()
            }
        }
    }

    private func select(_ destination: WalletPage, _ asset: String?) {
        selectedAsset = asset
        if WalletPage.actions.contains(destination) {
            model.startNewTransfer()
            model.review = nil
            model.sendAmount = WalletSendAmount(reportingCurrency: reporting)
            model.recipient = ""
            model.selectedContact = nil
            if let asset { model.currency = asset }
            presentedForm = destination
        } else {
            page = destination
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func hero<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased()).font(.caption.bold()).tracking(1.6)
            content()
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(.white)
        .background(WalletFolds().stroke(.white.opacity(0.13), lineWidth: 1).allowsHitTesting(false))
        .background(WalletBrand.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var signInButton: some View {
        let canSubmit = !model.email.isEmpty && !model.password.isEmpty
        let title = model.busy ? "Signing in…" : "Sign in and link wallet"
        return Button {
            focus = nil
            Task { await model.load(linkWallet: true) }
        } label: {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if model.busy {
                    ProgressView().tint(.white).accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .foregroundColor(.white).background(
                model.busy || canSubmit ? WalletBrand.plum : Color(white: 0.40),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(WalletSignInButtonStyle())
        .disabled(model.busy || !canSubmit)
    }

    private var signIn: some View {
        Group {
            Image("letknow-global").resizable().scaledToFit().frame(maxWidth: 180)
                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(
                    "LetKnow Pay Global")
            hero("LetKnow wallet") {
                Text(chatName == nil ? "Sign in to your wallet" : "Sign in to send money").font(.largeTitle.bold())
                Text("Use your LetKnow Pay account.").font(.subheadline)
            }
            card {
                Label("Wallet account", systemImage: "wallet.pass").font(.headline)
                TextField("Email", text: $model.email).keyboardType(.emailAddress).textContentType(.username)
                    .autocapitalization(.none).disableAutocorrection(true).focused($focus, equals: .email)
                    .frame(minHeight: 44)
                Divider()
                SecureField("Password", text: $model.password).textContentType(.password)
                    .focused($focus, equals: .password).frame(minHeight: 44)
            }
            Text(
                "Linking lets the staging service verify your wallet email with LetKnow once. Only LetKnow receives your password."
            )
            .font(.footnote).foregroundColor(.secondary)
            signInButton
        }
    }

    private var entryScreen: some View {
        Group {
            WalletCard {
                Text("Choose currency").font(.subheadline)
                Button {
                    choosingSendCurrency = true
                } label: {
                    HStack {
                        WalletCoin(code: model.currency)
                        Text(model.currency).bold()
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                }
                if let balance = model.balances?.first(where: { $0.currency == model.currency }) {
                    Text("Available: " + balance.balance + " " + model.currency).font(.footnote)
                } else if model.busy {
                    WalletSkeleton(sample: "Available: 0.00000000 BTC")
                }
            }
            WalletCard {
                Text("Amount to send").font(.headline)
                HStack {
                    ForEach([25, 50, 75, 100], id: \.self) { percent in
                        Button(percent == 100 ? "MAX" : String(percent) + "%") {
                            model.sendAmount.selectPercent(
                                percent, balance: model.selectedBalance, isFiat: model.selectedCurrencyIsFiat)
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(model.selectedBalance == nil)
                    }
                }
                let reporting = model.sendAmount.reportingCurrency
                let usesFiat = model.sendAmount.usesReportingCurrency
                HStack {
                    TextField("0.0", text: Binding(get: { model.sendAmount.text }, set: { model.sendAmount.edit($0) }))
                        .keyboardType(.decimalPad).font(.title2).focused($focus, equals: .amount)
                        .accessibilityLabel("Amount in " + (usesFiat ? reporting : model.currency))
                    Text(usesFiat ? reporting : model.currency)
                    Button {
                        model.sendAmount.switchUnit(model.selectedBalance, isFiat: model.selectedCurrencyIsFiat)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Switch amount currency").disabled(
                        !model.sendAmount.canSwitch(model.selectedBalance))
                }
                HStack {
                    let unit = usesFiat ? model.currency : reporting
                    let equivalent = model.sendAmount.equivalent(model.selectedBalance, isFiat: model.selectedCurrencyIsFiat)
                    Text(verbatim: equivalent.map { $0 + " " + unit } ?? "—").foregroundStyle(.secondary)
                    Spacer()
                    if !usesFiat {
                        Button {
                            choosingSendReporting = true
                        } label: {
                            Label(reporting, systemImage: "chevron.down")
                        }
                        .accessibilityLabel("Choose reporting currency")
                    }
                }
            }
            WalletCard {
                HStack {
                    Text("Recipient").font(.headline)
                    Spacer()
                    if chatName == nil { Button("Contacts") { choosingContact = true } }
                }
                if let chatName {
                    Text(chatName).bold()
                    if let chatPhone, chatPhone != chatName { Text(chatPhone).font(.subheadline) }
                    if (model.busy || model.linking) && model.linkedEmail == nil {
                        WalletSkeleton(sample: "Checking linked recipient")
                    } else {
                        Text(model.linkStatus).font(.footnote)
                    }
                    if chatACI != nil && model.linkedEmail == nil {
                        Button("Check wallet link") { Task { await model.load(linkWallet: true) } }
                    }
                } else if let contact = model.selectedContact {
                    HStack {
                        Text(contact.name)
                        Spacer()
                        Button("Use email") { model.selectedContact = nil }
                    }
                } else {
                    emailRecipient
                }
            }

        }
        .disabled(model.busy)
        .sheet(isPresented: $choosingSendReporting) {
            WalletOptions(
                title: "Reporting currency", options: ["EUR", "USD"], selection: model.sendAmount.reportingCurrency
            ) {
                model.sendAmount.reportingCurrency = $0
            }
        }
        .sheet(isPresented: $choosingSendCurrency) {
            WalletCurrencyPicker(
                assets: model.portfolio?.assets.filter { $0.isFiat || $0.isCrypto } ?? [],
                balances: model.balances ?? [], selection: model.currency
            ) { model.currency = $0.code }
        }
        .sheet(isPresented: $choosingContact) {
            WalletContactPicker(model: model) { model.selectedContact = $0 }
        }
    }

    private var transferControls: some View {
        HStack(spacing: 8) {
            if model.review != nil {
                Button("Edit") { model.review = nil }.buttonStyle(.bordered).controlSize(.large)
            } else if presentedForm == .send {
                Button("Cancel") { presentedForm = nil }.buttonStyle(.bordered).controlSize(.large)
            }
            let reviewing = model.review != nil
            Button {
                focus = nil
                Task {
                    if reviewing {
                        await model.submitTransfer(sendReceipt: sendReceipt)
                    } else {
                        await model.prepareTransfer()
                    }
                }
            } label: {
                HStack {
                    if model.busy { ProgressView().tint(.white) }
                    Text(reviewing ? "Confirm and send" : "Review transfer").bold()
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(model.uncertain || model.offline || (!reviewing && !model.canReview))
        }.padding(.horizontal, 16).padding(.vertical, 8).background(WalletStyle.card).disabled(model.busy)
    }

    private var emailRecipient: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Recipient email", text: $model.recipient).keyboardType(.emailAddress)
                .autocapitalization(.none).disableAutocorrection(true).focused($focus, equals: .recipient)
                .frame(minHeight: 44).padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            Text("Funds go to the wallet for this email address.").font(.footnote).foregroundColor(.secondary)
        }
    }

    private func reviewScreen(_ review: MerchantWalletAPI.Review) -> some View {
        Group {
            WalletCard {
                Text("You send").font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: "\(WalletStyle.exactAmount(review.amount)) \(review.estimate.currencyCode)").font(
                    .largeTitle.bold()
                ).monospacedDigit()
            }
            card {
                Label("Recipient", systemImage: "person.crop.circle").font(.headline)
                Text(verbatim: review.name).font(.title3.bold())
                Text(verbatim: review.email).textSelection(.enabled)
                Divider()
                line(
                    "Transfer fee",
                    "\(WalletStyle.exactAmount(review.estimate.totalFeeAmount)) \(review.estimate.currencyCode)")
                line(
                    "Total you pay",
                    "\(WalletStyle.exactAmount(review.estimate.amountWithFee)) \(review.estimate.currencyCode)",
                    prominent: true)
            }
            if let chatName, sendReceipt != nil {
                Label(
                    "When LetKnow accepts the payment, Signal will send a receipt to \(chatName).",
                    systemImage: "bubble.left"
                ).font(.footnote).foregroundColor(.secondary)
            }

        }
    }

    private func result(_ receipt: MerchantWalletModel.Receipt) -> some View {
        let title: String
        let note: String
        let icon: String
        switch receipt.outcome {
        case .accepted:
            (title, note, icon) = (
                "Transfer accepted", "Check Activity in LetKnow Pay for the final status.", "checkmark.circle"
            )
        case .unknown:
            (title, note, icon) = ("Transfer unconfirmed", "Check Activity in LetKnow Pay before sending again.", "clock")
        case .rejected(let code):
            (title, note, icon) = (
                "Transfer rejected", "The wallet service declined this transfer (HTTP \(code)).", "xmark.circle"
            )
        }
        return VStack(alignment: .leading, spacing: 18) {
            hero("Wallet transfer") {
                Image(systemName: icon).font(.title)
                Text(title).font(.largeTitle.bold())
            }
            card {
                line(
                    "Amount", "\(WalletStyle.exactAmount(receipt.review.amount)) \(receipt.review.estimate.currencyCode)",
                    prominent: true)
                line("Recipient", receipt.review.email)
                Divider()
                Text(note).font(.subheadline)
            }
            Button("Start a new transfer") {
                model.startNewTransfer()
            }.frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func line(_ label: String, _ value: String, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }.font(prominent ? .subheadline.bold() : .subheadline)
    }

    private var walletDetails: some View {
        Group {
            WalletCard {
                let linked = model.session?.stagingLinkVerified == true
                HStack(spacing: 12) {
                    Image("letknow_bird").resizable().frame(width: 48, height: 48).background(
                        WalletStyle.purple, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LetKnow wallet").font(.title2.bold())
                        if model.linking {
                            HStack {
                                ProgressView()
                                Text("Linking…")
                            }
                        } else {
                            Label(linked ? "Linked" : "Not linked", systemImage: linked ? "checkmark.circle.fill" : "link")
                        }
                    }
                }
                Divider()
                Text(
                    model.linking
                        ? "Checking your wallet with LetKnow."
                        : linked ? "Your contacts can send money to this wallet from a chat." : model.linkStatus
                )
                .foregroundStyle(.secondary)
                if !linked && !model.linking {
                    Text("The staging service uses your access token once to verify your wallet with LetKnow.").font(
                        .footnote)
                    Button("Link my wallet") { Task { await model.load(linkWallet: true) } }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                }
            }
            WalletCard {
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    HStack {
                        Label("Sign out of wallet", systemImage: "rectangle.portrait.and.arrow.right")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .frame(minHeight: 44)
                }.disabled(model.busy)
            }
        }
    }
}
