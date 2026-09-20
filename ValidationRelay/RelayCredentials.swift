import Foundation

struct RelayCredentials: Codable, Equatable {
    let code: String
    let secret: String
    let serverURL: String

    var isComplete: Bool {
        !code.isEmpty && !secret.isEmpty && URL(string: serverURL) != nil
    }
}

enum RelayCredentialState: Equatable {
    case absent
    case available(RelayCredentials)
    case incomplete
}

struct RelayCredentialStore {
    static let recordKey = "relayCredentialsV2"
    static let legacyCodeKey = "savedRegistrationCode"
    static let legacySecretKey = "savedRegistrationSecret"
    static let legacyURLKey = "savedRegistrationURL"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RelayCredentialState {
        if let data = defaults.data(forKey: Self.recordKey),
           let credentials = try? JSONDecoder().decode(RelayCredentials.self, from: data),
           credentials.isComplete {
            mirrorLegacyCredentials(credentials)
            return .available(credentials)
        }

        let code = defaults.string(forKey: Self.legacyCodeKey) ?? ""
        let secret = defaults.string(forKey: Self.legacySecretKey) ?? ""
        let serverURL = defaults.string(forKey: Self.legacyURLKey) ?? ""
        let credentials = RelayCredentials(code: code, secret: secret, serverURL: serverURL)

        if credentials.isComplete {
            save(credentials)
            return .available(credentials)
        }

        let hasStoredValue = defaults.object(forKey: Self.recordKey) != nil
            || !code.isEmpty
            || !secret.isEmpty
            || !serverURL.isEmpty
        return hasStoredValue ? .incomplete : .absent
    }

    func save(_ credentials: RelayCredentials) {
        guard credentials.isComplete,
              let data = try? JSONEncoder().encode(credentials) else {
            return
        }

        // The single encoded record is authoritative. Keep the legacy keys in sync
        // so an in-place rollback to ValidationRelay 1.8 retains the same relay ID.
        defaults.set(data, forKey: Self.recordKey)
        mirrorLegacyCredentials(credentials)
    }

    private func mirrorLegacyCredentials(_ credentials: RelayCredentials) {
        defaults.set(credentials.code, forKey: Self.legacyCodeKey)
        defaults.set(credentials.secret, forKey: Self.legacySecretKey)
        defaults.set(credentials.serverURL, forKey: Self.legacyURLKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.recordKey)
        defaults.removeObject(forKey: Self.legacyCodeKey)
        defaults.removeObject(forKey: Self.legacySecretKey)
        defaults.removeObject(forKey: Self.legacyURLKey)
    }
}
