import Foundation
import Testing
@testable import ScrobblerCore

/// These tests use the real Keychain (your login keychain), so each one gets
/// its own made-up service name and deletes its item when it ends. The app's
/// own item (`io.github.mehrad77.GameScrobbler`) is never touched.
@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {
    /// A store no other test or run shares. Swift Testing makes a fresh
    /// instance of the suite for every test, so each test has its own `store`.
    let store = KeychainTokenStore(service: "io.github.mehrad77.GameScrobbler.tests.\(UUID().uuidString)")

    @Test func savesReadsAndDeletesAToken() throws {
        // `defer` runs when the scope ends, however it ends: here, even when
        // an expectation below fails, the test item is cleaned up.
        defer { try? store.delete() }

        #expect(try store.hasToken() == false)
        #expect(try store.token() == nil)

        try store.save("gsp_first")
        #expect(try store.hasToken())
        #expect(try store.token() == "gsp_first")

        try store.delete()
        #expect(try store.token() == nil)
    }

    @Test func savingAgainReplacesTheToken() throws {
        defer { try? store.delete() }

        try store.save("gsp_old")
        try store.save("gsp_new")

        #expect(try store.token() == "gsp_new")
    }

    @Test func deletingWhenEmptyIsFine() throws {
        try store.delete()
    }

    @Test func errorsExplainThemselves() {
        // -25300 is errSecItemNotFound; the system has a sentence for it.
        #expect(!KeychainError(status: errSecItemNotFound).description.isEmpty)
    }
}
