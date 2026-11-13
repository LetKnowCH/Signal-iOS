// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The provider charges the asset amount. A rounded reporting value is for display only.
struct WalletSendAmount {
    var reportingCurrency: String
    private(set) var text = ""
    private(set) var usesReportingCurrency = false
    private var originalAssetAmount: String?

    mutating func edit(_ value: String) {
        originalAssetAmount = nil
        text = String(value.prefix(40))
    }

    init(reportingCurrency: String) { self.reportingCurrency = reportingCurrency }

    private func number(_ raw: String?) -> Decimal? {
        guard let raw else { return nil }
        return try? MerchantWalletAPI.decimal(raw.replacingOccurrences(of: ",", with: "."))
    }

    private func ratio(_ balance: MerchantWalletAPI.Balance?) -> (units: Decimal, reported: Decimal)? {
        guard let balance, balance.currency != reportingCurrency,
            let units = number(balance.balance), units > 0,
            let reported = number(reportingCurrency == "EUR" ? balance.balance_eur : balance.balance_usd),
            reported > 0
        else { return nil }
        return (units, reported)
    }

    func canSwitch(_ balance: MerchantWalletAPI.Balance?) -> Bool { ratio(balance) != nil }

    private func rounded(_ value: Decimal, digits: Int, mode: Decimal.RoundingMode) -> String? {
        guard !value.isNaN else { return nil }
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, digits, mode)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    func equivalent(_ balance: MerchantWalletAPI.Balance?, isFiat: Bool) -> String? {
        if usesReportingCurrency, let originalAssetAmount { return originalAssetAmount }
        guard let input = number(text), input > 0 else { return nil }
        if balance?.currency == reportingCurrency { return text }
        guard let rate = ratio(balance) else { return nil }
        if usesReportingCurrency {
            return rounded(input * rate.units / rate.reported, digits: isFiat ? 2 : 8, mode: .down)
        }
        return rounded(input * rate.reported / rate.units, digits: 2, mode: .plain)
    }

    func assetAmount(_ balance: MerchantWalletAPI.Balance?, isFiat: Bool) -> String? {
        let raw = usesReportingCurrency ? equivalent(balance, isFiat: isFiat) : text
        guard let raw, let value = number(raw), value > 0 else { return nil }
        return raw.replacingOccurrences(of: ",", with: ".")
    }

    mutating func switchUnit(_ balance: MerchantWalletAPI.Balance?, isFiat: Bool) {
        guard canSwitch(balance) else { return }
        let converted = equivalent(balance, isFiat: isFiat) ?? ""
        originalAssetAmount = usesReportingCurrency ? nil : assetAmount(balance, isFiat: isFiat)
        usesReportingCurrency.toggle()
        text = converted
    }

    mutating func selectPercent(_ percent: Int, balance: MerchantWalletAPI.Balance?, isFiat: Bool) {
        guard let balance, let units = number(balance.balance) else { return }
        let precision = balance.balance.split(separator: ".").dropFirst().first?.count ?? 0
        let digits = min(18, max(isFiat ? 2 : 8, precision))
        guard let result = rounded(units * Decimal(percent) / 100, digits: digits, mode: .down) else { return }
        usesReportingCurrency = false
        edit(result)
    }
}
