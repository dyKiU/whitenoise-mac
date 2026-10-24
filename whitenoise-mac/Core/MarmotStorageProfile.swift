import Foundation
import MarmotKit

nonisolated enum MarmotStorageProfile {
    case production
    case syncDevelopment
    case testHost

    var directoryName: String {
        switch self {
        case .production: "White Noise"
        case .syncDevelopment: "White Noise Sync Development"
        case .testHost: "White Noise Tests"
        }
    }

    var keychainService: String {
        switch self {
        case .production: "com.marmot.whitenoise"
        case .syncDevelopment: "com.marmot.whitenoise.syncdev"
        case .testHost: "com.marmot.whitenoise.tests"
        }
    }

    func makeSecretStore() -> SecretStore? {
        switch self {
        case .production: nil
        case .syncDevelopment, .testHost: SyncDevelopmentSecretStore(service: keychainService)
        }
    }

    static var current: Self {
        forBundleIdentifier(Bundle.main.bundleIdentifier)
    }

    static func forBundleIdentifier(_ identifier: String?) -> Self {
        switch identifier {
        case "dev.ipf.whitenoise.mac.syncdev": .syncDevelopment
        case "dev.ipf.whitenoise.mac.tests": .testHost
        default: .production
        }
    }
}
