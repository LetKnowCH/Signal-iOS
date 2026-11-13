// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct WalletHistory: View {
    struct Entry: Codable, Identifiable {
        let operationId, operationType, status: String
        let createdAt: Int
        let amount, currencyCode, baseAmount, baseCurrencyCode, quotedAmount, quotedCurrencyCode: String?
        struct Approval: Codable {
            let currentCount, requiredCount: Int
            let isApprovedByCurrentUser: Bool
        }
        let merchantApproval: Approval?
        var id: String { operationId }

        func includes(currency: String) -> Bool {
            currencyCode == currency || baseCurrencyCode == currency || quotedCurrencyCode == currency
        }
        var amounts: [(String, String)] {
            [(currencyCode, amount), (baseCurrencyCode, baseAmount), (quotedCurrencyCode, quotedAmount)].compactMap {
                code, value in
                guard let code, let value else { return nil }
                return (code, value)
            }
        }
    }
    struct Page: Codable {
        let data: [Entry]
        let hasMorePages: Bool
    }
    struct Snapshot: Codable {
        let page: Page
        let date: Date
    }
    private struct Cell: Decodable {
        let text: String?
        enum CodingKeys: String, CodingKey { case value, isDate }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw =
                (try? c.decode(String.self, forKey: .value)) ?? (try? c.decode(Decimal.self, forKey: .value)).map {
                    NSDecimalNumber(decimal: $0).stringValue
                }
                ?? (try? c.decode(Bool.self, forKey: .value)).map { $0 ? "Yes" : "No" }
            if (try? c.decode(Bool.self, forKey: .isDate)) == true, let raw, let time = TimeInterval(raw) {
                text = Date(timeIntervalSince1970: time).formatted()
            } else {
                text = raw
            }
        }
    }
    @ObservedObject var model: MerchantWalletModel
    var currency: String?
    let hidden: Bool
    @State private var page = 1
    @State private var category = "All"
    @State private var filters = Filters()
    @State private var draft = Filters()
    @State private var filterSheet = false
    @State private var selected: Entry?
    @State private var details: [String: [String: Cell]]?
    @State private var detailError = ""
    @State private var detailRetry = 0
    @State private var snapshot: Page?
    @State private var assetEntries: [Entry] = []
    @State private var savedAt: Date?
    @State private var count: Int?
    @State private var loading = true
    @State private var error = ""
    @State private var until = Int(Date().timeIntervalSince1970)
    @State private var revision = 0
    @State private var exportFile: MerchantWalletAPI.ActivityExport?
    @State private var exportOptions = false
    @State private var saving = false
    struct Filters: Hashable {
        var days = 30
        var search = ""
        var customer = ""
        var status = ""
        var approval = ""
    }
    private let types = [
        "Deposit": "CRYPTO_DEPOSIT,MERCHANT_CRYPTO_DEPOSIT_AND_SELL,API_CRYPTO_DEPOSIT_AND_SELL",
        "Withdrawal": "CRYPTO_WITHDRAW,SELL_CRYPTO_TO_BANK,SELL_CRYPTO_TO_CARD",
        "Exchange": "BUY_CRYPTO_BY_WALLET,SELL_CRYPTO_TO_WALLET",
        "Send": "SEND_TO_USER,RECEIVE_FROM_USER", "Shop payment": "SHOP_PAYMENT",
    ]
    private var pending: Bool { category == "Awaiting approval" }
    private var query: [String: String] {
        [
            "dateFrom": String(until - filters.days * 86400), "dateTo": String(until), "types": types[category] ?? "",
            "searchQuery": filters.search, "clientInfoQuery": filters.customer, "states": filters.status,
            "approvalStates": filters.approval,
        ].filter { !$0.value.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(pending ? category : "Last " + String(filters.days) + " days").font(.headline)
                Spacer()
                Button {
                    draft = filters
                    filterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Activity filters").disabled(pending)
                Button {
                    page = 1
                    until = Int(Date().timeIntervalSince1970)
                    revision += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh activity")
                if !hidden && currency == nil && !pending {
                    Button {
                        exportOptions = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export activity").disabled(saving)
                }
            }.frame(minHeight: 44)
            if saving { ProgressView("Preparing export…") }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(
                        currency == nil
                            ? ["All", "Deposit", "Withdrawal", "Exchange", "Send", "Shop payment", "Awaiting approval"]
                            : ["All", "Deposit", "Withdrawal", "Exchange", "Send"], id: \.self
                    ) { item in
                        Button(item) {
                            category = item
                            if currency == nil { page = 1 }
                        }
                        .buttonStyle(.bordered).tint(category == item ? WalletStyle.purple : .secondary)
                    }
                }
            }
            if let savedAt { Text("Last saved " + savedAt.formatted()).font(.caption) }
            if pending, let count { Text("Pending withdrawals: " + String(count)) }
            if loading && (currency == nil || page == 1) {
                WalletCard {
                    WalletSkeleton(sample: "Transfer to wallet")
                    WalletSkeleton(sample: "0.00000 BTC")
                }.accessibilityLabel("Loading activity")
            } else if let snapshot {
                let rows =
                    currency == nil
                    ? snapshot.data
                    : assetEntries.filter { row in
                        category == "All"
                            || types[category]?.split(separator: ",").contains(Substring(row.operationType)) == true
                    }
                if rows.isEmpty {
                    Text(
                        snapshot.hasMorePages
                            ? "No matching activity on the pages loaded." : "No matching activity in this period."
                    ).foregroundColor(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        selected = row
                    } label: {
                        WalletCard {
                            HStack {
                                Text(Self.readable(row.operationType)).font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            Text(
                                row.status.capitalized + " · "
                                    + Date(timeIntervalSince1970: Double(row.createdAt)).formatted()
                            ).font(.caption)
                            ForEach(row.amounts.indices, id: \.self) { i in
                                Text(hidden ? "••••" : row.amounts[i].1 + " " + row.amounts[i].0)
                            }
                            if let progress = row.merchantApproval {
                                Text("Approvals: " + String(progress.currentCount) + "/" + String(progress.requiredCount))
                                if progress.isApprovedByCurrentUser {
                                    Text("You initiated or approved this withdrawal.").font(.caption)
                                }
                            }
                        }
                    }.buttonStyle(.plain)
                }
                HStack {
                    if currency == nil && page > 1 { Button("Previous") { page -= 1 } }
                    Spacer()
                    if snapshot.hasMorePages && savedAt == nil {
                        Button(currency == nil ? "Next" : "Load more activity") { page += 1 }.disabled(
                            loading || !error.isEmpty)
                    }
                }
            }
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
                Button("Try again") { revision += 1 }
            }
        }
        .task(
            id: [String(page), currency == nil ? category : "", String(until), String(revision), currency ?? ""].joined(
                separator: "|")
        ) { await load() }
        .sheet(isPresented: $filterSheet) {
            NavigationView {
                Form {
                    TextField("Transaction search", text: $draft.search)
                    TextField("Customer or shop", text: $draft.customer)
                    Picker("Period", selection: $draft.days) {
                        ForEach([7, 30, 90], id: \.self) { Text(String($0) + " days").tag($0) }
                    }
                    Picker("Status", selection: $draft.status) {
                        ForEach(
                            [
                                "", "pending", "success", "error", "cancelled", "approval-pending", "new", "processing",
                                "confirmed",
                            ], id: \.self
                        ) { Text($0.isEmpty ? "All" : $0).tag($0) }
                    }
                    Picker("Approval", selection: $draft.approval) {
                        ForEach(["", "no-approval", "pending", "success", "rejected"], id: \.self) {
                            Text($0.isEmpty ? "All" : $0).tag($0)
                        }
                    }
                    Button("Apply") {
                        filters = draft
                        page = 1
                        revision += 1
                        filterSheet = false
                    }
                }.navigationTitle("Activity filters").toolbar { Button("Close") { filterSheet = false } }
            }.navigationViewStyle(.stack)
        }
        .sheet(item: $selected) { row in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Transaction details").font(.title2.bold())
                        Spacer()
                        Button("Close") { selected = nil }
                    }
                    if hidden {
                        Text(Self.readable(row.operationType))
                        Text("Balances are hidden.")
                    } else if !detailError.isEmpty {
                        Text(detailError)
                        Button("Try again") { detailRetry += 1 }
                    } else {
                        receipt(row)
                    }
                }.padding()
            }.background(WalletStyle.background).task(id: row.id + String(detailRetry)) {
                details = nil
                detailError = ""
                guard !hidden else { return }
                do {
                    details = try await model.read {
                        try await model.api.get(
                            [String: [String: Cell]].self, "activities/detail", session: $0, query: ["operationId": row.id])
                    }
                } catch { if !Task.isCancelled { detailError = error.localizedDescription } }
            }
        }
        .sheet(isPresented: $exportOptions) {
            WalletOptions(title: "Export activity", options: ["CSV", "XLSX"], selection: "") { format in
                Task { await export(csv: format == "CSV") }
            }
        }
        .sheet(item: $exportFile) { file in
            WalletExportPicker(file: file)
        }
    }

    static func readable(_ key: String) -> String {
        let labels = [
            "transactionDetails": "Payment breakdown", "counterpartyDetails": "Other party", "payerDetails": "Payer",
            "clientDetails": "Customer", "blockchainDetails": "Blockchain", "operationDetails": "Reference",
            "operationId": "Transaction ID", "referenceId": "Reference ID", "ownerFullName": "Account holder",
            "initiatorFullName": "Initiated by", "counterpartyFullName": "Name", "counterpartyEmail": "Email",
            "feeAmount": "Fee", "processingFeeAmount": "Processing fee", "networkFeeAmount": "Network fee",
            "SEND_TO_USER": "Outgoing transfer", "RECEIVE_FROM_USER": "Incoming transfer",
            "CRYPTO_WITHDRAW": "Crypto withdrawal",
        ]
        if let label = labels[key] { return label }
        let words = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func paymentBreakdown(_ fields: [String: String]) -> [String: String] {
        var result = fields
        var units = Set<String>()
        for (field, value) in fields {
            let candidates: [String]
            switch field {
            case "amount": candidates = ["amountCurrencyCode", "currencyCode"]
            case "withdrawalNetAmount": candidates = ["withdrawalNetAmountCurrencyCode", "withdrawalCurrencyCode"]
            default:
                guard field.hasSuffix("Amount") else { continue }
                candidates = [field + "CurrencyCode", String(field.dropLast(6)) + "CurrencyCode"]
            }
            if let key = candidates.first(where: { fields[$0] != nil }), let unit = fields[key] {
                result[field] = value + " " + unit
                units.insert(key)
            }
        }
        for key in units { result[key] = nil }
        return result
    }

    @ViewBuilder private func receipt(_ row: Entry) -> some View {
        let operation = details?["operationDetails"]?.compactMapValues(\.text) ?? [:]
        let breakdown = Self.paymentBreakdown(details?["transactionDetails"]?.compactMapValues(\.text) ?? [:])
        let primary = ["amount", "withdrawalAmount", "depositAmount"].first { breakdown[$0] != nil }
        let state = operation["operationState"] ?? row.status
        let loading = details == nil
        VStack(alignment: .leading, spacing: 6) {
            receiptText(
                Self.readable(operation["operationType"] ?? row.operationType), sample: "Outgoing transfer", loading: loading
            )
            .font(.headline)
            if loading || primary != nil {
                receiptText(primary.flatMap { breakdown[$0] } ?? "", sample: "000.00 EUR", loading: loading).font(
                    .title2.bold())
            }
            receiptText(
                state.lowercased() == "success" ? "Completed" : Self.readable(state), sample: "Completed", loading: loading
            )
            .font(.subheadline.bold())
            receiptText(
                operation["operationCreated"] ?? Date(timeIntervalSince1970: Double(row.createdAt)).formatted(),
                sample: Date(timeIntervalSince1970: 0).formatted(), loading: loading
            ).font(.subheadline)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white).background(WalletStyle.purple, in: RoundedRectangle(cornerRadius: 20))
        if let details {
            let priority = [
                "transactionDetails", "counterpartyDetails", "payerDetails", "clientDetails", "blockchainDetails",
                "operationDetails",
            ]
            let order = priority + details.keys.filter { !priority.contains($0) }.sorted()
            ForEach(order, id: \.self) { section in
                let fields =
                    section == "transactionDetails"
                    ? breakdown.filter { $0.key != primary }
                    : (details[section]?.compactMapValues(\.text) ?? [:]).filter {
                        section != "operationDetails"
                            || !["operationType", "operationState", "operationCreated"].contains($0.key)
                    }
                if !fields.isEmpty { receiptSection(Self.readable(section), rows: fields, loading: false) }
            }
            if details.isEmpty { Text("No details available.") }
        } else {
            receiptSection("Payment breakdown", rows: ["Fee": "0.00 EUR", "Net amount": "000.00 EUR"], loading: true)
            receiptSection("Payer", rows: ["Account holder": "Account name", "Initiated by": "Account name"], loading: true)
            receiptSection("Reference", rows: ["Transaction ID": "0000000000000000"], loading: true)
        }
    }

    @ViewBuilder private func receiptText(_ value: String, sample: String, loading: Bool) -> some View {
        if loading { WalletSkeleton(sample: sample) } else { Text(verbatim: value).textSelection(.enabled) }
    }

    private func receiptSection(_ title: String, rows: [String: String], loading: Bool) -> some View {
        WalletCard {
            Text(title).font(.headline)
            ForEach(rows.keys.sorted(), id: \.self) { key in
                let value = rows[key] ?? ""
                HStack(alignment: .firstTextBaseline) {
                    Text(loading ? key : Self.readable(key)).foregroundStyle(.secondary)
                    Spacer()
                    receiptText(value, sample: value, loading: loading).multilineTextAlignment(.trailing)
                }.font(.subheadline)
            }
        }
    }

    @MainActor private func load() async {
        error = ""
        savedAt = nil
        loading = true
        count = nil
        if currency == nil || page == 1 {
            snapshot = nil
            assetEntries = []
        }
        let canCache = !pending && page == 1 && (currency != nil || category == "All") && filters == Filters()
        do {
            var parameters = query
            if currency != nil { parameters.removeValue(forKey: "types") }
            let paging = ["page": String(page), "perPage": "50"]
            let value = try await model.read { session in
                try await model.api.get(
                    Page.self, pending ? "activities/pending-approval" : "activities/list", session: session,
                    query: pending ? paging : parameters.merging(paging) { _, v in v })
            }
            snapshot = value
            if let currency {
                var seen = Set(assetEntries.map(\.id))
                assetEntries += value.data.filter { row in
                    row.includes(currency: currency) && seen.insert(row.id).inserted
                }
            }
            if canCache { try model.saveHistory(Snapshot(page: value, date: Date())) }
            if pending {
                struct Count: Decodable { let count: Int }
                count = try await model.read {
                    try await model.api.get(Count.self, "activities/pending-approval/count", session: $0).count
                }
            }
        } catch {
            if Task.isCancelled { return }
            if MerchantWalletAPI.canUseOfflineData(after: error), canCache, let cached = try? model.cachedHistory() {
                snapshot = cached.page
                savedAt = cached.date
                if let currency { assetEntries = cached.page.data.filter { $0.includes(currency: currency) } }
            }
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor private func export(csv: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            var fields: [String: Any] = query
            fields["dateFrom"] = until - filters.days * 86400
            fields["dateTo"] = until
            exportFile = try await model.read { try await model.api.exportActivity($0, fields: fields, csv: csv) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct WalletExportPicker: UIViewControllerRepresentable {
    let file: MerchantWalletAPI.ActivityExport
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(close: { dismiss() }) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { close() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { close() }
    }
}
