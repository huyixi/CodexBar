import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountUsagePaneStateTests {
    @Test
    func `current account appears first and cached inactive account usage is preserved`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountUsagePaneStateTests-current-first")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        store._setSnapshotForTesting(Self.makeSnapshot(email: "live@example.com"), provider: .codex)
        let managedVisibleAccountID = "managed@example.com"
        store.codexVisibleAccountSnapshots[managedVisibleAccountID] = CodexVisibleAccountUsageSnapshot(
            visibleAccountID: managedVisibleAccountID,
            snapshot: Self.makeSnapshot(email: "managed@example.com", usedPercent: 42),
            error: nil,
            sourceLabel: "cached")

        let state = CodexAccountUsagePaneStateBuilder.make(settings: settings, store: store)

        #expect(state.entries.map(\.account.email) == ["live@example.com", "managed@example.com"])
        #expect(state.entries.first?.badgeText == "Current")
        #expect(state.entries.last?.model.email == "managed@example.com")
        #expect(state.notice == nil)
    }

    @Test
    func `legacy current and system mismatch surfaces notice`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountUsagePaneStateTests-legacy-notice")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)

        let state = CodexAccountUsagePaneStateBuilder.make(settings: settings, store: store)

        #expect(state.entries.map(\.account.email) == ["managed@example.com", "live@example.com"])
        #expect(state.notice?.tone == .secondary)
        #expect(state.notice?.text.contains("Current account differs") == true)
    }

    @Test
    func `state is empty when no codex accounts are available`() {
        let settings = Self.makeSettingsStore(suite: "CodexAccountUsagePaneStateTests-empty")
        let store = Self.makeUsageStore(settings: settings)

        let state = CodexAccountUsagePaneStateBuilder.make(settings: settings, store: store)

        #expect(state.isEmpty)
        #expect(state.entries.isEmpty)
        #expect(state.notice == nil)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private static func makeSnapshot(
        email: String,
        usedPercent: Double = 30,
        updatedAt: Date = Date()) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: usedPercent + 10,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }
}
