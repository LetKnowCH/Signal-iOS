// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG
import CoreImage
import Foundation
@testable import SignalServiceKit
import SignalUI
import SwiftUI
import XCTest
@testable import Signal

private final class WalletStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func jsonBody() -> Data {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 512)
            var count = stream.read(&buffer, maxLength: buffer.count)
            while count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                count = stream.read(&buffer, maxLength: buffer.count)
            }
        }
        return bytes
    }

    private func jsonFields() -> [String: String]? {
        try? JSONDecoder().decode([String: String].self, from: jsonBody())
    }

    override func startLoading() {
        if let value = request.value(forHTTPHeaderField: "X-Fixture-Network-Error"), let code = Int(value) {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        let directory = request.url?.path.hasPrefix("/v1/") == true
        XCTAssertEqual(request.url?.host, directory ? "localhost" : "monolith.letknow.com")
        XCTAssertEqual(request.url?.scheme, "https")
        let result: (Int, String)
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/v1/wallet-link"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic fixture-credential")
            XCTAssertEqual(jsonFields(), ["accessToken": "funded"])
            result = (204, "")
        case ("POST", "/v1/wallet-link/recipient"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic fixture-credential")
            XCTAssertEqual(jsonFields(), ["aci": "fixture-aci"])
            result = (200, #"{"email":"recipient+stage@example.test"}"#)
        case ("POST", "/v1/wallet-link/contacts"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic fixture-credential")
            result = (200, #"{"acis":["fixture-aci"]}"#)
        case ("POST", "/mobile/activities/export-csv"), ("POST", "/mobile/activities/export-xls"):
            let csv = request.url!.path.hasSuffix("csv")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                csv ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            let fields = try? JSONSerialization.jsonObject(with: jsonBody()) as? [String: Int]
            XCTAssertEqual(fields?["dateFrom"], 1)
            result = (200, csv ? "amount,currency" : "fixture workbook")
        case ("POST", "/v1/invoices"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            let fields = (try? JSONSerialization.jsonObject(with: jsonBody())) as? [String: Any]
            if fields?["storeId"] as? Int == 1 {
                result = (
                    200,
                    #"{"orderUrl":"https://payment.letknow.com/4abf2ae5-27d2-4fdd-a121-6bf1fe30936b","expiresAt":2000000000000}"#
                )
            } else {
                result = (400, #"{"error":"shop_ip_denied"}"#)
            }
        case ("GET", "/mobile/merchant/get-stores"):
            result = (200, #"{"items":[{"id":1,"name":"Fixture shop","shop_id":"e3b2","status":1}],"lastPage":1}"#)
        case ("GET", "/mobile/merchant/get-current-user"):
            result = (200, #"{"settings":{"notificationEmail":"fixture@example.test"}}"#)
        case ("GET", "/mobile/configs/list"):
            result = (200, #"{"LEGAL_LINKS":[{"key":"TERMS_AND_CONDITIONS","url":"https://example.test/terms"}]}"#)
        case ("GET", "/mobile/global-configuration/get-public-config-items"):
            result = (
                200,
                #"{"items":[{"key":"public_exchange_pairs","value":[{"baseCurrency":"BTC","quotedCurrency":"EUR","buyEnabled":true,"sellEnabled":true}]}]}"#
            )
        case ("GET", "/mobile/merchant/get-user-banks"):
            result = (
                200,
                #"{"banks":[{"id":1,"bankName":"Fixture bank","currencyCode":"EUR","iban":"FIXTURE"}],"referenceNumber":"EXAMPLE"}"#
            )
        case ("GET", "/mobile/activities/list"):
            result = (
                200,
                #"{"data":[{"operationId":"sample","operationType":"BUY_CRYPTO_BY_WALLET","createdAt":1794500000,"status":"success","baseAmount":"0.005","baseCurrencyCode":"BTC","quotedAmount":"100","quotedCurrencyCode":"EUR"}],"hasMorePages":false}"#
            )
        case ("GET", "/mobile/merchant/payment-page/business/get-orders"):
            result = (
                200,
                #"{"items":[{"order_id":"4abf2ae5-27d2-4fdd-a121-6bf1fe30936b","order_amount":"19.99","order_currency_code":"EUR","step":"new","createdAt":1999990000,"shop_name":"Fixture shop"}],"lastPage":1}"#
            )
        case ("POST", "/mobile/login"):
            let fields = jsonFields()
            XCTAssertFalse(fields?["deviceId"]?.isEmpty ?? true)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if fields?["email"] == "funded@example.test" {
                result = (200, #"{"data":{"accessToken":"funded","refreshToken":"refresh"}}"#)
                break
            }
            result =
                fields?["email"] == "challenge@example.test"
                ? (202, #"{"data":{"challengeId":"test-challenge"}}"#)
                : (200, #"{"data":{"accessToken":"access","refreshToken":"refresh"}}"#)
        case ("POST", "/mobile/2fa/verify"):
            XCTAssertEqual(jsonFields(), ["challengeId": "challenge", "code": "123456"])
            result = (200, #"{"data":{"accessToken":"verified","refreshToken":"refresh"}}"#)
        case ("GET", "/mobile/currencies/list"):
            result = (
                200,
                #"[{"code":"BTC","name":"Bitcoin","isFiat":false,"isCrypto":true},{"code":"EUR","name":"Euro","isFiat":true,"isCrypto":false}]"#
            )
        case ("GET", "/mobile/merchant/get-crypto-deposit-address"):
            let code = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            result = (
                200,
                #"{"currency":"\#(code)","address":"fixture-deposit-address","network":"Test network","destinationTag":84730109}"#
            )
        case ("GET", "/mobile/merchant/get-estimate-deposit-fee"):
            result = (200, #"{"currencyCode":"EUR","netAmount":"100.00","amount":"101.00","fee":"1.00"}"#)
        case ("POST", "/mobile/merchant/create-deposit-intention"):
            result = (201, "{}")
        case ("GET", "/mobile/merchant/exchange/calculate"):
            result = (
                200,
                #"{"baseCurrency":"BTC","quotedCurrency":"EUR","processingFeeCurrency":"EUR","quotedAmount":"100","baseNetAmount":"0.005","rate":"20000","processingFeeAmount":"0"}"#
            )
        case ("POST", "/mobile/merchant/exchange/execute"):
            XCTAssertEqual(jsonFields()?["amount"], "100")
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case ("POST", "/mobile/merchant/crypto-withdraw/estimate"), ("POST", "/mobile/merchant/crypto-withdraw/validate"):
            result = (
                200,
                #"{"cryptoCurrency":"BTC","fiatCurrency":"EUR","cryptoAmount":"0.005","fiatAmount":"250.00","fee":"0.00005","networkFee":"0.00010"}"#
            )
        case ("GET", "/mobile/v2/merchant/get-balances"):
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer funded" {
                result = (
                    200,
                    #"{"balances":[{"currency":"BTC","balance":"1.00000000","balance_eur":"20000.00","balance_usd":"22000.00"}],"total_balance_eur":"20000.00","total_balance_usd":"22000.00","rates_updated_at":1794500000}"#
                )
                break
            }
            result =
                request.value(forHTTPHeaderField: "Authorization") == "Bearer access"
                ? (200, #"{"balances":[{"currency":"BTC","balance":"0.00000001"}]}"#)
                : (401, "{}")
        case ("GET", "/mobile/merchant/internal-transfer/check-recipient"):
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("email=recipient%2Bstage@example.test"))
            result = (200, #"{"firstName":"Test","lastName":"R."}"#)
        case ("POST", "/mobile/merchant/internal-transfer/estimate"):
            XCTAssertEqual(jsonFields(), ["amount": "0.00000001", "currencyCode": "BTC"])
            result = (
                200,
                #"{"currencyCode":"BTC","amount":"0.000000010","totalFeeAmount":"0.00000001","amountWithFee":"0.00000002"}"#
            )
        case ("POST", "/mobile/merchant/internal-transfer/execute"):
            XCTAssertTrue(
                ["Bearer access", "Bearer funded"].contains(request.value(forHTTPHeaderField: "Authorization") ?? ""))
            XCTAssertEqual(
                jsonFields(), ["email": "recipient+stage@example.test", "amount": "0.00000001", "currencyCode": "BTC"])
            result = (204, "")
        case ("POST", "/mobile/refresh"):
            XCTAssertEqual(jsonFields(), ["refreshToken": "refresh"])
            result = (200, #"{"data":{"accessToken":"rotated-access","refreshToken":"rotated-refresh"}}"#)
        case ("POST", "/mobile/logout"):
            XCTAssertTrue(["refresh", "rotated-refresh"].contains(jsonFields()?["refreshToken"] ?? ""))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            result = (204, "")
        default:
            XCTFail("Unexpected wallet request")
            result = (404, "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class WalletTestStorage: KeychainStorage {
    var values = [String: Data]()
    func dataValue(service: String, key: String) throws -> Data {
        guard let value = values[service + "/" + key] else { throw KeychainError.notFound }
        return value
    }
    func setDataValue(_ value: Data, service: String, key: String) throws { values[service + "/" + key] = value }
    func removeValue(service: String, key: String) throws { values.removeValue(forKey: service + "/" + key) }
}

final class MerchantWalletAPITests: XCTestCase {
    private func makeAPI(failingWith error: URLError.Code? = nil) -> MerchantWalletAPI {
        let config = URLSessionConfiguration.ephemeral
        if let error { config.httpAdditionalHeaders = ["X-Fixture-Network-Error": String(error.rawValue)] }
        config.protocolClasses = [WalletStub.self]
        return MerchantWalletAPI(configuration: config, directoryCredential: { "fixture-credential" })
    }

    func testLoginBalancesAndLogout() async throws {
        let api = makeAPI()
        defer { api.close() }
        let session = try await api.login(email: "wallet@example.test", password: "test", installation: "install")
        let rows = try await api.balances(session)
        XCTAssertEqual(rows.map(\.balance), ["0.00000001"])
        XCTAssertEqual(rows.map(\.currency), ["BTC"])
        try await api.logout(session)
    }

    func testChallengeDoesNotOpenWallet() async throws {
        let api = makeAPI()
        defer { api.close() }
        do {
            _ = try await api.login(email: "challenge@example.test", password: "test", installation: "install")
            XCTFail("A challenge must not open a wallet")
        } catch MerchantWalletAPI.Failure.challenge {}
    }

    func testExecuteUsesReviewedRecipientAndAmount() async throws {
        let api = makeAPI()
        defer { api.close() }
        let session = MerchantWalletAPI.Session(accessToken: "access", refreshToken: "refresh")
        let review = try await api.review(
            session, email: "recipient+stage@example.test", amount: "0.00000001", currency: "BTC")
        XCTAssertEqual(review.name, "Test R.")
        XCTAssertEqual(review.estimate.amountWithFee, "0.00000002")
        try await api.send(session, review: review)
    }

    func testRefreshReplacesBothCredentials() async throws {
        let api = makeAPI()
        defer { api.close() }
        let renewed = try await api.refresh(.init(accessToken: "expired", refreshToken: "refresh"))
        XCTAssertEqual(renewed.accessToken, "rotated-access")
        XCTAssertEqual(renewed.refreshToken, "rotated-refresh")
    }

    func testAuthenticatorCodeCompletesSignIn() async throws {
        let api = makeAPI()
        defer { api.close() }
        let session = try await api.verifyLogin(challenge: "challenge", code: "123456")
        XCTAssertEqual(session.accessToken, "verified")
    }

    func testSwitchingUnitsPreservesExactAssetAmountUntilEdited() {
        let btc = MerchantWalletAPI.Balance(balance_eur: "20000", balance_usd: "22000", currency: "BTC", balance: "1")
        var draft = WalletSendAmount(reportingCurrency: "EUR")
        draft.edit("0,00000001")
        draft.switchUnit(btc, isFiat: false)
        XCTAssertEqual(draft.text, "0")
        XCTAssertEqual(draft.assetAmount(btc, isFiat: false), "0.00000001")
        draft.switchUnit(btc, isFiat: false)
        XCTAssertEqual(draft.text, "0.00000001")
        draft.switchUnit(btc, isFiat: false)
        draft.edit("3.05")
        XCTAssertEqual(draft.assetAmount(btc, isFiat: false), "0.0001525")
        draft.selectPercent(25, balance: btc, isFiat: false)
        XCTAssertFalse(draft.usesReportingCurrency)
        XCTAssertEqual(draft.text, "0.25")
    }

    func testPresetUsesBalancePrecisionAndMissingRateDisablesConversion() {
        let coin = MerchantWalletAPI.Balance(
            balance_eur: nil, balance_usd: "0", currency: "ETH", balance: "0.000000000000000017")
        var draft = WalletSendAmount(reportingCurrency: "EUR")
        XCTAssertFalse(draft.canSwitch(coin))
        draft.selectPercent(25, balance: coin, isFiat: false)
        XCTAssertEqual(draft.text, "0.000000000000000004")
        draft.selectPercent(100, balance: coin, isFiat: false)
        XCTAssertEqual(draft.text, coin.balance)
    }

    @MainActor
    private func signIn(_ model: MerchantWalletModel) async {
        await model.open(chatACI: nil)
        model.email = "wallet@example.test"
        model.password = "fixture"
        await model.load()
        XCTAssertNotNil(model.portfolio)
    }

    @MainActor
    func testUnknownExchangeBlocksAnotherWindowAndSurvivesReopen() async throws {
        let storage = WalletTestStorage()
        let first = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "user-a" })
        await signIn(first)
        let second = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "user-a" })
        await second.open(chatACI: nil)
        let pair = MerchantWalletAPI.ExchangePair(base: "BTC", quoted: "EUR", buy: true)
        let quote = try await first.read { try await first.api.exchangeQuote($0, pair: pair, amount: "100") }
        try first.approve(quote)
        do {
            try await first.execute(quote)
            XCTFail("Lost response must require checking activity")
        } catch WalletActionError.previousAttempt {}
        XCTAssertTrue(first.uncertain)
        XCTAssertThrowsError(try second.approve(quote))
        await second.open(chatACI: nil)
        XCTAssertTrue(second.uncertain)
        second.acknowledgeHistory()
        XCTAssertFalse(second.uncertain)
        do {
            try await second.execute(quote)
            XCTFail("A reviewed operation must be consumed once")
        } catch WalletActionError.expired {}
    }

    @MainActor
    func testAccountChangeInvalidatesReviewAndKeepsNewData() async throws {
        let storage = WalletTestStorage()
        var owner = "user-a"
        let first = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { owner })
        await signIn(first)
        let second = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { owner })
        await second.open(chatACI: nil)
        let bank: MerchantWalletAPI.Bank = try JSONDecoder().decode(
            MerchantWalletAPI.Bank.self,
            from: Data(#"{"id":1,"bankName":"Bank","currencyCode":"EUR"}"#.utf8))
        let quote = try await second.read {
            try await second.api.bankQuote($0, bank: bank, reference: "reference", amount: "100")
        }
        try second.approve(quote)
        await first.signOut()
        await signIn(first)
        XCTAssertThrowsError(try second.approve(quote))
        XCTAssertThrowsError(try first.approve(quote))
        let stamp = WalletHistory.Snapshot(page: .init(data: [], hasMorePages: false), date: Date())
        try first.saveHistory(stamp)
        await second.signOut()
        XCTAssertNotNil(try first.cachedHistory())
        owner = "user-b"
        await first.open(chatACI: nil)
        XCTAssertNil(first.session)
        XCTAssertNil(first.portfolio)
        XCTAssertThrowsError(try first.cachedHistory())
    }

    func testWithdrawalReviewAndNumericDepositTag() async throws {
        let api = makeAPI()
        defer { api.close() }
        let session = MerchantWalletAPI.Session(accessToken: "access", refreshToken: "refresh")
        let deposit = try await api.depositAddress(session, currency: "XRP")
        XCTAssertEqual(deposit.destinationTag, "84730109")
        let estimate = try await api.withdrawalEstimate(session, coin: "BTC", fiat: "EUR", amount: 250, fiatInput: true)
        XCTAssertEqual(estimate.cryptoAmount, "0.005")
        let review = try await api.withdrawalReview(
            session, coin: "BTC", fiat: "EUR", amount: Decimal(string: "0.005")!,
            address: "fixture", tag: "123", comment: "Invoice", acceptedTerms: true)
        XCTAssertEqual(review.fields["withdrawDestinationTag"] as? String, "123")
        XCTAssertEqual(review.details.first { $0.0 == "Total debit" }?.1, "0.00515 BTC")
    }

    func testBrandedDepositQRRetainsProviderPayload() async throws {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("wallet-fixture:address?tag=84730109".utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let matrix = try XCTUnwrap(filter.outputImage)
        let scaled = matrix.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let original = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent.insetBy(dx: -48, dy: -48)))
        let png = try XCTUnwrap(UIImage(cgImage: original).pngData())
        let rendered = await WalletQRImage.render(png.base64EncodedString())
        let image = try XCTUnwrap(rendered)
        let payload = try XCTUnwrap(WalletQRImage.payload(original))
        XCTAssertEqual(WalletQRImage.payload(try XCTUnwrap(image.cgImage)), payload)
        let attachment = XCTAttachment(image: image)
        attachment.name = "deposit-qr"
        attachment.lifetime = .keepAlways
        add(attachment)
        let invalid = await WalletQRImage.render("not an image")
        XCTAssertNil(invalid)
    }

    @MainActor
    func testWalletOverviewLoadingAndBalanceLayouts() throws {
        let report = MerchantWalletAPI.Report(
            balances: [
                .init(balance_eur: "1250", balance_usd: "1400", currency: "BTC", balance: "0.06250000"),
                .init(balance_eur: "52.12", balance_usd: "58.37", currency: "USDTTRC20", balance: "58.37"),
            ],
            total_balance_eur: "1302.12", total_balance_usd: "1458.37", rates_updated_at: 1_794_456_000)
        let portfolio = MerchantWalletAPI.Portfolio(
            report: report,
            assets: [
                .init(code: "BTC", name: "Bitcoin", isFiat: false, isCrypto: true),
                .init(code: "USDTTRC20", name: "Tether TRC20", isFiat: false, isCrypto: true),
            ], savedAt: Date())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for loading in [true, false] {
            let view = WalletOverview(
                portfolio: loading ? nil : portfolio, loading: loading, offline: false, fiat: .constant("EUR"),
                hidden: .constant(false), select: { _, _ in }, refresh: {})
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = loading ? "wallet-loading" : "wallet-balances"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    @MainActor
    func testBankTransferNoticeSurvivesRelaunchUntilAcknowledged() async throws {
        let storage = WalletTestStorage()
        let model = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "owner" })
        await signIn(model)
        let banks = try await model.read { try await model.api.depositBanks($0, currency: "EUR") }
        let bank = try XCTUnwrap(banks.banks.first)
        let quote = try await model.read {
            try await model.api.bankQuote($0, bank: bank, reference: banks.referenceNumber, amount: "100")
        }
        try model.approve(quote)
        try await model.execute(quote)
        XCTAssertEqual(model.accepted, "Deposit reported")
        let reopened = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "owner" })
        await reopened.open(chatACI: nil)
        XCTAssertEqual(reopened.accepted, "Deposit reported")
        XCTAssertThrowsError(try reopened.approve(quote))
        reopened.acknowledgeHistory()
        XCTAssertNil(reopened.accepted)
        do {
            try await reopened.execute(quote)
            XCTFail("The acknowledged notice cannot be reported twice")
        } catch WalletActionError.expired {}
    }

    func testInvoiceDirectoryAndShopPermissions() async throws {
        let api = makeAPI()
        defer { api.close() }
        let session = MerchantWalletAPI.Session(accessToken: "access", refreshToken: "refresh")
        let shop = try await api.shops(session, page: 1, search: "Fixture")
        XCTAssertEqual(shop.items.first?.status.active, true)
        let attempt = UUID()
        let invoice = try await api.invoiceLink(
            session, shop: 1, attempt: attempt, amount: "19.99", currency: "EUR", customer: "customer")
        XCTAssertEqual(invoice.0.host, "payment.letknow.com")
        XCTAssertEqual(invoice.1.timeIntervalSince1970, 2_000_000_000)
        do {
            _ = try await api.invoiceLink(
                session, shop: 2, attempt: attempt, amount: "19.99", currency: "EUR", customer: "customer")
            XCTFail("A rejected invoice must stay rejected")
        } catch let failure as MerchantWalletAPI.InvoiceError { XCTAssertEqual(failure.reason, "shop_ip_denied") }
    }

    func testReceiptPairsAmountsWithTheirOwnCurrency() {
        let values = WalletHistory.paymentBreakdown([
            "amount": "2", "currencyCode": "EUR", "feeAmount": "0.005",
            "feeCurrencyCode": "BTC", "withdrawalNetAmount": "1.95", "withdrawalCurrencyCode": "USD",
        ])
        XCTAssertEqual(values, ["amount": "2 EUR", "feeAmount": "0.005 BTC", "withdrawalNetAmount": "1.95 USD"])
    }

    func testQRSupportsProviderSVG() async throws {
        // A real QR matrix in the small SVG coordinate system used by providers.
        let rows = [
            "1111111000010100101111111",
            "1000001001111111001000001",
            "1011101000101100101011101",
            "1011101000000111001011101",
            "1011101001010110101011101",
            "1000001011001110001000001",
            "1111111010101010101111111",
            "0000000001011010000000000",
            "1001011011111001110100000",
            "1010010101000011011001101",
            "0101111011010000011110011",
            "1000100001111011110010010",
            "1100101001011000011001000",
            "0111010111011000001100111",
            "1000011001101000011010101",
            "0111010101001111010110011",
            "1111111000110111111111111",
            "0000000010100001100010001",
            "1111111000100101101011111",
            "1000001010110100100010101",
            "1011101001011010111111000",
            "1011101011111100100011010",
            "1011101000111110000110101",
            "1000001001011100111010000",
            "1111111010010011110110011",
        ]
        let edge = rows.count + 8
        var svg =
            #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(edge)" height="\#(edge)"><rect width="100%" height="100%" fill="white"/>"#
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() where pixel == "1" {
                svg += #"<rect x="\#(x + 4)" y="\#(y + 4)" width="1" height="1"/>"#
            }
        }
        let rendered = await WalletQRImage.render(Data((svg + "</svg>").utf8).base64EncodedString())
        let image = try XCTUnwrap(rendered)
        XCTAssertNotNil(WalletQRImage.payload(try XCTUnwrap(image.cgImage)))
    }

    @MainActor
    func testPaymentAndMerchantScreensRenderWithProviderFixtures() async throws {
        let storage = WalletTestStorage()
        let model = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "owner" })
        await signIn(model)
        let displays: [(String, AnyView)] = [
            ("exchange", AnyView(WalletPaymentForm(model: model, page: .exchange, fiat: "EUR", initial: nil))),
            ("withdraw", AnyView(WalletPaymentForm(model: model, page: .withdraw, fiat: "EUR", initial: "BTC"))),
            ("deposit-fiat", AnyView(WalletPaymentForm(model: model, page: .deposit, fiat: "EUR", initial: "EUR"))),
            ("invoices", AnyView(WalletInvoices(model: model))),
            ("shops", AnyView(WalletShops(model: model))),
            ("activity", AnyView(WalletHistory(model: model, hidden: false))),
            ("offline", AnyView(WalletOfflineView(model: model, page: .wallets, hidden: false, chat: false, signOut: {}))),
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, content) in displays {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = UIHostingController(
                rootView: content.frame(maxHeight: .infinity, alignment: .top).background(WalletStyle.background))
            window.isHidden = false
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    @MainActor
    func testLinkedChatRechecksRecipientAndQueuesOneReceipt() async throws {
        let storage = WalletTestStorage()
        var eligible = true
        let model = MerchantWalletModel(
            api: makeAPI(), storage: { storage }, contactEligible: { _ in eligible }, signalAccount: { "owner" })
        await model.open(chatACI: "fixture-aci")
        model.email = "funded@example.test"
        model.password = "fixture"
        await model.load(linkWallet: true)
        XCTAssertNotNil(model.portfolio)
        for _ in 0..<100 where model.linkedEmail == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.linkedEmail, "recipient+stage@example.test")
        let contacts = try await model.api.linkedContacts(["fixture-aci"])
        XCTAssertEqual(contacts, ["fixture-aci"])
        model.sendAmount.edit("0.00000001")
        await model.prepareTransfer()
        XCTAssertNotNil(model.review)
        eligible = false
        await model.submitTransfer { _ in
            XCTFail("An ineligible contact must not receive a receipt")
            return false
        }
        XCTAssertNil(model.transferResult)
        eligible = true
        await model.load(linkWallet: true)
        for _ in 0..<100 where model.linkedEmail == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        await model.prepareTransfer()
        var queued = [String]()
        await model.submitTransfer { text in
            queued.append(text)
            return true
        }
        await model.submitTransfer { text in
            queued.append(text)
            return true
        }
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued.first?.contains("0.00000001 BTC") == true)
        XCTAssertEqual(model.accepted, "Transfer accepted")
    }

    @MainActor
    func testReviewRejectsFeeAboveCurrentBalance() async {
        let storage = WalletTestStorage()
        let model = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "owner" })
        await signIn(model)
        model.currency = "BTC"
        model.recipient = "recipient+stage@example.test"
        model.sendAmount.edit("0.00000001")
        XCTAssertTrue(model.canReview)
        await model.prepareTransfer()
        XCTAssertNil(model.review)
        XCTAssertEqual(model.message, "The amount and fee exceed your available balance.")
    }

    func testDownloadsKeepProviderExportBytesAndExtension() async throws {
        let api = makeAPI()
        defer { api.close() }
        for csv in [true, false] {
            let export = try await api.exportActivity(
                .init(accessToken: "access", refreshToken: "refresh"),
                fields: ["dateFrom": 1, "dateTo": 2], csv: csv)
            XCTAssertEqual(export.url.pathExtension, csv ? "csv" : "xlsx")
            XCTAssertEqual(try Data(contentsOf: export.url), Data((csv ? "amount,currency" : "fixture workbook").utf8))
        }
    }

    @MainActor
    func testRejectedRefreshClosesActiveWalletAndClearsCachedData() async throws {
        let storage = WalletTestStorage()
        let model = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { "owner" })
        await signIn(model)
        var reads = 0
        do {
            try await model.read { _ in
                reads += 1
                throw MerchantWalletAPI.Failure.status(401)
            }
            XCTFail("An unauthorized read must close the wallet")
        } catch MerchantWalletAPI.Failure.status(401) {}
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(model.sessionExpired)
        XCTAssertNil(model.portfolio)
        XCTAssertNil(model.session)
    }

    @MainActor
    func testOnlyTransientNetworkFailuresShowSavedBalances() async throws {
        let storage = WalletTestStorage()
        var owner = "owner"
        let online = MerchantWalletModel(api: makeAPI(), storage: { storage }, signalAccount: { owner })
        await signIn(online)
        try online.saveHistory(.init(page: .init(data: [], hasMorePages: false), date: Date()))
        let offline = MerchantWalletModel(
            api: makeAPI(failingWith: .notConnectedToInternet),
            storage: { storage }, signalAccount: { owner })
        await offline.open(chatACI: nil)
        XCTAssertTrue(offline.offline)
        XCTAssertEqual(offline.balances?.first?.currency, "BTC")
        XCTAssertNotNil(try offline.cachedHistory())
        let untrusted = MerchantWalletModel(
            api: makeAPI(failingWith: .serverCertificateUntrusted),
            storage: { storage }, signalAccount: { owner })
        await untrusted.open(chatACI: nil)
        XCTAssertFalse(untrusted.offline)
        XCTAssertNil(untrusted.portfolio)
        owner = "another-owner"
        await offline.open(chatACI: nil)
        XCTAssertNil(offline.balances)
        XCTAssertThrowsError(try offline.cachedHistory())
    }

    func testAssetHistoryIncludesBothSidesOfAnExchange() throws {
        let row = try JSONDecoder().decode(
            WalletHistory.Entry.self,
            from: Data(
                #"{"operationId":"x","operationType":"BUY_CRYPTO_BY_WALLET","createdAt":1794500000,"status":"success","baseCurrencyCode":"BTC","baseAmount":"0.005","quotedCurrencyCode":"EUR"}"#
                    .utf8))
        XCTAssertTrue(row.includes(currency: "BTC"))
        XCTAssertTrue(row.includes(currency: "EUR"))
        XCTAssertFalse(row.includes(currency: "USD"))
    }

    func testExactReviewAmountsKeepSmallUnits() {
        XCTAssertEqual(WalletStyle.exactAmount("0.000000010"), "0.00000001")
        XCTAssertEqual(WalletStyle.exactAmount("100.0000"), "100")
        XCTAssertEqual(WalletStyle.exactAmount("0.01020"), "0.0102")
    }

    func testExpiredSession() async throws {
        let api = makeAPI()
        defer { api.close() }
        do {
            _ = try await api.balances(.init(accessToken: "expired", refreshToken: "refresh"))
            XCTFail("Expired credentials must not return balances")
        } catch MerchantWalletAPI.Failure.status(401) {}
    }
}

final class WalletNavigationTests: SignalBaseTest {
    @MainActor func testHomeTabOpensWalletAndReturnsToChats() async throws {
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl)
                .registerForTests(localIdentifiers: .forUnitTests, tx: tx)
        }
        let badge = BadgeManager(
            badgeCountFetcher: DependenciesBridge.shared.badgeCountFetcher,
            databaseStorage: SSKEnvironment.shared.databaseStorageRef)
        final class FixtureHome: HomeTabBarController {
            override func viewDidLoad() {
                chatListNavController = OWSNavigationController(rootViewController: UIViewController())
                callsListNavController = OWSNavigationController(rootViewController: UIViewController())
                storiesNavController = OWSNavigationController(rootViewController: UIViewController())
                super.viewDidLoad()
            }
        }
        let home = FixtureHome(appReadiness: AppReadinessMock(), badgeManager: badge)
        home.loadViewIfNeeded()
        let controller = try XCTUnwrap(
            home.walletNavController.topViewController as? UIHostingController<MerchantWalletView>)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WalletStub.self]
        let storage = WalletTestStorage()
        let model = MerchantWalletModel(
            api: MerchantWalletAPI(configuration: config, directoryCredential: { "fixture-credential" }),
            storage: { storage }, signalAccount: { "owner" })
        await model.open(chatACI: nil)
        model.email = "funded@example.test"
        model.password = "fixture"
        await model.load()
        let route = controller.rootView
        controller.rootView = MerchantWalletView(
            model: model, closeWallet: route.closeWallet, walletTabVisible: route.walletTabVisible)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = home
        home.selectedHomeTab = .wallet
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 where !home.tabBar.isHidden { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(home.selectedHomeTab, .wallet)
        XCTAssertTrue(home.tabBar.isHidden)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "wallet-tab"
        attachment.lifetime = .keepAlways
        add(attachment)
        route.closeWallet?()
        XCTAssertEqual(home.selectedHomeTab, .chatList)
        XCTAssertFalse(home.tabBar.isHidden)
    }
}
#endif
