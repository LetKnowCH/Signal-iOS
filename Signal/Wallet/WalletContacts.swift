// SPDX-License-Identifier: AGPL-3.0-only

import LibSignalClient
import SignalServiceKit
import SwiftUI

struct WalletContact: Identifiable {
    let id: String
    let name: String

    private static func eligible(_ address: SignalServiceAddress, tx: DBReadTransaction) -> Bool {
        !address.isLocalAddress && address.aci != nil
            && !SSKEnvironment.shared.blockingManagerRef.isAddressBlocked(address, transaction: tx)
            && !DependenciesBridge.shared.recipientHidingManager.isHiddenAddress(address, tx: tx)
            && DependenciesBridge.shared.recipientDatabaseTable.fetchRecipient(address: address, tx: tx)?.isRegistered
                == true
    }

    static func stillEligible(_ identifier: String) -> Bool {
        guard let id = Aci.parseFrom(aciString: identifier) else { return false }
        return SSKEnvironment.shared.databaseStorageRef.read { eligible(SignalServiceAddress(id), tx: $0) }
    }

    static func candidates() async -> [Self] {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let env = SSKEnvironment.shared
            var addresses = Set(env.profileManagerRef.allWhitelistedRegisteredAddresses(tx: tx))
            addresses.formUnion(SignalAccount.anyFetchAll(transaction: tx).map(\.recipientAddress))
            return addresses.compactMap { address -> Self? in
                guard eligible(address, tx: tx), let aci = address.aci else { return nil }
                return Self(
                    id: aci.serviceIdString.lowercased(),
                    name: env.contactManagerRef.displayName(for: address, tx: tx).resolvedValue())
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

struct WalletContactPicker: View {
    @ObservedObject var model: MerchantWalletModel
    let choose: (WalletContact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [WalletContact]?
    @State private var query = ""
    @State private var error = ""
    @State private var revision = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Wallet contacts").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if model.linking {
                    ProgressView("Linking your wallet…")
                } else if model.session?.stagingLinkVerified != true {
                    Text("Link your wallet to find contacts who accept payments.")
                    Button("Link my wallet") {
                        Task {
                            await model.load(linkWallet: true)
                            revision += 1
                        }
                    }.disabled(model.busy)
                    if let message = model.message { Text(message) }
                } else {
                    TextField("Search contacts", text: $query).textFieldStyle(.roundedBorder)
                    if let contacts {
                        let matches = contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                        if matches.isEmpty {
                            Text(contacts.isEmpty ? "None of your contacts have linked a wallet." : "No matching contacts.")
                        }
                        ForEach(matches) { item in
                            Button {
                                choose(item)
                                dismiss()
                            } label: {
                                Text(item.name).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    } else if error.isEmpty {
                        ForEach(0..<3) { _ in WalletCard { WalletSkeleton(sample: "Contact name") } }
                    }
                    if !error.isEmpty {
                        Text(error)
                        Button("Try again") { revision += 1 }
                    }
                }
            }.padding()
        }.task(id: [String(revision), String(model.session?.stagingLinkVerified == true)]) {
            guard model.session?.stagingLinkVerified == true else { return }
            error = ""
            contacts = nil
            do {
                let local = await WalletContact.candidates()
                var result: [WalletContact] = []
                for start in stride(from: 0, to: local.count, by: 100) {
                    let batch = local[start..<min(start + 100, local.count)]
                    let matches = try await model.read { _ in try await model.api.linkedContacts(batch.map(\.id)) }
                    result.append(contentsOf: batch.filter { matches.contains($0.id) })
                }
                try Task.checkCancellation()
                contacts = result
            } catch MerchantWalletAPI.LinkError.mismatch {
                if !Task.isCancelled { model.requireLinkVerification() }
            } catch { if !Task.isCancelled { self.error = "Could not check which contacts have linked wallets." } }
        }
    }
}
