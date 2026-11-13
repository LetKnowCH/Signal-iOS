// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import SignalServiceKit

private final class WalletRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct MerchantWalletAPI {
    struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        // Older saved sessions predate loginID. Derive their ID once and preserve it through refresh.
        var loginID: String?
        var identity: String {
            loginID ?? Data(SHA256.hash(data: Data(refreshToken.utf8))).base64EncodedString()
        }

        var automaticLinkRequested: Bool?
        var stagingLinkVerified: Bool? = nil
        var accessDeadline: Date?
        var refreshDeadline: Date?
        var sessionDeadline: Date?

        var expired: Bool {
            [refreshDeadline, sessionDeadline].compactMap { $0 }.contains { $0 <= Date() }
        }
    }

    struct Balance: Codable, Identifiable {
        var id: String { currency }
        let balance_eur: String?
        let balance_usd: String?
        let currency: String
        let balance: String
    }

    enum Failure: LocalizedError {
        case challenge(String)
        case status(Int)
        case withdrawalDenied(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .challenge: return "Enter your authenticator code."
            case .status(401): return "Your wallet session expired. Sign in again."
            case .status(403): return "Your wallet does not have permission to perform this action."
            case .withdrawalDenied(let message): return message
            case .status(422): return "Check the information you entered."
            case .status(429): return "Too many requests. Try again later."
            case .status(let code): return "The wallet service returned HTTP \(code)."
            case .invalidResponse: return "The wallet service returned an unexpected response."
            }
        }
    }

    static func canUseOfflineData(after error: Error) -> Bool {
        if case Failure.status(let status) = error { return (500...599).contains(status) }
        guard let failure = error as? URLError else { return false }
        return [
            .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .timedOut, .dataNotAllowed, .internationalRoamingOff,
        ].contains(failure.code)
    }

    private let network: URLSession
    private let directoryCredential: () async throws -> String
    init(
        configuration: URLSessionConfiguration = .ephemeral,
        directoryCredential: @escaping () async throws -> String = { try await MerchantWalletAPI.signalCredential() }
    ) {
        self.directoryCredential = directoryCredential
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        network = URLSession(configuration: configuration, delegate: WalletRedirectPolicy(), delegateQueue: nil)
    }

    // Only a build setting can choose where Signal and wallet credentials are sent.
    private func directoryURL(_ path: String) throws -> URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "LetKnowWalletDirectoryHost") as? String
        let host: String
        if let configured, !configured.isEmpty {
            host = configured
        } else {
            #if targetEnvironment(simulator)
            host = "localhost:18443"
            #else
            throw LinkError.unavailable
            #endif
        }
        guard var parts = URLComponents(string: "https://" + host), parts.host != nil, parts.path.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw LinkError.unavailable }
        parts.path = path
        guard let url = parts.url else { throw LinkError.unavailable }
        return url
    }

    func verifyWalletLink(_ session: Session) async throws {
        _ = try await directory("", fields: ["accessToken": session.accessToken], expected: 204)
    }

    func linkedEmail(for aci: String) async throws -> String {
        struct Recipient: Decodable { let email: String }
        let data = try await directory("/recipient", fields: ["aci": aci.lowercased()], expected: 200)
        return try JSONDecoder().decode(Recipient.self, from: data).email
    }

    enum LinkError: Error { case unavailable, unlinked, mismatch }

    static func signalCredential() async throws -> String {
        let signal = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(
            OWSRequestFactory.paymentsAuthenticationCredentialRequest()
        )
        struct Credential: Decodable {
            let username: String
            let password: String
        }
        let credential = try JSONDecoder().decode(Credential.self, from: signal.responseBodyData ?? Data())
        return Data((credential.username + ":" + credential.password).utf8).base64EncodedString()
    }

    private func directory(_ suffix: String, fields: [String: Any], expected: Int) async throws -> Data {
        let url = try directoryURL("/v1/wallet-link" + suffix)
        let auth = try await directoryCredential()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic " + auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await network.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case expected: return data
        case 404: throw LinkError.unlinked
        case 403: throw LinkError.mismatch
        default: throw LinkError.unavailable
        }
    }

    func linkedContacts(_ identifiers: [String]) async throws -> Set<String> {
        struct Result: Decodable { let acis: [String] }
        let data = try await directory("/contacts", fields: ["acis": identifiers], expected: 200)
        return Set(try JSONDecoder().decode(Result.self, from: data).acis.map { $0.lowercased() })
    }

    func invoiceLink(_ session: Session, shop: Int, attempt: UUID, amount: String, currency: String, customer: String)
        async throws -> (URL, Date)
    {
        var request = URLRequest(url: try directoryURL("/v1/invoices"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "storeId": shop, "attempt": attempt.uuidString.lowercased(), "amount": amount,
            "currency": currency, "customerId": customer,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await network.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        guard status == 200 else {
            struct Rejection: Decodable { let error: String? }
            let reason = try? JSONDecoder().decode(Rejection.self, from: data.prefix(4096)).error
            throw InvoiceError(status: status, reason: reason)
        }
        struct Link: Decodable {
            let orderUrl: URL
            let expiresAt: Double
        }
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard link.orderUrl.scheme == "https", link.orderUrl.host != nil, link.orderUrl.user == nil,
            link.orderUrl.password == nil
        else { throw Failure.invalidResponse }
        return (link.orderUrl, Date(timeIntervalSince1970: link.expiresAt / 1_000))
    }

    func close() { network.finishTasksAndInvalidate() }

    final class ActivityExport: Identifiable {
        let url: URL
        init(download: URL, csv: Bool) throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            url = folder.appendingPathComponent(csv ? "wallet-activity.csv" : "wallet-activity.xlsx")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do { try FileManager.default.moveItem(at: download, to: url) } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func exportActivity(_ session: Session, fields: [String: Any], csv: Bool) async throws -> ActivityExport {
        let url = URL(string: "https://monolith.letknow.com/mobile/activities/export-" + (csv ? "csv" : "xls"))!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            csv ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (file, response) = try await network.download(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        guard status == 200 else { throw Failure.status(status) }
        return try ActivityExport(download: file, csv: csv)
    }

    func request(
        _ path: String, fields: [String: Any]? = nil, bearer: String? = nil, expected: Int = 200,
        query: [URLQueryItem] = [], singleUseBody: Bool = false
    ) async throws -> Data {
        let base = URL(string: "https://monolith.letknow.com/mobile")!
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let fields {
            request.httpMethod = "POST"
            let data = try JSONSerialization.data(withJSONObject: fields)
            if singleUseBody {
                request.httpBodyStream = InputStream(data: data)
            } else {
                request.httpBody = data
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if path == "login", http.statusCode == 202 {
            struct Challenge: Decodable {
                struct Body: Decodable { let challengeId: String }
                let data: Body
            }
            let id = try JSONDecoder().decode(Challenge.self, from: bytes).data.challengeId
            guard !id.isEmpty else { throw Failure.invalidResponse }
            throw Failure.challenge(id)
        }
        if http.statusCode == 403 && path == "merchant/crypto-withdraw/estimate" {
            struct Denial: Decodable { let message: String }
            switch try? JSONDecoder().decode(Denial.self, from: bytes.prefix(4096)).message {
            case "Password change is required.":
                throw Failure.withdrawalDenied("Change your LetKnow password before withdrawing.")
            case "This action is unauthorized.":
                throw Failure.withdrawalDenied("This wallet does not have withdrawal permission.")
            default: break
            }
        }
        guard http.statusCode == expected else { throw Failure.status(http.statusCode) }
        return bytes
    }

    func login(email: String, password: String, installation: String) async throws -> Session {
        let bytes = try await request(
            "login",
            fields: [
                "email": email, "password": password, "deviceId": installation, "deviceName": "LetKnow iOS",
            ])
        return try decodeSession(bytes)
    }

    func refresh(_ session: Session) async throws -> Session {
        let bytes = try await request("refresh", fields: ["refreshToken": session.refreshToken], singleUseBody: true)
        var renewed = try decodeSession(bytes)
        renewed.loginID = session.identity
        renewed.sessionDeadline = renewed.sessionDeadline ?? session.sessionDeadline
        renewed.stagingLinkVerified = session.stagingLinkVerified
        renewed.automaticLinkRequested = session.automaticLinkRequested
        return renewed
    }

    private func decodeSession(_ bytes: Data) throws -> Session {
        struct Tokens: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: TimeInterval?
            let refreshExpiresIn: TimeInterval?
            let sessionExpiresAt: String?
        }
        struct Envelope: Decodable { let data: Tokens }
        let tokens = try JSONDecoder().decode(Envelope.self, from: bytes).data
        let now = Date()
        let session = Session(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, loginID: UUID().uuidString,
            accessDeadline: tokens.expiresIn.map(now.addingTimeInterval),
            refreshDeadline: tokens.refreshExpiresIn.map(now.addingTimeInterval),
            sessionDeadline: tokens.sessionExpiresAt.flatMap { value in
                let parser = ISO8601DateFormatter()
                if let date = parser.date(from: value) { return date }
                parser.formatOptions.insert(.withFractionalSeconds)
                return parser.date(from: value)
            })
        guard !session.accessToken.isEmpty, !session.refreshToken.isEmpty else { throw Failure.invalidResponse }
        return session
    }

    func verifyLogin(challenge: String, code: String) async throws -> Session {
        try await decodeSession(
            request("2fa/verify", fields: ["challengeId": challenge, "code": code], singleUseBody: true))
    }

    struct Asset: Codable {
        let code: String
        let name: String
        let isFiat: Bool
        let isCrypto: Bool
    }

    struct Report: Codable {
        let balances: [Balance]
        let total_balance_eur: String?
        let total_balance_usd: String?
        let rates_updated_at: Int?
    }

    struct Portfolio: Codable {
        let report: Report
        let assets: [Asset]
        let savedAt: Date
    }

    func portfolio(_ session: Session) async throws -> Portfolio {
        async let report = request("v2/merchant/get-balances", bearer: session.accessToken)
        async let catalog = request("currencies/list", bearer: session.accessToken)
        return try await Portfolio(
            report: JSONDecoder().decode(Report.self, from: report),
            assets: JSONDecoder().decode([Asset].self, from: catalog), savedAt: Date())
    }

    func balances(_ session: Session) async throws -> [Balance] {
        struct Envelope: Decodable { let balances: [Balance] }
        let bytes = try await request("v2/merchant/get-balances", bearer: session.accessToken)
        return try JSONDecoder().decode(Envelope.self, from: bytes).balances
    }

    struct Estimate: Decodable {
        let amount: String
        let currencyCode: String
        let totalFeeAmount: String
        let amountWithFee: String
    }

    struct Review {
        let id = UUID()
        let email: String
        let name: String
        let amount: String
        let estimate: Estimate
    }

    func review(_ session: Session, email: String, amount: String, currency: String) async throws -> Review {
        struct Recipient: Decodable {
            let firstName: String
            let lastName: String
        }
        let path = "merchant/internal-transfer/"
        let recipientBytes = try await request(
            path + "check-recipient", bearer: session.accessToken,
            query: [URLQueryItem(name: "email", value: email)])
        let recipient = try JSONDecoder().decode(Recipient.self, from: recipientBytes)
        let bytes = try await request(
            path + "estimate", fields: ["currencyCode": currency, "amount": amount],
            bearer: session.accessToken)
        let estimate = try JSONDecoder().decode(Estimate.self, from: bytes)
        let quoted = try Self.decimal(estimate.amount)
        let fee = try Self.decimal(estimate.totalFeeAmount)
        guard estimate.currencyCode == currency, quoted > 0, quoted == (try Self.decimal(amount)),
            try Self.decimal(estimate.amountWithFee) == quoted + fee
        else { throw Failure.invalidResponse }
        return Review(
            email: email, name: [recipient.firstName, recipient.lastName].joined(separator: " "),
            amount: amount, estimate: estimate)
    }

    func send(_ session: Session, review: Review) async throws {
        _ = try await request(
            "merchant/internal-transfer/execute",
            fields: [
                "email": review.email, "currencyCode": review.estimate.currencyCode, "amount": review.amount,
            ], bearer: session.accessToken, expected: 204, singleUseBody: true)
    }

    func logout(_ session: Session) async throws {
        _ = try await request("logout", fields: ["refreshToken": session.refreshToken], expected: 204)
    }
}
