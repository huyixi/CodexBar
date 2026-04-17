import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderExternalLinksTests {
    @Test
    func `alibaba dashboard link follows selected region`() {
        let settings = Self.makeSettingsStore(suite: "ProviderExternalLinksTests-alibaba")
        settings.alibabaCodingPlanAPIRegion = .chinaMainland
        let store = Self.makeUsageStore(settings: settings)

        let links = ProviderExternalLinks.links(for: .alibaba, settings: settings, store: store)

        #expect(links.first(where: { $0.id == "dashboard" })?.url == AlibabaCodingPlanAPIRegion.chinaMainland
            .dashboardURL)
    }

    @Test
    func `claude subscription uses subscription dashboard URL when available`() {
        let settings = Self.makeSettingsStore(suite: "ProviderExternalLinksTests-claude-subscription")
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "claude@example.com",
                    accountOrganization: nil,
                    loginMethod: "Max")),
            provider: .claude)

        let links = ProviderExternalLinks.links(for: .claude, settings: settings, store: store)
        let expected = URL(string: ProviderRegistry.shared.metadata[.claude]?.subscriptionDashboardURL ?? "")

        #expect(links.first(where: { $0.id == "dashboard" })?.url == expected)
    }

    @Test
    func `provider uses standard dashboard URL when no override applies`() {
        let settings = Self.makeSettingsStore(suite: "ProviderExternalLinksTests-standard-dashboard")
        let store = Self.makeUsageStore(settings: settings)

        let links = ProviderExternalLinks.links(for: .codex, settings: settings, store: store)
        let expected = URL(string: ProviderRegistry.shared.metadata[.codex]?.dashboardURL ?? "")

        #expect(links.first(where: { $0.id == "dashboard" })?.url == expected)
    }

    @Test
    func `status link prefers status page and falls back to status link`() {
        let settings = Self.makeSettingsStore(suite: "ProviderExternalLinksTests-status-fallback")
        let store = Self.makeUsageStore(settings: settings)

        let codexLinks = ProviderExternalLinks.links(for: .codex, settings: settings, store: store)
        let geminiLinks = ProviderExternalLinks.links(for: .gemini, settings: settings, store: store)
        let codexExpected = URL(string: ProviderRegistry.shared.metadata[.codex]?.statusPageURL ?? "")
        let geminiExpected = URL(string: ProviderRegistry.shared.metadata[.gemini]?.statusLinkURL ?? "")

        #expect(codexLinks.first(where: { $0.id == "status" })?.url == codexExpected)
        #expect(geminiLinks.first(where: { $0.id == "status" })?.url == geminiExpected)
    }

    @Test
    func `providers without links return empty array`() {
        let settings = Self.makeSettingsStore(suite: "ProviderExternalLinksTests-no-links")
        let store = Self.makeUsageStore(settings: settings)

        let links = ProviderExternalLinks.links(for: .synthetic, settings: settings, store: store)

        #expect(links.isEmpty)
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
            settings: settings)
    }
}
