// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension MerchantWalletAPI {
    struct ExchangePair: Identifiable, Hashable {
        let base: String
        let quoted: String
        let buy: Bool
        var source: String { buy ? quoted : base }
        var target: String { buy ? base : quoted }
        var id: String { [base, quoted, buy ? "buy" : "sell"].joined(separator: "/") }
        func fields(_ amount: String) -> [String: String] {
            [
                "baseCurrency": base, "quotedCurrency": quoted, "operationType": buy ? "buy" : "sell",
                "estimateType": buy ? "from-quoted" : "from-base", "amount": amount,
            ]
        }
    }

    struct Bank: Decodable, Identifiable {
        let id: Int
        let currencyCode: String
        let bankName: String
        let iban, swift, beneficiaryName, beneficiaryAddress, bankAddress, bankCountry, mode: String?
        let intermediaryBankName, intermediaryBankRoutingCode: String?
        var details: [(String, String)] {
            let values: [(String, String?)] = [
                ("Recipient account number", iban), ("BIC", swift), ("Beneficiary", beneficiaryName),
                ("Beneficiary address", beneficiaryAddress), ("Bank", bankName), ("Bank address", bankAddress),
                ("Bank country", bankCountry), ("Transfer method", mode),
                ("Intermediary bank", intermediaryBankName), ("Routing code", intermediaryBankRoutingCode),
            ]
            return values.compactMap { key, value in value.flatMap { $0.isEmpty ? nil : (key, $0) } }
        }
    }

    struct BankList: Decodable {
        let banks: [Bank]
        let referenceNumber: String?
    }
    struct DepositAddress: Decodable {
        let currency, address: String
        let network, address2, destinationTag, qrCodeSvgBase64: String?

        private enum CodingKeys: String, CodingKey {
            case currency, address, network, address2, destinationTag, qrCodeSvgBase64
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currency = try c.decode(String.self, forKey: .currency)
            address = try c.decode(String.self, forKey: .address)
            network = try c.decodeIfPresent(String.self, forKey: .network)
            address2 = try c.decodeIfPresent(String.self, forKey: .address2)
            qrCodeSvgBase64 = try c.decodeIfPresent(String.self, forKey: .qrCodeSvgBase64)
            if let numericTag = try? c.decode(Int64.self, forKey: .destinationTag) {
                destinationTag = String(numericTag)
            } else {
                destinationTag = try c.decodeIfPresent(String.self, forKey: .destinationTag)
            }
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, session: Session, query: [String: String] = [:]) async throws -> T
    {
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await JSONDecoder().decode(type, from: request(path, bearer: session.accessToken, query: items))
    }

    func exchangePairs(_ session: Session) async throws -> [ExchangePair] {
        struct Config: Decodable {
            struct Pair: Decodable {
                let baseCurrency, quotedCurrency: String
                let buyEnabled, sellEnabled: Bool
            }
            struct Item: Decodable {
                let key: String
                let value: [Pair]
            }
            let items: [Item]
        }
        let config = try await get(
            Config.self, "global-configuration/get-public-config-items",
            session: session, query: ["key": "public_exchange_pairs"])
        let rows = config.items.first { $0.key == "public_exchange_pairs" }?.value ?? []
        return rows.flatMap { row in
            [true, false].compactMap { buy in
                guard buy ? row.buyEnabled : row.sellEnabled else { return nil }
                return ExchangePair(base: row.baseCurrency, quoted: row.quotedCurrency, buy: buy)
            }
        }
    }

    struct Operation {
        let loginID: String
        let path: String
        let fields: [String: Any]
        let status: Int
        let title: String
        let confirm: String
        let details: [(String, String)]
        var receiveAmount: String? = nil
        let id = UUID()
        var expires: Bool { path != "merchant/create-deposit-intention" }
    }

    static func decimal(_ text: String) throws -> Decimal {
        guard text.count <= 38, text.range(of: #"^[0-9]+(\.[0-9]{1,18})?$"#, options: .regularExpression) != nil,
            let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        else { throw Failure.invalidResponse }
        return number
    }

    func exchangeQuote(_ session: Session, pair: ExchangePair, amount: String) async throws -> Operation {
        struct Response: Decodable {
            let baseCurrency, quotedCurrency, processingFeeCurrency: String
            let baseAmount, quotedAmount, baseNetAmount, quotedNetAmount: String?
            let rate, processingFeeAmount: String
        }
        let fields = pair.fields(amount)
        let quote = try await get(Response.self, "merchant/exchange/calculate", session: session, query: fields)
        let debit = pair.buy ? quote.quotedAmount : quote.baseAmount
        let credit = pair.buy ? quote.baseNetAmount : quote.quotedNetAmount
        guard let debit, let credit, quote.baseCurrency == pair.base, quote.quotedCurrency == pair.quoted,
            quote.processingFeeCurrency == pair.quoted, try Self.decimal(debit) == Self.decimal(amount),
            try Self.decimal(credit) > 0, try Self.decimal(debit) > 0,
            try Self.decimal(quote.processingFeeAmount) >= 0, try Self.decimal(quote.rate) > 0
        else { throw Failure.invalidResponse }
        return Operation(
            loginID: session.identity, path: "merchant/exchange/execute", fields: fields, status: 200,
            title: "Review exchange", confirm: "Confirm exchange",
            details: [
                ("You pay", amount + " " + pair.source), ("You receive", credit + " " + pair.target),
                ("Rate", quote.rate + " " + pair.quoted + " per " + pair.base),
                ("Processing fee", quote.processingFeeAmount + " " + pair.quoted),
            ], receiveAmount: credit)
    }

    func depositAddress(_ session: Session, currency: String) async throws -> DepositAddress {
        let value = try await get(
            DepositAddress.self, "merchant/get-crypto-deposit-address", session: session, query: ["currency": currency])
        guard value.currency == currency, !value.address.isEmpty else { throw Failure.invalidResponse }
        return value
    }

    func depositBanks(_ session: Session, currency: String) async throws -> BankList {
        let value = try await get(
            BankList.self, "merchant/get-user-banks", session: session, query: ["currencyCode": currency])
        return BankList(banks: value.banks.filter { $0.currencyCode == currency }, referenceNumber: value.referenceNumber)
    }

    func bankQuote(_ session: Session, bank: Bank, reference: String?, amount: String) async throws -> Operation {
        struct Quote: Decodable { let currencyCode, netAmount, fee, amount: String }
        let quote = try await get(
            Quote.self, "merchant/get-estimate-deposit-fee", session: session,
            query: ["bankId": String(bank.id), "amount": amount])
        let net = try Self.decimal(amount)
        let fee = try Self.decimal(quote.fee)
        guard net > 0, quote.currencyCode == bank.currencyCode, try Self.decimal(quote.netAmount) == net,
            try Self.decimal(quote.amount) == net + fee
        else { throw Failure.invalidResponse }
        let suffix = " " + bank.currencyCode
        var details =
            [("Net deposit", amount + suffix), ("Fee", quote.fee + suffix), ("Transfer amount", quote.amount + suffix)]
            + bank.details
        if let reference { details.append(("Payment reference", reference)) }
        return Operation(
            loginID: session.identity, path: "merchant/create-deposit-intention",
            fields: ["bankId": bank.id, "amount": amount], status: 201,
            title: "Bank transfer instructions", confirm: "I made the bank transfer", details: details)
    }
}

enum WalletActionError: LocalizedError {
    case previousAttempt, expired, inProgress
    var errorDescription: String? {
        switch self {
        case .inProgress: return "A wallet request is in progress. Try again when it finishes."
        case .previousAttempt:
            return "Check Activity before starting another transaction. The previous request may have reached LetKnow."
        case .expired: return "This review expired. Request a new estimate."
        }
    }
}

extension MerchantWalletAPI {
    struct WithdrawalPolicy {
        let terms: URL
        let requiresEmailCode: Bool
    }

    func withdrawalPolicy(_ session: Session) async throws -> WithdrawalPolicy {
        struct Config: Decodable {
            struct LegalLink: Decodable { let key, url: String }
            let LEGAL_LINKS: [LegalLink]
        }
        struct Profile: Decodable {
            struct Settings: Decodable { let notificationEmail: String? }
            let settings: Settings
        }
        async let profile = get(Profile.self, "merchant/get-current-user", session: session)
        let config = try await JSONDecoder().decode(Config.self, from: request("configs/list"))
        guard let raw = config.LEGAL_LINKS.first(where: { $0.key == "TERMS_AND_CONDITIONS" })?.url,
            let url = URL(string: raw), url.scheme == "https", url.host != nil
        else { throw Failure.invalidResponse }
        return try await WithdrawalPolicy(terms: url, requiresEmailCode: profile.settings.notificationEmail != nil)
    }

    struct WithdrawalEstimate: Decodable {
        let cryptoCurrency, fiatCurrency: String
        let cryptoAmount, fiatAmount, fee, networkFee: String
        func check(coin: String, fiat: String, amount: Decimal, fiatInput: Bool) throws {
            guard coin == cryptoCurrency, fiat == fiatCurrency,
                try MerchantWalletAPI.decimal(fiatInput ? fiatAmount : cryptoAmount) == amount,
                try MerchantWalletAPI.decimal(cryptoAmount) > 0,
                try MerchantWalletAPI.decimal(fee) >= 0,
                try MerchantWalletAPI.decimal(networkFee) >= 0
            else { throw Failure.invalidResponse }
        }
    }

    func withdrawalEstimate(_ session: Session, coin: String, fiat: String, amount: Decimal, fiatInput: Bool) async throws
        -> WithdrawalEstimate
    {
        let fields: [String: Any] = [
            "cryptoCurrency": coin, "fiatCurrency": fiat, "convertDirection": fiatInput ? 2 : 1,
            fiatInput ? "fiatAmount" : "cryptoAmount": NSDecimalNumber(decimal: amount),
        ]
        let data = try await request("merchant/crypto-withdraw/estimate", fields: fields, bearer: session.accessToken)
        let quote = try JSONDecoder().decode(WithdrawalEstimate.self, from: data)
        try quote.check(coin: coin, fiat: fiat, amount: amount, fiatInput: fiatInput)
        return quote
    }

    func withdrawalReview(
        _ session: Session, coin: String, fiat: String, amount: Decimal, address: String,
        tag: String, comment: String, acceptedTerms: Bool
    ) async throws -> Operation {
        guard acceptedTerms, amount > 0, !address.isEmpty else { throw Failure.invalidResponse }
        var fields: [String: Any] = [
            "cryptoCurrency": coin, "fiatCurrency": fiat, "cryptoAmount": NSDecimalNumber(decimal: amount),
            "withdrawAddress": address,
        ]
        if !tag.isEmpty { fields["withdrawDestinationTag"] = tag }
        let validation = fields.merging(["convertDirection": 1, "agreeTC": true]) { first, _ in first }
        let data = try await request("merchant/crypto-withdraw/validate", fields: validation, bearer: session.accessToken)
        let quote = try JSONDecoder().decode(WithdrawalEstimate.self, from: data)
        try quote.check(coin: coin, fiat: fiat, amount: amount, fiatInput: false)
        if !comment.isEmpty { fields["comment"] = comment }
        let total = try amount + Self.decimal(quote.fee) + Self.decimal(quote.networkFee)
        var details = [
            ("Amount", quote.cryptoAmount + " " + coin), ("Fiat value", quote.fiatAmount + " " + fiat),
            ("Address", address), ("Fee", quote.fee), ("Network fee", quote.networkFee),
            ("Total debit", NSDecimalNumber(decimal: total).stringValue + " " + coin),
        ]
        if !tag.isEmpty { details.append(("Destination tag", tag)) }
        if !comment.isEmpty { details.append(("Comment", comment)) }
        return Operation(
            loginID: session.identity, path: "merchant/crypto-withdraw", fields: fields, status: 200,
            title: "Review withdrawal", confirm: "Confirm withdrawal", details: details)
    }
}
