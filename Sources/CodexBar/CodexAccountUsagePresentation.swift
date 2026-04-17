import CodexBarCore
import SwiftUI

@MainActor
extension UsageStore {
    func usageMenuCardModel(
        for provider: UsageProvider,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        usesOverride: Bool = false) -> UsageMenuCardView.Model
    {
        let metadata = self.metadata(for: provider)
        let isOverride = usesOverride || snapshotOverride != nil || errorOverride != nil
        let snapshot = isOverride ? snapshotOverride : self.snapshot(for: provider)
        let surface: CodexConsumerProjection.Surface = if isOverride {
            .overrideCard
        } else {
            .liveCard
        }
        let now = Date()
        let codexProjection = self.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: surface,
            snapshotOverride: snapshotOverride,
            errorOverride: errorOverride,
            usesOverride: isOverride,
            now: now)
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        if let codexProjection {
            credits = codexProjection.credits?.snapshot
            creditsError = codexProjection.credits?.userFacingError
            dashboard = nil
            dashboardError = codexProjection.userFacingErrors.dashboard
            if surface == .liveCard {
                tokenSnapshot = self.tokenSnapshot(for: provider)
                tokenError = self.tokenError(for: provider)
            } else {
                tokenSnapshot = nil
                tokenError = nil
            }
        } else if provider == .claude || provider == .vertexai, !isOverride {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = self.tokenSnapshot(for: provider)
            tokenError = self.tokenError(for: provider)
        } else {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = nil
            tokenError = nil
        }

        let sourceLabel = !isOverride ? self.sourceLabel(for: provider) : nil
        let kiloAutoMode = provider == .kilo && self.settings.kiloUsageDataSource == .auto
        let paceWindow = provider == .abacus ? snapshot?.primary : snapshot?.secondary
        let weeklyPace = if let codexProjection,
                            let weekly = codexProjection.rateWindow(for: .weekly)
        {
            self.weeklyPace(provider: provider, window: weekly, now: now)
        } else {
            paceWindow.flatMap { window in
                self.weeklyPace(provider: provider, window: window, now: now)
            }
        }
        let input = UsageMenuCardView.Model.Input(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: credits,
            creditsError: creditsError,
            dashboard: dashboard,
            dashboardError: dashboardError,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: self.accountInfo(for: provider),
            isRefreshing: self.shouldShowRefreshingMenuCard(for: provider),
            lastError: errorOverride
                ?? codexProjection?.userFacingErrors.usage
                ?? self.userFacingError(for: provider),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: provider),
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            sourceLabel: sourceLabel,
            kiloAutoMode: kiloAutoMode,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            weeklyPace: weeklyPace,
            now: now)
        return UsageMenuCardView.Model.make(input)
    }
}

struct CodexAccountUsageEntry: Identifiable {
    let account: CodexVisibleAccount
    let model: UsageMenuCardView.Model
    let title: String
    let badgeText: String?

    var id: String {
        self.account.id
    }
}

struct CodexAccountUsagePaneState {
    let entries: [CodexAccountUsageEntry]
    let notice: CodexAccountsSectionNotice?

    var isEmpty: Bool {
        self.entries.isEmpty
    }
}

enum CodexAccountUsagePaneStateBuilder {
    @MainActor
    static func make(settings: SettingsStore, store: UsageStore) -> CodexAccountUsagePaneState {
        let projection = settings.codexVisibleAccountProjection
        let currentVisibleAccountID = projection.activeVisibleAccountID
        let hasLegacySelectionMismatch = projection.activeVisibleAccountID != projection.liveVisibleAccountID &&
            (projection.activeVisibleAccountID != nil || projection.liveVisibleAccountID != nil)
        let legacyNotice: CodexAccountsSectionNotice? = if hasLegacySelectionMismatch {
            CodexAccountsSectionNotice(
                text: "Current account differs from this Mac's live system account. "
                    + "Choose a current account to converge them.",
                tone: .secondary)
        } else {
            nil
        }

        let orderedAccounts = projection.visibleAccounts.filter { $0.id == currentVisibleAccountID } +
            projection.visibleAccounts.filter { $0.id != currentVisibleAccountID }

        let entries = orderedAccounts.map { account in
            let isCurrent = account.id == currentVisibleAccountID
            let model: UsageMenuCardView.Model = if isCurrent {
                store.usageMenuCardModel(for: .codex)
            } else if let cached = store.codexVisibleAccountSnapshots[account.id] {
                store.usageMenuCardModel(
                    for: .codex,
                    snapshotOverride: cached.snapshot,
                    errorOverride: cached.error,
                    usesOverride: true)
            } else {
                store.usageMenuCardModel(
                    for: .codex,
                    snapshotOverride: nil,
                    errorOverride: nil,
                    usesOverride: true)
            }

            return CodexAccountUsageEntry(
                account: account,
                model: model,
                title: self.accountTitle(account, hidePersonalInfo: settings.hidePersonalInfo),
                badgeText: isCurrent ? "Current" : nil)
        }

        return CodexAccountUsagePaneState(
            entries: entries,
            notice: legacyNotice)
    }

    private static func accountTitle(_ account: CodexVisibleAccount, hidePersonalInfo: Bool) -> String {
        PersonalInfoRedactor.redactEmails(
            in: account.displayName,
            isEnabled: hidePersonalInfo) ?? account.displayName
    }
}
