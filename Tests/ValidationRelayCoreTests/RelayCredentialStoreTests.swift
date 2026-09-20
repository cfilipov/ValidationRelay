import Foundation
import XCTest
@testable import ValidationRelayCore

final class RelayCredentialStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RelayCredentialStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyStoreHasNoCredentials() {
        XCTAssertEqual(RelayCredentialStore(defaults: defaults).load(), .absent)
    }

    func testCompleteLegacyCredentialsMigrateWithoutDeletingLegacyKeys() {
        defaults.set("code", forKey: RelayCredentialStore.legacyCodeKey)
        defaults.set("secret", forKey: RelayCredentialStore.legacySecretKey)
        defaults.set("wss://relay.example/provider", forKey: RelayCredentialStore.legacyURLKey)

        let store = RelayCredentialStore(defaults: defaults)
        let expected = RelayCredentials(
            code: "code",
            secret: "secret",
            serverURL: "wss://relay.example/provider"
        )

        XCTAssertEqual(store.load(), .available(expected))
        XCTAssertNotNil(defaults.data(forKey: RelayCredentialStore.recordKey))
        XCTAssertEqual(defaults.string(forKey: RelayCredentialStore.legacySecretKey), "secret")
    }

    func testPartialLegacyCredentialsAreNotTreatedAsANewRegistration() {
        defaults.set("code", forKey: RelayCredentialStore.legacyCodeKey)

        XCTAssertEqual(RelayCredentialStore(defaults: defaults).load(), .incomplete)
    }

    func testSaveMirrorsCredentialsForRollback() {
        let credentials = RelayCredentials(
            code: "code",
            secret: "secret",
            serverURL: "wss://relay.example/provider"
        )
        let store = RelayCredentialStore(defaults: defaults)

        store.save(credentials)

        XCTAssertEqual(store.load(), .available(credentials))
        XCTAssertEqual(defaults.string(forKey: RelayCredentialStore.legacyCodeKey), "code")
        XCTAssertEqual(defaults.string(forKey: RelayCredentialStore.legacySecretKey), "secret")
        XCTAssertEqual(defaults.string(forKey: RelayCredentialStore.legacyURLKey), credentials.serverURL)
    }

    func testLoadRepairsLegacyKeysFromAuthoritativeRecord() {
        let credentials = RelayCredentials(
            code: "code",
            secret: "secret",
            serverURL: "wss://relay.example/provider"
        )
        let store = RelayCredentialStore(defaults: defaults)
        store.save(credentials)
        defaults.removeObject(forKey: RelayCredentialStore.legacySecretKey)

        XCTAssertEqual(store.load(), .available(credentials))
        XCTAssertEqual(defaults.string(forKey: RelayCredentialStore.legacySecretKey), "secret")
    }

    func testClearRemovesBothCredentialFormats() {
        let store = RelayCredentialStore(defaults: defaults)
        store.save(RelayCredentials(
            code: "code",
            secret: "secret",
            serverURL: "wss://relay.example/provider"
        ))

        store.clear()

        XCTAssertEqual(store.load(), .absent)
        XCTAssertNil(defaults.object(forKey: RelayCredentialStore.legacySecretKey))
    }
}
