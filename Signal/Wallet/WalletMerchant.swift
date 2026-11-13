// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network
import SignalServiceKit
import SignalUI
import SwiftUI

extension MerchantWalletAPI {
    struct InvoiceError: LocalizedError {
        let status: Int
        let reason: String?
        var errorDescription: String? {
            switch status {
            case 400, 422:
                switch reason {
                case "shop_ip_denied": return "This shop does not allow the payment service's IP address."
                case "merchant_api_disabled": return "API access is disabled for this merchant."
                case "business_account_required": return "This shop needs a business account to create payment links."
                case "currency_unavailable": return "Choose another currency. This shop cannot accept the selected currency."
                case "shop_signature_rejected": return "The provider rejected the shop signature. Check the shop settings."
                default: return "Check the amount and the shop's payment page settings."
                }
            case 401: return "Sign in again to create a payment link."
            case 403, 404: return "This shop is unavailable. Check your access and the shop settings."
            case 409:
                return
                    "Check your shop's payment orders before creating another link. The previous link could not be recovered."
            case 429: return "Too many requests. Try again later."
            default: return "Could not confirm the payment link. Retry with the same details to check this request."
            }
        }
    }

    struct Shop: Decodable, Identifiable {
        let id: Int
        let name, shop_id: String
        let status: MerchantFlag
    }
    struct MerchantFlag: Decodable {
        let active: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let bool = try? c.decode(Bool.self) {
                active = bool
                return
            }
            switch try c.decode(Int.self) {
            case 0: active = false
            case 1: active = true
            default: throw Failure.invalidResponse
            }
        }
    }
    struct ShopSettings: Decodable {
        let name, callbackUrl, ips, shopKey: String
        let callbackUrlWithdraw: String?
        let status: MerchantFlag
    }
    struct MerchantPage<Item: Decodable>: Decodable {
        let items: [Item]
        let lastPage: Int
    }

    func shops(_ session: Session, page: Int, search: String) async throws -> MerchantPage<Shop> {
        try await get(
            MerchantPage<Shop>.self, "merchant/get-stores", session: session,
            query: ["page": String(page), "perPage": "25", "searchQuery": search])
    }
}

struct WalletShops: View {
    @ObservedObject var model: MerchantWalletModel
    @State private var search = ""
    @State private var page = 1
    @State private var revision = 0
    @State private var result: MerchantWalletAPI.MerchantPage<MerchantWalletAPI.Shop>?
    @State private var error = ""
    private struct Editor: Identifiable { let id: Int }
    @State private var editor: Editor?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Shop name", text: $search).textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                    }.accessibilityLabel("Clear shop search")
                }
                Button {
                    editor = Editor(id: 0)
                } label: {
                    Image(systemName: "plus.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("Create shop")
            }
            if let result {
                if result.items.isEmpty { Text(search.isEmpty ? "No shops on this page." : "No matching shops.") }
                ForEach(result.items) { shop in
                    Button {
                        editor = Editor(id: shop.id)
                    } label: {
                        WalletCard {
                            HStack {
                                Text(shop.name).font(.headline)
                                Spacer()
                                Image(systemName: "gearshape")
                            }
                            Text(shop.status.active ? "Active" : "Inactive")
                            Text("Shop ID: " + shop.shop_id).font(.caption)
                        }
                    }.buttonStyle(.plain)
                }
                HStack {
                    if page > 1 { Button("Previous") { page -= 1 } }
                    Spacer()
                    if page < result.lastPage { Button("Next") { page += 1 } }
                }
            } else if error.isEmpty {
                WalletCard {
                    WalletSkeleton(sample: "Merchant shop")
                    WalletSkeleton(sample: "Shop ID: 0000000000000000")
                }
            }
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
                Button("Try again") { revision += 1 }
            }
        }.onChange(of: search) { _ in page = 1 }
            .task(id: [search, String(page), String(revision)]) {
                result = nil
                error = ""
                do {
                    if !search.isEmpty { try await Task.sleep(nanoseconds: 350_000_000) }
                    result = try await model.read {
                        try await model.api.shops(
                            $0, page: page, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }.sheet(item: $editor) { item in
                ShopEditor(model: model, id: item.id) {
                    revision += 1
                    editor = nil
                }
            }
    }
}

private struct ShopEditor: View {
    @ObservedObject var model: MerchantWalletModel
    let id: Int
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var callback = ""
    @State private var withdrawal = ""
    @State private var ips = ""
    @State private var signingKey = ""
    @State private var error = ""
    @State private var active = true
    @State private var reveal = false
    @State private var ready = false
    @State private var saving = false
    private func validURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return false }
        return url.host != nil
    }
    private var allowed: [String] {
        ips.isEmpty ? [] : ips.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private var validIPs: Bool {
        allowed.count <= 20 && allowed.allSatisfy { IPv4Address($0) != nil || IPv6Address($0) != nil }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(id == 0 ? "Create shop" : "Shop settings").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if ready {
                    if id != 0 {
                        Button(reveal ? "Hide signing key" : "Show signing key") { reveal.toggle() }
                        if reveal { Text(verbatim: signingKey).textSelection(.enabled).privacySensitive() }
                    }
                    WalletCard {
                        field("Shop name", $name)
                        field("Payment callback URL", $callback)
                        field("Withdrawal callback URL (optional)", $withdrawal)
                        field("Allowed IP addresses", $ips)
                        Text("Separate addresses with commas. Leave empty to allow all addresses.").font(.caption)
                        if !callback.isEmpty && !validURL(callback) {
                            Text("Enter a valid HTTP or HTTPS callback URL.").foregroundColor(.red)
                        }
                        if !validIPs { Text("Enter up to 20 valid IP addresses.").foregroundColor(.red) }
                        Toggle("Active", isOn: $active)
                    }
                    Button(saving ? "Saving…" : "Save shop") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 255 || !validIPs
                                || !validURL(callback) || (!withdrawal.isEmpty && !validURL(withdrawal)))
                } else if error.isEmpty {
                    WalletSkeleton(sample: "Show signing key")
                    WalletCard {
                        ForEach(
                            [
                                "Shop name", "Payment callback URL", "Withdrawal callback URL (optional)",
                                "Allowed IP addresses",
                            ], id: \.self
                        ) { label in
                            VStack(alignment: .leading) {
                                Text(label).font(.caption)
                                WalletSkeleton(sample: "Merchant settings").frame(minHeight: 36)
                            }
                        }
                        Text("Separate addresses with commas. Leave empty to allow all addresses.").font(.caption)
                        HStack {
                            Text("Active")
                            Spacer()
                            WalletSkeleton(sample: "Switch")
                        }
                    }
                    Button("Save shop") {}.buttonStyle(.borderedProminent).disabled(true)
                }
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                    if !ready { Button("Try again") { Task { await load() } } }
                }
            }.padding()
        }.background(WalletStyle.background).disabled(saving).interactiveDismissDisabled(saving).task { await load() }
    }
    private func field(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            TextField(title, text: value).textInputAutocapitalization(.never).disableAutocorrection(true).textFieldStyle(
                .roundedBorder)
        }
    }
    @MainActor private func load() async {
        error = ""
        do {
            if id != 0 {
                let data = try await model.read {
                    try await model.api.get(
                        MerchantWalletAPI.ShopSettings.self, "merchant/get-store", session: $0, query: ["id": String(id)])
                }
                name = data.name
                callback = data.callbackUrl
                withdrawal = data.callbackUrlWithdraw ?? ""
                ips = data.ips
                active = data.status.active
                signingKey = data.shopKey
            }
            ready = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func save() async {
        guard !saving, ready else { return }
        saving = true
        defer { saving = false }
        var fields: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "callback_url": callback.trimmingCharacters(in: .whitespacesAndNewlines), "ips": allowed.joined(separator: ","),
            "status": active,
        ]
        fields["callback_url_withdraw"] =
            withdrawal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NSNull() as Any : withdrawal.trimmingCharacters(in: .whitespacesAndNewlines)
        if id != 0 { fields["id"] = id }
        do {
            try await model.write { session in
                _ = try await model.api.request(
                    id == 0 ? "merchant/create-store" : "merchant/update-store", fields: fields,
                    bearer: session.accessToken, expected: id == 0 ? 201 : 200, singleUseBody: true)
            }
            saved()
        } catch { self.error = error.localizedDescription }
    }
}

struct WalletInvoices: View {
    struct Invoice: Identifiable, Codable {
        let url: URL
        let amount, currency, step, stepLabel: String
        var shop, customer: String
        let expires: Date
        var id: URL { url }
        func active(at date: Date) -> Bool { step == "new" && date < expires }
    }
    private struct Order: Decodable {
        let order_id, order_amount, order_currency_code, step: String
        let createdAt: Double
        let shop_name, customer_id, step_label: String?
        func invoice() throws -> Invoice {
            guard let uuid = UUID(uuidString: order_id) else { throw MerchantWalletAPI.Failure.invalidResponse }
            let url = URL(string: "https://payment.letknow.com")!.appendingPathComponent(uuid.uuidString.lowercased())
            return Invoice(
                url: url, amount: order_amount, currency: order_currency_code, step: step, stepLabel: step_label ?? "",
                shop: shop_name ?? "", customer: customer_id ?? "",
                expires: Date(timeIntervalSince1970: createdAt + 7200))
        }
    }
    @ObservedObject var model: MerchantWalletModel
    @State private var items: [Invoice] = []
    @State private var page = 1
    @State private var lastPage = 1
    @State private var revision = 0
    @State private var loading = true
    @State private var creating = false
    @State private var error = ""
    @State private var detail: Invoice?
    @State private var sharing: Invoice?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                creating = true
            } label: {
                Label("Create payment link", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).disabled(loading || model.offline)
            HStack {
                Text("Payment links").font(.headline)
                Spacer()
                Button {
                    page = 1
                    revision += 1
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Refresh payment links")
            }
            if loading && items.isEmpty {
                ForEach(0..<2) { _ in
                    WalletCard {
                        WalletSkeleton(sample: "0.00 EUR")
                        WalletSkeleton(sample: "Merchant payment link")
                    }
                }
            } else if !loading && items.isEmpty && error.isEmpty {
                WalletCard {
                    Text("No payment links yet").font(.headline)
                    Text("Create a link to request a payment in chat.")
                }
            }
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                ForEach(items) { item in
                    WalletCard {
                        Button {
                            detail = item
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.amount + " " + item.currency).font(.headline)
                                if !item.shop.isEmpty { Text(item.shop) }
                                Text(status(item, now: context.date)).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button("Share in chat") { if item.active(at: Date()) { sharing = item } }.disabled(
                            !item.active(at: context.date))
                    }
                }
            }
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
                Button("Try again") { revision += 1 }
            }
            if page < lastPage { Button(loading ? "Loading…" : "Load older links") { page += 1 }.disabled(loading) }
        }
        .task(id: [page, revision]) {
            loading = true
            error = ""
            do {
                let value = try await model.read { session in
                    try await model.api.get(
                        MerchantWalletAPI.MerchantPage<Order>.self, "merchant/payment-page/business/get-orders",
                        session: session,
                        query: [
                            "page": String(page), "perPage": "25", "dateFrom": "1", "orderBy": "created",
                            "orderByDirection": "desc",
                        ])
                }
                let rows = try value.items.map { try $0.invoice() }
                let local = (try? model.recentInvoices()) ?? []
                var merged = page == 1 ? local : items
                for row in rows {
                    if let i = merged.firstIndex(where: { $0.url == row.url }) {
                        var item = row
                        if item.shop.isEmpty { item.shop = merged[i].shop }
                        if item.customer.isEmpty { item.customer = merged[i].customer }
                        merged[i] = item
                    } else {
                        merged.append(row)
                    }
                }
                items = merged
                lastPage = value.lastPage
            } catch {
                guard !Task.isCancelled else { return }
                if MerchantWalletAPI.canUseOfflineData(after: error) {
                    if page == 1 { items = (try? model.recentInvoices()) ?? [] }
                } else if page == 1 {
                    items = []
                }
                self.error = error.localizedDescription
            }
            loading = false
        }
        .sheet(isPresented: $creating) {
            InvoiceEditor(model: model, lastShop: items.first?.shop) { item in
                items.removeAll { $0.url == item.url }
                items.insert(item, at: 0)
                creating = false
            }
        }
        .sheet(item: $detail) { item in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Payment link").font(.title2.bold())
                        Spacer()
                        Button("Close") { detail = nil }
                    }
                    Text(item.amount + " " + item.currency).font(.largeTitle.bold())
                    Text(item.shop)
                    if !item.customer.isEmpty { Text("Customer reference: " + item.customer) }
                    Text(verbatim: item.url.absoluteString).textSelection(.enabled)
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        Text(status(item, now: context.date))
                        if item.active(at: context.date) {
                            Button("Share in chat") { if item.active(at: Date()) { sharing = item } }
                        }
                    }
                }.padding()
            }.sheet(item: $sharing) { WalletShare(url: $0.url) }
        }
        .sheet(item: Binding(get: { detail == nil ? sharing : nil }, set: { sharing = $0 })) { WalletShare(url: $0.url) }
    }
    private func status(_ item: Invoice, now: Date) -> String {
        if item.active(at: now) { return "Expires " + item.expires.formatted() }
        if ["new", "expired"].contains(item.step) { return "Link expired" }
        return item.stepLabel.isEmpty ? item.step.capitalized : item.stepLabel
    }
}

private struct WalletShare: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(close: { dismiss() }) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let navigation = OWSNavigationController()
        let body = MessageBody(text: url.absoluteString, ranges: .empty)
        if let content = SendMessageUnapprovedContent(messageBody: body) {
            context.coordinator.flow = SendMessageFlow(
                unapprovedContent: content, presentationStyle: .pushOnto(navigation),
                delegate: context.coordinator)
        }
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: SendMessageDelegate {
        var flow: SendMessageFlow?
        private let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func sendMessageFlowDidComplete(threads: [TSThread]) {
            flow = nil
            close()
        }
        func sendMessageFlowDidCancel() {
            flow = nil
            close()
        }
        func sendMessageFlowWillShowConversation() { flow = nil }
    }
}

private struct InvoiceEditor: View {
    @ObservedObject var model: MerchantWalletModel
    let lastShop: String?
    let created: (WalletInvoices.Invoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shop: MerchantWalletAPI.Shop?
    @State private var shops: MerchantWalletAPI.MerchantPage<MerchantWalletAPI.Shop>?
    @State private var page = 1
    @State private var revision = 0
    @State private var amount = ""
    @State private var currency = "EUR"
    @State private var customer = ""
    @State private var error = ""
    @State private var saving = false
    @State private var attempt = UUID()
    @State private var attemptedInput: [String]?
    @State private var choosingShop = false
    private var validAmount: Bool {
        guard let value = try? MerchantWalletAPI.decimal(amount), value >= 0.01, amount.count <= 16 else { return false }
        return (amount.split(separator: ".").dropFirst().first?.count ?? 0) <= (currency == "USDT" ? 6 : 2)
    }
    private var valid: Bool {
        validAmount && shop != nil && !customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && customer.count <= 199
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("New payment link").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                WalletCard {
                    Text("Shop").font(.headline)
                    if let shops {
                        Button {
                            choosingShop.toggle()
                        } label: {
                            HStack {
                                Image(systemName: "building.2")
                                Text(shop?.name ?? "Select a shop")
                                Spacer()
                                Image(systemName: "chevron.down")
                            }
                            .frame(minHeight: 48)
                        }
                        let active = shops.items.filter { $0.status.active }
                        if choosingShop || (active.isEmpty && shop == nil) {
                            ForEach(active) { value in
                                Button {
                                    shop = value
                                    choosingShop = false
                                } label: {
                                    HStack {
                                        Image(systemName: shop?.id == value.id ? "checkmark.circle.fill" : "circle")
                                        Text(value.name)
                                        Spacer()
                                    }
                                    .frame(minHeight: 44)
                                }
                            }
                            if active.isEmpty { Text("No active shops on this page.") }
                            HStack {
                                if page > 1 { Button("Previous") { page -= 1 } }
                                Spacer()
                                if page < shops.lastPage { Button("Next") { page += 1 } }
                            }
                        }
                    } else if error.isEmpty {
                        WalletSkeleton(sample: "Merchant shop")
                    }
                }
                WalletCard {
                    Text("Request amount").bold()
                    TextField(
                        "0.00", text: Binding(get: { amount }, set: { amount = $0.replacingOccurrences(of: ",", with: ".") })
                    ).keyboardType(.decimalPad)
                    Picker("Currency", selection: $currency) { ForEach(["EUR", "USD", "USDT"], id: \.self) { Text($0) } }
                        .pickerStyle(.segmented)
                    if !amount.isEmpty && !validAmount {
                        Text("Enter at least 0.01 with up to " + (currency == "USDT" ? "6" : "2") + " decimal places.").font(
                            .footnote
                        ).foregroundStyle(.red)
                    }
                    TextField("Customer reference", text: $customer)
                    Text("The link expires after 2 hours.").font(.footnote).foregroundStyle(.secondary)
                }
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                    if shops == nil { Button("Try again") { revision += 1 } }
                }
                Button(saving ? "Creating link…" : "Create link") { Task { await create() } }.buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }.padding()
        }.background(WalletStyle.background).disabled(saving).interactiveDismissDisabled(saving)
            .task(id: [page, revision]) {
                shops = nil
                error = ""
                do {
                    let value = try await model.read { try await model.api.shops($0, page: page, search: "") }
                    shops = value
                    let active = value.items.filter { $0.status.active }
                    if page == 1, shop == nil {
                        shop =
                            active.first { $0.name == lastShop }
                            ?? (value.lastPage <= 1 && active.count == 1 ? active.first : nil)
                    }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
    @MainActor private func create() async {
        guard valid, !saving, let shop else { return }
        let reference = customer.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = [String(shop.id), amount, currency, reference]
        if attemptedInput != input {
            attempt = UUID()
            attemptedInput = input
        }
        saving = true
        defer { saving = false }
        do {
            let (url, expiry) = try await model.write {
                try await model.api.invoiceLink(
                    $0, shop: shop.id, attempt: attempt, amount: amount, currency: currency, customer: reference)
            }
            let item = WalletInvoices.Invoice(
                url: url, amount: amount, currency: currency, step: "new", stepLabel: "", shop: shop.name,
                customer: reference, expires: expiry)
            try model.rememberInvoice(item)
            created(item)
        } catch { self.error = error.localizedDescription }
    }
}
