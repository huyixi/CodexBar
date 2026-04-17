import CodexBarCore
import Foundation

struct ProviderExternalLink: Equatable, Identifiable {
    let id: String
    let title: String
    let url: URL
}

enum ProviderExternalLinks {
    @MainActor
    static func links(
        for provider: UsageProvider,
        settings: SettingsStore,
        store: UsageStore) -> [ProviderExternalLink]
    {
        var links: [ProviderExternalLink] = []

        if let dashboardURL = self.dashboardURL(for: provider, settings: settings, store: store) {
            links.append(ProviderExternalLink(
                id: "dashboard",
                title: "Usage Dashboard",
                url: dashboardURL))
        }

        if let statusURL = self.statusURL(for: provider, store: store) {
            links.append(ProviderExternalLink(
                id: "status",
                title: "Status Page",
                url: statusURL))
        }

        return links
    }

    @MainActor
    private static func dashboardURL(for provider: UsageProvider, settings: SettingsStore, store: UsageStore) -> URL? {
        if provider == .alibaba {
            return settings.alibabaCodingPlanAPIRegion.dashboardURL
        }

        let meta = store.metadata(for: provider)
        let urlString: String? = if provider == .claude, store.isClaudeSubscription() {
            meta.subscriptionDashboardURL ?? meta.dashboardURL
        } else {
            meta.dashboardURL
        }

        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    @MainActor
    private static func statusURL(for provider: UsageProvider, store: UsageStore) -> URL? {
        let meta = store.metadata(for: provider)
        guard let urlString = meta.statusPageURL ?? meta.statusLinkURL else { return nil }
        return URL(string: urlString)
    }
}
