//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// MARK: -

import Foundation
public import LibSignalClient

public class TSConstants {

    private enum Environment {
        case production
        case staging
    }

    private static let environment: Environment = {
// You can set "USE_STAGING=1" in your Xcode Scheme. This allows you to
// prepare a series of commits without accidentally committing the change
// to the environment.
#if DEBUG
        if isUsingLetKnowService {
            return .staging
        }

        if ProcessInfo.processInfo.environment["USE_STAGING"] == "1" {
            return .staging
        }
#endif

        // If you do want to make a build that will always connect to staging,
        // change this value. (Scheme environment variables are only set when
        // launching via Xcode, so this approach is still quite useful.)
        return .production
    }()

    public static var isUsingProductionService: Bool {
        return environment == .production
    }

    public static let isUsingLetKnowService = true

    // Never instantiate this class.
    private init() {}

    public static let legalTermsUrl = URL(string: "https://signal.org/legal/")!
    public static let donateUrl = URL(string: "https://signal.org/donate/")!
    public static let appStoreUrl = URL(string: "https://itunes.apple.com/us/app/signal-private-messenger/id874139669?mt=8")!

    public static var mainServiceURL: String { shared.mainServiceURL }

    public static var textSecureCDN0ServerURL: String { shared.textSecureCDN0ServerURL }
    public static var textSecureCDN2ServerURL: String { shared.textSecureCDN2ServerURL }
    public static var textSecureCDN3ServerURL: String { shared.textSecureCDN3ServerURL }
    public static var storageServiceURL: String { shared.storageServiceURL }
    public static var sfuURL: String { shared.sfuURL }
    public static var sfuTestURL: String { shared.sfuTestURL }
    public static var svr2URL: String { shared.svr2URL }
    public static var registrationCaptchaURL: String { shared.registrationCaptchaURL }
    public static var challengeCaptchaURL: String { shared.challengeCaptchaURL }
    public static var kUDTrustRoots: [String] { shared.kUDTrustRoots }
    public static var updatesURL: String { shared.updatesURL }
    public static var updates2URL: String { shared.updates2URL }

    public static var censorshipFReflectorHost: String { shared.censorshipFReflectorHost }
    public static var censorshipGReflectorHost: String { shared.censorshipGReflectorHost }

    public static var serviceCensorshipPrefix: String { shared.serviceCensorshipPrefix }
    public static var cdn0CensorshipPrefix: String { shared.cdn0CensorshipPrefix }
    public static var cdn2CensorshipPrefix: String { shared.cdn2CensorshipPrefix }
    public static var cdn3CensorshipPrefix: String { shared.cdn3CensorshipPrefix }
    public static var storageServiceCensorshipPrefix: String { shared.storageServiceCensorshipPrefix }
    public static var svr2CensorshipPrefix: String { shared.svr2CensorshipPrefix }

    static var svr2Enclave: MrEnclave { shared.svr2Enclave }
    static var svr2PreviousEnclaves: [MrEnclave] { shared.svr2PreviousEnclaves }

    public static var applicationGroup: String { shared.applicationGroup }

    public static var serverPublicParams: Data { shared.serverPublicParams }
    public static var callLinkPublicParams: Data { shared.callLinkPublicParams }
    public static var backupServerPublicParams: Data { shared.backupServerPublicParams }

    public static let shared: TSConstantsProtocol = {
        switch environment {
        case .production:
            return TSConstantsProduction()
        case .staging:
            return TSConstantsStaging()
        }
    }()

    public static let libSignalEnv: Net.Environment = {
        // Both LetKnow configurations use the staging chat service.
        if isUsingLetKnowService { return .staging }
        switch environment {
        case .production:
            return .production
        case .staging:
            return .staging
        }
    }()
}

// MARK: -

public protocol TSConstantsProtocol: AnyObject {
    var mainServiceURL: String { get }
    var textSecureCDN0ServerURL: String { get }
    var textSecureCDN2ServerURL: String { get }
    var textSecureCDN3ServerURL: String { get }
    var storageServiceURL: String { get }
    var sfuURL: String { get }
    var sfuTestURL: String { get }
    var svr2URL: String { get }
    var registrationCaptchaURL: String { get }
    var challengeCaptchaURL: String { get }
    var kUDTrustRoots: [String] { get }
    var updatesURL: String { get }
    var updates2URL: String { get }

    var censorshipFReflectorHost: String { get }
    var censorshipGReflectorHost: String { get }

    var serviceCensorshipPrefix: String { get }
    var cdn0CensorshipPrefix: String { get }
    var cdn2CensorshipPrefix: String { get }
    var cdn3CensorshipPrefix: String { get }
    var storageServiceCensorshipPrefix: String { get }
    var svr2CensorshipPrefix: String { get }

    var svr2Enclave: MrEnclave { get }
    var svr2PreviousEnclaves: [MrEnclave] { get }

    var applicationGroup: String { get }

    var serverPublicParams: Data { get }
    var callLinkPublicParams: Data { get }
    var backupServerPublicParams: Data { get }
}

public struct MrEnclave: Equatable {
    public let dataValue: Data
    public let stringValue: String

    // This identifies the backup namespace. Libsignal verifies Nitro measurements separately.
    static let letKnowNitroPin = MrEnclave(serviceIdentifier: "letknow-nitro-pin-v1")

    private init(serviceIdentifier: String) {
        stringValue = serviceIdentifier
        dataValue = Data(serviceIdentifier.utf8)
    }

    init(_ stringValue: StaticString) {
        self.stringValue = String(describing: stringValue)
        // This is a constant -- it should never fail to parse.
        self.dataValue = Data.data(fromHex: self.stringValue)!
        // All of our MrEnclave values are currently 32 bytes.
        owsPrecondition(self.dataValue.count == 32)
    }

    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.dataValue == rhs.dataValue
    }
}

// MARK: - Production

public class TSConstantsProduction: TSConstantsProtocol {

    public init() {}

    public let mainServiceURL = "https://chat.stage.letknow.info"
    public let textSecureCDN0ServerURL = "https://cdn.signal.org"
    public let textSecureCDN2ServerURL = "https://cdn2.signal.org"
    public let textSecureCDN3ServerURL = "https://cdn3-stage.letknow.info"
    public let storageServiceURL = "https://storage.stage.letknow.info:8444"
    public let sfuURL = "https://calling.stage.letknow.info:8445"
    public let sfuTestURL = "https://calling.stage.letknow.info:8445"
    public let svr2URL = "wss://svr2.stage.letknow.info:8446"
    public let registrationCaptchaURL = "https://chat.stage.letknow.info/v1/captcha/registration"
    public let challengeCaptchaURL = "https://signalcaptchas.org/challenge/generate.html"
    public let kUDTrustRoots = ["BauR5nkOg3c57jiVRudkJiH0Jbw7vm5hJ8R9RY6mWOha"]
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipFReflectorHost = "reflector-signal.global.ssl.fastly.net"
    public let censorshipGReflectorHost = "reflector-nrgwuv7kwq-uc.a.run.app"

    public let serviceCensorshipPrefix = "service"
    public let cdn0CensorshipPrefix = "cdn"
    public let cdn2CensorshipPrefix = "cdn2"
    public let cdn3CensorshipPrefix = "cdn3"
    public let storageServiceCensorshipPrefix = "storage"
    public let svr2CensorshipPrefix = "svr2"

    public let svr2Enclave = MrEnclave.letKnowNitroPin

    // An array of previously used enclaves that we should try and restore
    // key material from during registration. These must be ordered from
    // newest to oldest, so we check the latest enclaves for backups before
    // checking earlier enclaves.
    public let svr2PreviousEnclaves: [MrEnclave] = []

    public let applicationGroup = "group.com.suisse.ag.letKnow.signal.group"

    /// We *might* need to clear credentials (or perform some other migration)
    /// when this value changes, depending on how it's changing. If you do need
    /// to perform a migration, check out `ZkParamsMigrator`.
    public let serverPublicParams = Data(base64Encoded: "ALh1pN5sy9xpGBo5A09b3/PuPw3jWs8gkBOzDUsqHwtUbpbOK+xrUgqinsPbrI9YZO2NuCOAtxdbhpgKXJqny1p4TcIylJVMvMUcPNG7JhEZNMbja/lnjfXFNzXngdioAha/bnTSO4H3fM4DPMqzJxzk1MS4bH0K1DfYneWbolFyWl064ok6/X1R073/qSlQYms33sEhYlyyXYYWiLtbLGFUX0XH+X89l0051l8+gr0z6NHJZugKOCxbRNMTSm4oBaiO3kLlxvxACgfTfuZQRhpw1nZ387PJbCQIEORl8LR5tMTL0B9lwDgxmh/RS2d4ht0zmh2w2ydPLxC2GNyLd1oouHqY+s3eZ0kp1/Tn2Zz8vO/wMaQ46xMzn16HR5hgJvS4Ase/6xf84yMnEMSGMZom2KwQNLeo0WxvOn8tE74zVjCu2MjNwsZ8iMwQBHMBkhOiZtNDqQz9KvkxseP68gNCPjcj4IuWRbBvMpgFK+wtd3pcIHawd1d4CyHpboppNKpBBi66twO4gpiLNpnY4uQ9K8g9XS/KOV+krjOlSkMStE78my1bhhkKcvtM8IvwELmYHYKOFADSZKEak7KrPFIChBRR87sGv8ytf2lLLDpTFeHiemnN/pyc+e/OFEQjHuw1OVoAqhHLsc7a8OYr85uY4e7dLiweBxjwDf22PgB15PRvIZPkNooHVvjP9xJKQVcHJAhzW32Qp/a6n5t3WzKAJ0cNHuOq2vxL6hoSE4AL3xO7ZkIDmoKmxm0rb6hZa157btmVkLEAOT8rwGuVBfKu2zuWmyxw6C3gXtv/v6R5AEO7OL2aMNLyJ8ya1uVfJJASTojKIj+Z+NFCzW4+yivuKYI8HfiPg89EjT+VeqAYlQb3yQVtpTxdXCCsUHKmDw==")!

    public let callLinkPublicParams = Data(base64Encoded: "AByD873dTilmOSG0TjKrvpeaKEsUmIO8Vx9BeMmftwUs9v7ikPwM8P3OHyT0+X3EUMZrSe9VUp26Wai51Q9I8mdk0hX/yo7CeFGJyzoOqn8e/i4Ygbn5HoAyXJx5eXfIbqpc0bIxzju4H/HOQeOpt6h742qii5u/cbwOhFZCsMIbElZTaeU+BWMBQiZHIGHT5IE0qCordQKZ5iPZom0HeFa8Yq0ShuEyAl0WINBiY6xE3H/9WnvzXBbMuuk//eRxXgzO8ieCeK8FwQNxbfXqZm6Ro1cMhCOF3u7xoX83QhpN")!

    public let backupServerPublicParams = Data(base64Encoded: "AJwNSU55fsFCbgaxGRD11wO1juAs8Yr5GF8FPlGzzvdJJIKH5/4CC7ZJSOe3yL2vturVaRU2Cx0n751Vt8wkj1bozK3CBV1UokxV09GWf+hdVImLGjXGYLLhnI1J2TWEe7iWHyb553EEnRb5oxr9n3lUbNAJuRmFM7hrr0Al0F0wrDD4S8lo2mGaXe0MJCOM166F8oYRQqpFeEHfiLnxA1O8ZLh7vMdv4g9jI5phpRBTsJ5IjiJrWeP0zdIGHEssUeprDZ9OUJ14m0v61eYJMKsf59Bn+mAT2a7YfB+Don9O")!
}

// MARK: - Staging

public class TSConstantsStaging: TSConstantsProtocol {

    public init() {}

    public let mainServiceURL = "https://chat.stage.letknow.info"
    public let textSecureCDN0ServerURL = "https://cdn-staging.signal.org"
    public let textSecureCDN2ServerURL = "https://cdn2-staging.signal.org"
    public let textSecureCDN3ServerURL = "https://cdn3-stage.letknow.info"
    public let storageServiceURL = "https://storage.stage.letknow.info:8444"
    public let sfuURL = "https://calling.stage.letknow.info:8445"
    public let svr2URL = "wss://svr2.stage.letknow.info:8446"
    public let registrationCaptchaURL = "https://chat.stage.letknow.info/v1/captcha/registration"
    public let challengeCaptchaURL = "https://signalcaptchas.org/staging/challenge/generate.html"
    // There's no separate test SFU for staging.
    public let sfuTestURL = "https://calling.stage.letknow.info:8445"
    public let kUDTrustRoots = ["BauR5nkOg3c57jiVRudkJiH0Jbw7vm5hJ8R9RY6mWOha"]
    // There's no separate updates endpoint for staging.
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipFReflectorHost = "reflector-staging-signal.global.ssl.fastly.net"
    public let censorshipGReflectorHost = "reflector-nrgwuv7kwq-uc.a.run.app"

    public let serviceCensorshipPrefix = "service-staging"
    public let cdn0CensorshipPrefix = "cdn-staging"
    public let cdn2CensorshipPrefix = "cdn2-staging"
    public let cdn3CensorshipPrefix = "cdn3-staging"
    public let storageServiceCensorshipPrefix = "storage-staging"
    public let svr2CensorshipPrefix = "svr2-staging"

    public let svr2Enclave = MrEnclave.letKnowNitroPin

    // An array of previously used enclaves that we should try and restore
    // key material from during registration. These must be ordered from
    // newest to oldest, so we check the latest enclaves for backups before
    // checking earlier enclaves.
    public let svr2PreviousEnclaves: [MrEnclave] = []

    public let applicationGroup = "group.com.suisse.ag.letKnow.signal.group.staging"

    /// We *might* need to clear credentials (or perform some other migration)
    /// when this value changes, depending on how it's changing. If you do need
    /// to perform a migration, check out `ZkParamsMigrator`.
    public let serverPublicParams = Data(base64Encoded: "ALh1pN5sy9xpGBo5A09b3/PuPw3jWs8gkBOzDUsqHwtUbpbOK+xrUgqinsPbrI9YZO2NuCOAtxdbhpgKXJqny1p4TcIylJVMvMUcPNG7JhEZNMbja/lnjfXFNzXngdioAha/bnTSO4H3fM4DPMqzJxzk1MS4bH0K1DfYneWbolFyWl064ok6/X1R073/qSlQYms33sEhYlyyXYYWiLtbLGFUX0XH+X89l0051l8+gr0z6NHJZugKOCxbRNMTSm4oBaiO3kLlxvxACgfTfuZQRhpw1nZ387PJbCQIEORl8LR5tMTL0B9lwDgxmh/RS2d4ht0zmh2w2ydPLxC2GNyLd1oouHqY+s3eZ0kp1/Tn2Zz8vO/wMaQ46xMzn16HR5hgJvS4Ase/6xf84yMnEMSGMZom2KwQNLeo0WxvOn8tE74zVjCu2MjNwsZ8iMwQBHMBkhOiZtNDqQz9KvkxseP68gNCPjcj4IuWRbBvMpgFK+wtd3pcIHawd1d4CyHpboppNKpBBi66twO4gpiLNpnY4uQ9K8g9XS/KOV+krjOlSkMStE78my1bhhkKcvtM8IvwELmYHYKOFADSZKEak7KrPFIChBRR87sGv8ytf2lLLDpTFeHiemnN/pyc+e/OFEQjHuw1OVoAqhHLsc7a8OYr85uY4e7dLiweBxjwDf22PgB15PRvIZPkNooHVvjP9xJKQVcHJAhzW32Qp/a6n5t3WzKAJ0cNHuOq2vxL6hoSE4AL3xO7ZkIDmoKmxm0rb6hZa157btmVkLEAOT8rwGuVBfKu2zuWmyxw6C3gXtv/v6R5AEO7OL2aMNLyJ8ya1uVfJJASTojKIj+Z+NFCzW4+yivuKYI8HfiPg89EjT+VeqAYlQb3yQVtpTxdXCCsUHKmDw==")!

    public let callLinkPublicParams = Data(base64Encoded: "AHILOIrFPXX9laLbalbA9+L1CXpSbM/bTJXZGZiuyK1JaI6dK5FHHWL6tWxmHKYAZTSYmElmJ5z2A5YcirjO/yfoemE03FItyaf8W1fE4p14hzb5qnrmfXUSiAIVrhaXVwIwSzH6RL/+EO8jFIjJ/YfExfJ8aBl48CKHgu1+A6kWynhttonvWWx6h7924mIzW0Czj2ROuh4LwQyZypex4GuOPW8sgIT21KNZaafgg+KbV7XM1x1tF3XA17B4uGUaDbDw2O+nR1+U5p6qHPzmJ7ggFjSN6Utu+35dS1sS0P9N")!

    public let backupServerPublicParams = Data(base64Encoded: "AHYrGb9IfugAAJiPKp+mdXUx+OL9zBolPYHYQz6GI1gWjpEu5me3zVNSvmYY4zWboZHif+HG1sDHSuvwFd0QszSwuSF4X4kRP3fJREdTZ5MCR0n55zUppTwfHRW2S4sdQ0JGz7YDQIJCufYSKh0pGNEHL6hv79Agrdnr4momr3oXdnkpVBIp3HWAQ6IbXQVSG18X36GaicI1vdT0UFmTwU2KTneluC2eyL9c5ff8PcmiS+YcLzh0OKYQXB5ZfQ06d6DiINvDQLy75zcfUOniLAj0lGJiHxGczin/RXisKSR8")!

}

#if TESTABLE_BUILD

public class TSConstantsMock: TSConstantsProtocol {

    public init() {}

    private let defaultValues = TSConstantsProduction()

    public lazy var mainServiceURL = defaultValues.mainServiceURL

    public lazy var textSecureCDN0ServerURL = defaultValues.textSecureCDN0ServerURL

    public lazy var textSecureCDN2ServerURL = defaultValues.textSecureCDN2ServerURL

    public lazy var textSecureCDN3ServerURL = defaultValues.textSecureCDN3ServerURL

    public lazy var storageServiceURL = defaultValues.storageServiceURL

    public lazy var sfuURL = defaultValues.sfuURL

    public lazy var sfuTestURL = defaultValues.sfuTestURL

    public lazy var svr2URL = defaultValues.svr2URL

    public lazy var registrationCaptchaURL = defaultValues.registrationCaptchaURL

    public lazy var challengeCaptchaURL = defaultValues.challengeCaptchaURL

    public lazy var kUDTrustRoots = defaultValues.kUDTrustRoots

    public lazy var updatesURL = defaultValues.updatesURL

    public lazy var updates2URL = defaultValues.updates2URL

    public lazy var censorshipFReflectorHost = defaultValues.censorshipFReflectorHost
    public lazy var censorshipGReflectorHost = defaultValues.censorshipGReflectorHost

    public lazy var serviceCensorshipPrefix = defaultValues.serviceCensorshipPrefix

    public lazy var cdn0CensorshipPrefix = defaultValues.cdn0CensorshipPrefix

    public lazy var cdn2CensorshipPrefix = defaultValues.cdn2CensorshipPrefix

    public lazy var cdn3CensorshipPrefix = defaultValues.cdn3CensorshipPrefix

    public lazy var storageServiceCensorshipPrefix = defaultValues.storageServiceCensorshipPrefix

    public lazy var svr2CensorshipPrefix = defaultValues.svr2CensorshipPrefix

    public lazy var svr2Enclave = defaultValues.svr2Enclave

    public lazy var svr2PreviousEnclaves = defaultValues.svr2PreviousEnclaves

    public lazy var applicationGroup = defaultValues.applicationGroup

    public lazy var serverPublicParams = defaultValues.serverPublicParams

    public lazy var callLinkPublicParams = defaultValues.callLinkPublicParams

    public lazy var backupServerPublicParams = defaultValues.backupServerPublicParams
}

#endif
