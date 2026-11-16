// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import SignalServiceKit
import SwiftUI

@MainActor
final class MerchantWalletModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var session: MerchantWalletAPI.Session?
    @Published private(set) var portfolio: MerchantWalletAPI.Portfolio?
    @Published private(set) var restoring = true
    @Published private(set) var offline = false
    @Published var sessionExpired = false
    @Published var challenge: String?
    @Published var code = ""
    var balances: [MerchantWalletAPI.Balance]? { portfolio?.report.balances }
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    let api: MerchantWalletAPI
    private let storage: () -> any KeychainStorage
    private let contactEligible: (String) -> Bool
    private let signalAccount: () -> String?
    init(
        api: MerchantWalletAPI = MerchantWalletAPI(),
        storage: @escaping () -> any KeychainStorage = { SSKEnvironment.shared.databaseStorageRef.keychainStorage },
        contactEligible: @escaping (String) -> Bool = WalletContact.stillEligible,
        signalAccount: @escaping () -> String? = {
            DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci.serviceIdString
        }
    ) {
        self.api = api
        self.storage = storage
        self.contactEligible = contactEligible
        self.signalAccount = signalAccount
    }
    private var closed = false

    deinit { api.close() }

    private var installation: String {
        let key = "LetKnow.MerchantWallet.InstallationID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private var keychain: any KeychainStorage { storage() }
    private let service = "LetKnow.MobileWallet"
    private var openedOwner: String?
    private var accountKey: String? {
        guard let id = signalAccount() else { return nil }
        return Data(SHA256.hash(data: Data((installation + id).utf8))).base64EncodedString()
    }
    // A rotating refresh token must be consumed only once, even if another wallet view opens.
    private static var renewals: [String: Task<MerchantWalletAPI.Session, Error>] = [:]

    private func currentSession() throws -> MerchantWalletAPI.Session {
        guard !closed, let session, let stored = try saved(), stored.identity == session.identity else {
            throw MerchantWalletAPI.Failure.status(401)
        }
        return stored
    }

    private func cacheKey() throws -> String {
        guard let owner = openedOwner, owner == accountKey else { throw MerchantWalletAPI.Failure.status(401) }
        return try owner + "." + currentSession().identity
    }

    func recentInvoices() throws -> [WalletInvoices.Invoice] {
        do {
            let bytes = try keychain.dataValue(service: service + ".Invoices", key: cacheKey())
            return try JSONDecoder().decode([WalletInvoices.Invoice].self, from: bytes)
        } catch KeychainError.notFound { return [] }
    }

    func rememberInvoice(_ item: WalletInvoices.Invoice) throws {
        var rows = try recentInvoices().filter { $0.url != item.url }
        rows.insert(item, at: 0)
        try keychain.setDataValue(
            JSONEncoder().encode(Array(rows.prefix(100))), service: service + ".Invoices", key: cacheKey())
    }

    func cachedHistory() throws -> WalletHistory.Snapshot? {
        do {
            let bytes = try keychain.dataValue(service: service + ".Activity", key: cacheKey())
            return try JSONDecoder().decode(WalletHistory.Snapshot.self, from: bytes)
        } catch KeychainError.notFound { return nil }
    }

    func saveHistory(_ snapshot: WalletHistory.Snapshot) throws {
        try keychain.setDataValue(JSONEncoder().encode(snapshot), service: service + ".Activity", key: cacheKey())
    }

    private func saved() throws -> MerchantWalletAPI.Session? {
        guard let accountKey, accountKey == openedOwner else { throw MerchantWalletAPI.Failure.invalidResponse }
        do {
            let bytes = try keychain.dataValue(service: service, key: accountKey)
            return try JSONDecoder().decode(MerchantWalletAPI.Session.self, from: bytes)
        } catch KeychainError.notFound { return nil }
    }

    private func save(_ value: MerchantWalletAPI.Session) throws {
        guard let accountKey, accountKey == openedOwner else { throw MerchantWalletAPI.Failure.invalidResponse }
        try keychain.setDataValue(JSONEncoder().encode(value), service: service, key: accountKey)
        session = value
    }

    func read<T>(_ operation: (MerchantWalletAPI.Session) async throws -> T) async throws -> T {
        let session = try currentSession()
        let result: T
        do {
            result = try await readWithRefresh(session, read: operation)
        } catch MerchantWalletAPI.Failure.status(401) {
            if !closed, self.session?.identity == session.identity, openedOwner == accountKey {
                await endSession()
                sessionExpired = self.session == nil
            }
            throw MerchantWalletAPI.Failure.status(401)
        }
        try Task.checkCancellation()
        guard try currentSession().identity == session.identity else { throw CancellationError() }
        return result
    }

    func write<T>(_ operation: (MerchantWalletAPI.Session) async throws -> T) async throws -> T {
        let stored = try currentSession()
        guard !stored.expired else { throw MerchantWalletAPI.Failure.status(401) }
        guard !busy, let owner = openedOwner, !Self.executingOwners.contains(owner) else {
            throw WalletActionError.inProgress
        }
        guard !uncertain, try !hasPendingOperation() else { throw WalletActionError.previousAttempt }
        Self.executingOwners.insert(owner)
        busy = true
        defer {
            busy = false
            Self.executingOwners.remove(owner)
        }
        let session = (stored.accessDeadline ?? .distantFuture) <= Date() ? try await renew(stored) : stored
        let result = try await operation(session)
        guard try currentSession().identity == session.identity else { throw CancellationError() }
        return result
    }

    private var chatACI: String?
    @Published private(set) var linkedEmail: String?
    private var linkTask: Task<Void, Never>?
    @Published private(set) var linking = false
    @Published private(set) var linkStatus = "Checking wallet link…"

    func open(chatACI: String?) async {
        self.chatACI = chatACI
        linkTask?.cancel()
        linking = false
        if openedOwner != accountKey {
            email = ""
            code = ""
            password = ""
            challenge = nil
            recipient = ""
            sendAmount = WalletSendAmount(reportingCurrency: "EUR")
        }
        openedOwner = accountKey
        session = nil
        restoring = true
        message = nil
        sessionExpired = false
        portfolio = nil
        offline = false
        uncertain = false
        accepted = nil
        linkedEmail = nil
        selectedContact = nil
        review = nil
        transferResult = nil
        closed = false
        defer { restoring = false }
        do {
            session = try saved()
            if let session {
                try restoreOutcome()
                if session.expired {
                    await endSession()
                    sessionExpired = true
                    return
                }
                if let bytes = try? keychain.dataValue(service: service + ".Portfolio", key: cacheKey()) {
                    portfolio = try? JSONDecoder().decode(MerchantWalletAPI.Portfolio.self, from: bytes)
                }
                restoring = false
                await load()
            } else {
                portfolio = nil
            }
        } catch { message = "Could not open the saved wallet session." }
    }

    private func renew(_ previous: MerchantWalletAPI.Session) async throws -> MerchantWalletAPI.Session {
        guard let current = try saved(), current.identity == previous.identity else {
            throw MerchantWalletAPI.Failure.status(401)
        }
        if current.refreshToken != previous.refreshToken {
            session = current
            return current
        }
        let token = previous.refreshToken
        if let pending = Self.renewals[token] {
            let value = try await pending.value
            guard try currentSession().identity == value.identity else { throw CancellationError() }
            session = value
            return value
        }
        let pending = Task { @MainActor in
            let next = try await api.refresh(previous)
            guard !next.expired else { throw MerchantWalletAPI.Failure.status(401) }
            guard try saved()?.refreshToken == token else { throw MerchantWalletAPI.Failure.status(401) }
            try save(next)
            return next
        }
        Self.renewals[token] = pending
        defer { Self.renewals[token] = nil }
        return try await pending.value
    }

    private func readWithRefresh<T>(
        _ current: MerchantWalletAPI.Session, read: (MerchantWalletAPI.Session) async throws -> T
    ) async throws -> T {
        guard !current.expired else { throw MerchantWalletAPI.Failure.status(401) }
        if let deadline = current.accessDeadline, deadline <= Date() { return try await read(try await renew(current)) }
        do { return try await read(current) } catch MerchantWalletAPI.Failure.status(401) {
            return try await read(try await renew(current))
        }
    }

    private static var signingIn = Set<String>()

    private func signIn(owner: String, linkWallet: Bool) async throws {
        guard owner == accountKey else { throw CancellationError() }
        if let existing = try saved() {
            password = ""
            code = ""
            challenge = nil
            session = existing
            try restoreOutcome()
            return
        }
        guard Self.signingIn.insert(owner).inserted else { throw WalletActionError.inProgress }
        defer { Self.signingIn.remove(owner) }
        var result: MerchantWalletAPI.Session
        if let challenge {
            result = try await api.verifyLogin(challenge: challenge, code: code)
        } else {
            let credential = password
            password = ""
            result = try await api.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: credential, installation: installation)
        }
        guard !closed, !Task.isCancelled, owner == accountKey, owner == openedOwner else {
            try? await api.logout(result)
            throw CancellationError()
        }
        challenge = nil
        code = ""
        result.automaticLinkRequested = linkWallet
        do {
            try save(result)
            try restoreOutcome()
        } catch {
            try? await api.logout(result)
            throw error
        }
    }

    func load(linkWallet: Bool = false) async {
        guard !closed, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        let owner = openedOwner
        let initialLogin = session?.identity
        do {
            if session == nil {
                guard let owner else { throw MerchantWalletAPI.Failure.invalidResponse }
                try await signIn(owner: owner, linkWallet: linkWallet)
            }
            if session != nil {
                let value = try await read(api.portfolio)
                if !closed {
                    portfolio = value
                    offline = false
                    try? keychain.setDataValue(JSONEncoder().encode(value), service: service + ".Portfolio", key: cacheKey())
                    if !currencies.contains(currency) || selectedBalance == nil {
                        if let code = value.report.balances.first(where: { currencies.contains($0.currency) })?.currency
                            ?? currencies.first
                        {
                            currency = code
                        }
                    }
                    linkTask?.cancel()
                    linkTask = Task { await checkLink(verify: linkWallet) }
                }
            }
        } catch MerchantWalletAPI.Failure.challenge(let id) {
            guard !closed, owner == accountKey, !Task.isCancelled else { return }
            challenge = id
            code = ""
        } catch let error as URLError {
            guard !closed, owner == accountKey, !Task.isCancelled else { return }
            offline = session != nil && MerchantWalletAPI.canUseOfflineData(after: error)
            if !offline { portfolio = nil }
            message = error.localizedDescription
        } catch MerchantWalletAPI.Failure.status(401) {
            guard !closed, owner == accountKey, !Task.isCancelled else { return }
            if session != nil {
                await endSession()
                sessionExpired = true
                message = MerchantWalletAPI.Failure.status(401).localizedDescription
            } else if initialLogin == nil, !sessionExpired {
                message = challenge == nil ? "Check your email and password." : "Check your authenticator code."
            }
        } catch is CancellationError {
            return
        } catch {
            guard !closed, owner == accountKey, !Task.isCancelled else { return }
            offline = session != nil && MerchantWalletAPI.canUseOfflineData(after: error)
            if !offline { portfolio = nil }
            message = error.localizedDescription
        }
    }

    private func checkLink(verify: Bool) async {
        guard !Task.isCancelled, let session, !closed else { return }
        linkedEmail = nil
        linking = true
        defer { if !Task.isCancelled { linking = false } }
        do {
            if session.stagingLinkVerified != true {
                guard verify || session.automaticLinkRequested == true else {
                    linkStatus = "Link your wallet to receive payments in Signal."
                    return
                }
                try await api.verifyWalletLink(session)
                guard !closed, !Task.isCancelled, var current = try saved(), current.refreshToken == session.refreshToken
                else { return }
                current.automaticLinkRequested = false
                current.stagingLinkVerified = true
                try save(current)
            }
            if let chatACI {
                let resolved = try await api.linkedEmail(for: chatACI)
                guard !Task.isCancelled, !closed, self.chatACI == chatACI, try currentSession().identity == session.identity
                else { return }
                linkedEmail = resolved
            }
            linkStatus = "Linked LetKnow wallet"
        } catch MerchantWalletAPI.LinkError.unlinked {
            guard !Task.isCancelled, !closed else { return }
            linkStatus = "This contact hasn’t linked a wallet yet."
        } catch MerchantWalletAPI.LinkError.mismatch {
            guard !Task.isCancelled, !closed else { return }
            linkStatus = "This wallet doesn’t match the staging account."
        } catch {
            guard !Task.isCancelled, !closed else { return }
            linkStatus = "Couldn’t verify the wallet link. Check the connection and try again."
        }
    }

    func requireLinkVerification() {
        do {
            var current = try currentSession()
            current.stagingLinkVerified = false
            try save(current)
        } catch { message = error.localizedDescription }
    }

    @Published private(set) var uncertain = false
    @Published private(set) var accepted: String?
    private enum StoredResult: String {
        case transfer = "Transfer accepted"
        case exchange = "Exchange submitted"
        case deposit = "Deposit reported"
        case withdrawal = "Withdrawal submitted"
    }

    private func restoreOutcome() throws {
        guard let accountKey, accountKey == openedOwner else { throw MerchantWalletAPI.Failure.status(401) }
        do {
            let data = try keychain.dataValue(service: service + ".Pending", key: accountKey)
            accepted = String(data: data, encoding: .utf8).flatMap(StoredResult.init(rawValue:))?.rawValue
            uncertain = accepted == nil
        } catch KeychainError.notFound {
            uncertain = false
            accepted = nil
        }
    }
    private struct Approval {
        let id: UUID
        let deadline: TimeInterval?
    }
    private static var approvals = [String: Approval]()

    private func approve(_ id: UUID, expires: Bool) throws {
        let key = try cacheKey()
        guard try !hasPendingOperation() else {
            try restoreOutcome()
            throw WalletActionError.previousAttempt
        }
        Self.approvals[key] = Approval(id: id, deadline: expires ? ProcessInfo.processInfo.systemUptime + 60 : nil)
    }

    private func checkApproval(_ id: UUID) throws {
        guard let approval = Self.approvals[try cacheKey()], approval.id == id,
            approval.deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true
        else {
            throw WalletActionError.expired
        }
    }

    func approve(_ operation: MerchantWalletAPI.Operation) throws {
        guard try currentSession().identity == operation.loginID else { throw WalletActionError.expired }
        try approve(operation.id, expires: operation.expires)
    }

    func requestWithdrawalCode(_ operation: MerchantWalletAPI.Operation) async throws {
        try await write { session in
            try checkApproval(operation.id)
            _ = try await api.request(
                "merchant/crypto-withdraw/send-otp", fields: [:], bearer: session.accessToken, singleUseBody: true)
        }
    }

    private static var executingOwners = Set<String>()
    private func hasPendingOperation() throws -> Bool {
        guard let accountKey, accountKey == openedOwner else { throw MerchantWalletAPI.Failure.invalidResponse }
        do {
            _ = try keychain.dataValue(service: service + ".Pending", key: accountKey)
            return true
        } catch KeychainError.notFound { return false }
    }

    func acknowledgeHistory() {
        guard let owner = openedOwner, owner == accountKey, !Self.executingOwners.contains(owner) else { return }
        do {
            if try hasPendingOperation() { try keychain.removeValue(service: service + ".Pending", key: owner) }
            uncertain = false
            accepted = nil
            transferResult = nil
        } catch { message = "Could not clear the previous result." }
    }

    private func executeOnce(_ id: UUID, result: StoredResult, perform: (MerchantWalletAPI.Session) async throws -> Void)
        async throws
    {
        let stored = try currentSession()
        guard let owner = openedOwner, !stored.expired else { throw MerchantWalletAPI.Failure.status(401) }
        let key = try cacheKey()
        let pendingKey = owner
        guard !Self.executingOwners.contains(owner), try !hasPendingOperation() else {
            try restoreOutcome()
            throw WalletActionError.previousAttempt
        }
        Self.executingOwners.insert(owner)
        defer { Self.executingOwners.remove(owner) }
        let current = (stored.accessDeadline ?? .distantFuture) <= Date() ? try await renew(stored) : stored
        try checkApproval(id)
        Self.approvals.removeValue(forKey: key)
        try keychain.setDataValue(Data([1]), service: service + ".Pending", key: pendingKey)
        do {
            try await perform(current)
        } catch MerchantWalletAPI.Failure.status(let code) where [400, 401, 403, 422, 429].contains(code) {
            try keychain.removeValue(service: service + ".Pending", key: pendingKey)
            throw MerchantWalletAPI.Failure.status(code)
        } catch {
            try restoreOutcome()
            throw WalletActionError.previousAttempt
        }
        do {
            try keychain.setDataValue(Data(result.rawValue.utf8), service: service + ".Pending", key: pendingKey)
            if accountKey == pendingKey { accepted = result.rawValue }
        } catch {
            uncertain = true
            throw WalletActionError.previousAttempt
        }
    }

    func execute(_ operation: MerchantWalletAPI.Operation, extra: [String: String] = [:]) async throws {
        guard !busy, try currentSession().identity == operation.loginID else { throw WalletActionError.expired }
        busy = true
        defer { busy = false }
        let result: StoredResult
        switch operation.path {
        case "merchant/exchange/execute": result = .exchange
        case "merchant/create-deposit-intention": result = .deposit
        case "merchant/crypto-withdraw": result = .withdrawal
        default: throw MerchantWalletAPI.Failure.invalidResponse
        }
        try await executeOnce(operation.id, result: result) { current in
            _ = try await api.request(
                operation.path, fields: operation.fields.merging(extra) { value, _ in value },
                bearer: current.accessToken, expected: operation.status, singleUseBody: true)
        }
    }

    @Published var selectedContact: WalletContact?
    private var reviewedContactID: String?
    @Published var recipient = ""
    @Published var currency = "EUR" {
        didSet { if oldValue != currency { sendAmount = WalletSendAmount(reportingCurrency: sendAmount.reportingCurrency) } }
    }
    @Published var sendAmount = WalletSendAmount(reportingCurrency: "EUR")
    var selectedBalance: MerchantWalletAPI.Balance? { balances?.first { $0.currency == currency } }
    var selectedCurrencyIsFiat: Bool { portfolio?.assets.first { $0.code == currency }?.isFiat == true }
    var currencies: [String] { (portfolio?.assets ?? []).filter { $0.isFiat || $0.isCrypto }.map(\.code) }
    private var reviewedLogin: String?
    @Published var review: MerchantWalletAPI.Review?
    enum Outcome {
        case accepted
        case rejected(Int)
        case unknown
    }
    struct Receipt {
        let review: MerchantWalletAPI.Review
        let outcome: Outcome
    }
    @Published var transferResult: Receipt?
    @Published private(set) var submitting = false

    var canReview: Bool {
        let address = linkedEmail ?? recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uncertain, let assetAmount = sendAmount.assetAmount(selectedBalance, isFiat: selectedCurrencyIsFiat),
            let requested = try? MerchantWalletAPI.decimal(assetAmount),
            let selectedBalance, let available = try? MerchantWalletAPI.decimal(selectedBalance.balance),
            requested <= available
        else { return false }
        if chatACI != nil { return linkedEmail != nil }
        return currencies.contains(currency)
            && (selectedContact != nil
                || address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil)
    }

    func prepareTransfer() async {
        guard session != nil, !closed, !busy, canReview, !offline,
            let amount = sendAmount.assetAmount(selectedBalance, isFiat: selectedCurrencyIsFiat)
        else { return }
        let asset = currency
        busy = true
        defer { busy = false }
        message = nil
        do {
            let address: String
            reviewedContactID = chatACI ?? selectedContact?.id
            if let id = reviewedContactID {
                guard contactEligible(id) else { throw MerchantWalletAPI.LinkError.unlinked }
                address = try await api.linkedEmail(for: id)
                guard chatACI == nil || address == linkedEmail else {
                    linkedEmail = nil
                    linkStatus = "The wallet link changed. Check the recipient again."
                    return
                }
            } else {
                address = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let checked = try await read { current in
                try await api.review(
                    current, email: address,
                    amount: amount, currency: asset)
            }
            let latest = try await read(api.balances)
            guard let available = latest.first(where: { $0.currency == asset }),
                try MerchantWalletAPI.decimal(checked.estimate.amountWithFee) <= MerchantWalletAPI.decimal(available.balance)
            else {
                message = "The amount and fee exceed your available balance."
                return
            }
            reviewedLogin = try currentSession().identity
            try approve(checked.id, expires: true)
            review = checked
        } catch MerchantWalletAPI.Failure.status(401) {
            await endSession()
            message = MerchantWalletAPI.Failure.status(401).localizedDescription
        } catch {
            message = "Couldn’t review this transfer. Check the recipient, amount, and available balance."
        }
    }

    func submitTransfer(sendReceipt: (@MainActor (String) async -> Bool)?) async {
        guard let session, let reviewed = review, !busy, !closed else { return }
        guard (try? currentSession().identity) == reviewedLogin, (try? checkApproval(reviewed.id)) != nil else {
            review = nil
            message = WalletActionError.expired.localizedDescription
            return
        }
        busy = true
        submitting = true
        defer {
            busy = false
            submitting = false
            review = nil
        }
        if let id = reviewedContactID {
            do {
                guard contactEligible(id), try await api.linkedEmail(for: id) == reviewed.email else {
                    throw MerchantWalletAPI.LinkError.mismatch
                }
            } catch {
                linkedEmail = nil
                linkStatus = "Couldn’t confirm the recipient’s wallet. Check the link again."
                return
            }
        }
        guard !closed, !Task.isCancelled, (try? currentSession().identity) == reviewedLogin else { return }
        recipient = ""
        sendAmount = WalletSendAmount(reportingCurrency: sendAmount.reportingCurrency)
        message = nil
        do {
            try await executeOnce(reviewed.id, result: .transfer) { try await api.send($0, review: reviewed) }
            transferResult = Receipt(review: reviewed, outcome: .accepted)
            selectedContact = nil
            if let sendReceipt {
                let text = "LetKnow Pay accepted a transfer of \(reviewed.amount) \(reviewed.estimate.currencyCode)."
                if await sendReceipt(text) { return }
                message = "Payment accepted. The chat receipt could not be sent."
            }
            if !closed, let value = try? await read(api.portfolio) { portfolio = value }
        } catch MerchantWalletAPI.Failure.status(401) {
            do {
                _ = try await renew(session)
                message = "Transfer rejected. Review the payment again."
            } catch MerchantWalletAPI.Failure.status(401) {
                await endSession()
                message = "Transfer rejected. Sign in again."
            } catch { message = "Transfer rejected. Refresh your balance before trying again." }
        } catch MerchantWalletAPI.Failure.status(let code) where [400, 403, 422, 429].contains(code) {
            transferResult = Receipt(review: reviewed, outcome: .rejected(code))
        } catch WalletActionError.expired {
            message = WalletActionError.expired.localizedDescription
        } catch {
            if uncertain {
                transferResult = Receipt(review: reviewed, outcome: .unknown)
            } else {
                message = error.localizedDescription
            }
        }
    }

    func startNewTransfer() {
        if accepted != nil { acknowledgeHistory() }
        message = nil
        transferResult = nil
    }

    func signOut() async {
        guard !busy, !closed, let owner = openedOwner, !Self.executingOwners.contains(owner) else { return }
        guard (try? hasPendingOperation()) == false else {
            try? restoreOutcome()
            return
        }
        busy = true
        Self.executingOwners.insert(owner)
        defer {
            busy = false
            Self.executingOwners.remove(owner)
        }
        await endSession()
    }

    private func endSession() async {
        linkTask?.cancel()
        linking = false
        var previous: MerchantWalletAPI.Session?
        if let owner = openedOwner, owner == accountKey {
            do {
                if let stored = try saved(), stored.identity == session?.identity {
                    let key = try cacheKey()
                    Self.approvals[key] = nil
                    for suffix in [".Portfolio", ".Activity", ".Invoices"] {
                        do { try keychain.removeValue(service: service + suffix, key: key) } catch KeychainError.notFound {
                            continue
                        }
                    }
                    try keychain.removeValue(service: service, key: owner)
                    previous = stored
                }
            } catch {
                message = "Could not clear the saved session. Try signing out again."
                return
            }
        }
        recipient = ""
        linkedEmail = nil
        currency = "EUR"
        sendAmount = WalletSendAmount(reportingCurrency: sendAmount.reportingCurrency)
        review = nil
        transferResult = nil
        session = nil
        portfolio = nil
        selectedContact = nil
        reviewedContactID = nil
        reviewedLogin = nil
        uncertain = false
        accepted = nil
        challenge = nil
        code = ""
        offline = false
        password = ""
        message = nil
        if let previous {
            do { try await api.logout(previous) } catch {
                message = "Signed out on this device. The server did not confirm sign-out."
            }
        }
    }

    func leave() {
        closed = true
        linkTask?.cancel()
        password = ""
    }
}
