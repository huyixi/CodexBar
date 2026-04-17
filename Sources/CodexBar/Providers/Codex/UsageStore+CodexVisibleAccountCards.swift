import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func refreshCodexVisibleAccountCards(
        visibleAccounts: [CodexVisibleAccount],
        selectedDidUpdate: @escaping @MainActor () -> Void,
        didFinish: @escaping @MainActor () -> Void)
    {
        self.codexVisibleAccountRefreshTask?.cancel()
        self.codexVisibleAccountRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshCodexVisibleAccountCardsNow(
                visibleAccounts: visibleAccounts,
                selectedDidUpdate: selectedDidUpdate,
                didUpdate: didFinish)
            didFinish()
            if !Task.isCancelled {
                self.codexVisibleAccountRefreshTask = nil
            }
        }
    }

    func refreshCodexVisibleAccountCardsNow(
        visibleAccounts: [CodexVisibleAccount],
        selectedDidUpdate: @escaping @MainActor () -> Void = {},
        didUpdate: @escaping @MainActor () -> Void = {}) async
    {
        guard visibleAccounts.count > 1 else { return }
        self.pruneCodexVisibleAccountSnapshotCache(visibleAccounts: visibleAccounts)
        if self.seedActiveCodexVisibleAccountSnapshotCache(visibleAccounts: visibleAccounts) {
            selectedDidUpdate()
        }

        let activeID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID
        for account in visibleAccounts where account.id != activeID {
            if Task.isCancelled { return }
            await self.refreshCodexVisibleAccountCard(account)
            if Task.isCancelled { return }
            didUpdate()
        }
    }

    func refreshCodexVisibleAccountCard(_ account: CodexVisibleAccount) async {
        let outcome = await self.fetchOutcome(
            provider: .codex,
            override: nil,
            codexActiveSourceOverride: account.selectionSource)
        switch outcome.result {
        case let .success(result):
            let snapshot = result.usage.scoped(to: .codex)
            self.codexVisibleAccountSnapshots[account.id] = CodexVisibleAccountUsageSnapshot(
                visibleAccountID: account.id,
                snapshot: snapshot,
                error: nil,
                sourceLabel: result.sourceLabel)
        case let .failure(error):
            self.codexVisibleAccountSnapshots[account.id] = CodexVisibleAccountUsageSnapshot(
                visibleAccountID: account.id,
                snapshot: nil,
                error: error.localizedDescription,
                sourceLabel: nil)
        }
    }

    @discardableResult
    func seedActiveCodexVisibleAccountSnapshotCache(visibleAccounts: [CodexVisibleAccount]? = nil) -> Bool {
        let accounts = visibleAccounts ?? self.settings.codexVisibleAccountProjection.visibleAccounts
        self.pruneCodexVisibleAccountSnapshotCache(visibleAccounts: accounts)
        guard let activeID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID,
              accounts.contains(where: { $0.id == activeID }),
              let snapshot = self.snapshots[.codex]
        else {
            return false
        }

        let cached = CodexVisibleAccountUsageSnapshot(
            visibleAccountID: activeID,
            snapshot: snapshot,
            error: nil,
            sourceLabel: self.lastSourceLabels[.codex])
        let previous = self.codexVisibleAccountSnapshots[activeID]
        self.codexVisibleAccountSnapshots[activeID] = cached
        return previous?.snapshot?.updatedAt != snapshot.updatedAt ||
            previous?.error != nil ||
            previous?.sourceLabel != cached.sourceLabel
    }

    func pruneCodexVisibleAccountSnapshotCache(visibleAccounts: [CodexVisibleAccount]) {
        let visibleIDs = Set(visibleAccounts.map(\.id))
        self.codexVisibleAccountSnapshots = self.codexVisibleAccountSnapshots.filter { key, _ in
            visibleIDs.contains(key)
        }
    }

    func clearCodexVisibleAccountSnapshotCache() {
        self.codexVisibleAccountRefreshTask?.cancel()
        self.codexVisibleAccountRefreshTask = nil
        self.codexVisibleAccountSnapshots.removeAll()
    }

    @discardableResult
    func applyCachedCodexVisibleAccountSnapshotIfAvailable(visibleAccountID: String) -> Bool {
        guard let cached = self.codexVisibleAccountSnapshots[visibleAccountID] else { return false }

        if let snapshot = cached.snapshot {
            self.snapshots[.codex] = snapshot
            if let sourceLabel = cached.sourceLabel {
                self.lastSourceLabels[.codex] = sourceLabel
            } else {
                self.lastSourceLabels.removeValue(forKey: .codex)
            }
            self.errors[.codex] = nil
            return true
        }

        if let error = cached.error {
            self.snapshots.removeValue(forKey: .codex)
            self.lastSourceLabels.removeValue(forKey: .codex)
            self.errors[.codex] = error
            return true
        }

        return false
    }
}
