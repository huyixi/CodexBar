import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusMenuCodexSwitcherTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexSwitcherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    private func makeController(
        fetcher: UsageFetcher,
        store: UsageStore,
        settings: SettingsStore,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil) -> StatusItemController
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            codexAccountPromotionCoordinator: codexAccountPromotionCoordinator,
            statusBar: self.makeStatusBarForTesting())
    }

    private func installBlockingCodexProvider(on store: UsageStore, blocker: BlockingStatusMenuCodexFetchStrategy) {
        self.installCodexProvider(on: store, strategy: StatusMenuTestCodexFetchStrategy {
            try await blocker.awaitResult()
        })
    }

    private func installCodexProvider(on store: UsageStore, strategy: any ProviderFetchStrategy) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec, strategy: strategy)
    }

    private static func makeCodexProviderSpec(
        baseSpec: ProviderSpec,
        strategy: any ProviderFetchStrategy) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let descriptor = ProviderDescriptor(
            id: .codex,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseDescriptor.cli)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }

    fileprivate nonisolated static func makeSnapshot(
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

    @Test
    func `codex menu shows account switcher and one current usage card for multiple visible accounts`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "live@example.com"), provider: .codex)
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let projection = settings.codexVisibleAccountProjection
        let ids = self.representedIDs(in: menu)

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com", "managed@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(ids.contains("menuCard"))
        #expect(ids.contains { $0.hasPrefix("codexAccountCard-") } == false)
        #expect(menu.items.contains { $0.view is CodexAccountSwitcherView })
        #expect(menu.items.contains { $0.title == "Add Account..." } == false)
        #expect(menu.items.contains { $0.title == "Switch Account..." } == false)
    }

    @Test
    func `codex menu omits account cards when only one visible account exists`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        defer { settings._test_liveSystemCodexAccount = nil }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "solo@example.com"), provider: .codex)
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let ids = self.representedIDs(in: menu)

        #expect(settings.codexVisibleAccountProjection.visibleAccounts.map(\.email) == ["solo@example.com"])
        #expect(ids.contains { $0.hasPrefix("codexAccountCard-") } == false)
        #expect(ids.contains("menuCard"))
        #expect(menu.items.contains { $0.title == "Add Account..." } == false)
    }

    @Test
    func `accounts pane titles redact personal labels while preserving team workspace labels`() {
        let settings = self.makeSettings()
        settings.hidePersonalInfo = true
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let managedAccountID = UUID()
        let accounts = [
            CodexVisibleAccount(
                id: "live:provider:account-personal",
                email: "pl.fr@yandex.com",
                workspaceLabel: "Personal",
                workspaceAccountID: "account-personal",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "managed:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                email: "pl.fr@yandex.com",
                workspaceLabel: "IDconcepts",
                workspaceAccountID: "account-team",
                storedAccountID: managedAccountID,
                selectionSource: .managedAccount(id: managedAccountID),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true),
        ]

        let entries = accounts.map { account in
            CodexAccountUsageEntry(
                account: account,
                model: store.usageMenuCardModel(
                    for: .codex,
                    snapshotOverride: nil,
                    errorOverride: nil,
                    usesOverride: true),
                title: PersonalInfoRedactor.redactEmails(
                    in: account.displayName,
                    isEnabled: settings.hidePersonalInfo) ?? account.displayName,
                badgeText: nil)
        }
        let titles = entries.map(\.title)

        #expect(titles == ["Hidden — Personal", "Hidden — IDconcepts"])
        #expect(titles.contains { $0.contains("@") } == false)
        #expect(accounts[0].displayName == "pl.fr@yandex.com — Personal")
        #expect(accounts[0].menuDisplayName == "pl.fr@yandex.com")
    }

    @Test
    func `codex account usage card renders only session and weekly metrics`() {
        let metrics = [
            UsageMenuCardView.Model.Metric(
                id: "session",
                title: "Session",
                percent: 20,
                percentStyle: .left,
                resetText: "resets soon",
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: false),
            UsageMenuCardView.Model.Metric(
                id: "weekly",
                title: "Weekly",
                percent: 40,
                percentStyle: .left,
                resetText: "resets Monday",
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: false),
            UsageMenuCardView.Model.Metric(
                id: "monthly",
                title: "Monthly",
                percent: 60,
                percentStyle: .left,
                resetText: nil,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: false),
        ]
        let model = UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "account@example.com",
            subtitleText: "Updated now",
            subtitleStyle: .info,
            planText: nil,
            metrics: metrics,
            usageNotes: [],
            creditsText: nil,
            creditsRemaining: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
        let view = CodexAccountUsageCardView(
            accountTitle: "account@example.com",
            model: model,
            badgeText: "Current",
            width: 310)

        #expect(view.displayMetrics.map(\.id) == ["session", "weekly"])
    }

    @Test
    func `codex account switcher selection promotes the visible managed account to system`() async throws {
        self.disableMenuCardsForTesting()
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "StatusMenuCodexSwitcherTests-card-promotes")
        defer { container.tearDown() }
        self.enableOnlyCodex(container.settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = try container.createManagedAccount(
            id: managedAccountID,
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([managedAccount])
        try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")
        container.settings.codexActiveSource = .liveSystem
        container.usageStore._setSnapshotForTesting(Self.makeSnapshot(email: "live@example.com"), provider: .codex)

        let controller = self.makeController(
            fetcher: UsageFetcher(),
            store: container.usageStore,
            settings: container.settings,
            codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator(service: container.makeService()))
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let managedVisibleAccount = try #require(container.settings.codexVisibleAccountProjection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })
        let switcher = try #require(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
        switcher._test_select(accountID: managedVisibleAccount.id)

        for _ in 0..<20
            where container.settings.codexVisibleAccountProjection.liveVisibleAccountID != managedVisibleAccount.id
        {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(container.settings.codexVisibleAccountProjection.liveVisibleAccountID == managedVisibleAccount.id)
        #expect(try container.liveAuthData() == container.managedAuthData(for: managedAccount))
    }

    @Test
    func `codex account switcher selection follows live system account without promotion`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "managed@example.com"), provider: .codex)
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let liveVisibleAccountID = try #require(settings.codexVisibleAccountProjection.liveVisibleAccountID)
        let switcher = try #require(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
        switcher._test_select(accountID: liveVisibleAccountID)

        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    func `codex visible account card refresh scopes managed account without mutating active source`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "live@example.com"), provider: .codex)
        let recorder = StatusMenuCodexFetchContextRecorder()
        self.installCodexProvider(
            on: store,
            strategy: CapturingStatusMenuCodexFetchStrategy(
                recorder: recorder,
                managedHomePath: managedHome.path,
                managedEmail: "managed@example.com",
                liveEmail: "live@example.com"))

        let projection = settings.codexVisibleAccountProjection
        let managedVisibleAccount = try #require(projection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })

        await store.refreshCodexVisibleAccountCardsNow(visibleAccounts: projection.visibleAccounts)

        #expect(settings.codexActiveSource == .liveSystem)
        #expect(store.codexVisibleAccountSnapshots[managedVisibleAccount.id]?.snapshot?
            .accountEmail(for: .codex) == "managed@example.com")
        let environments = await recorder.environments()
        #expect(environments.count == 1)
        #expect(environments.first?["CODEX_HOME"] == managedHome.path)
    }

    @Test
    func `failed codex visible account card refresh keeps successful cached cards`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-444444444444"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "live@example.com"), provider: .codex)
        self.installCodexProvider(
            on: store,
            strategy: FailingStatusMenuCodexFetchStrategy(message: "quota unavailable"))

        let projection = settings.codexVisibleAccountProjection
        let activeVisibleAccountID = try #require(projection.activeVisibleAccountID)
        let managedVisibleAccount = try #require(projection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })

        await store.refreshCodexVisibleAccountCardsNow(visibleAccounts: projection.visibleAccounts)

        #expect(store.codexVisibleAccountSnapshots[activeVisibleAccountID]?.snapshot?
            .accountEmail(for: .codex) == "live@example.com")
        #expect(store.codexVisibleAccountSnapshots[managedVisibleAccount.id]?.snapshot == nil)
        #expect(store.codexVisibleAccountSnapshots[managedVisibleAccount.id]?.error == "quota unavailable")
    }

    @Test
    func `codex account state disables add account while managed authentication is in flight`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        defer { settings._test_liveSystemCodexAccount = nil }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = BlockingManagedCodexLoginRunnerForStatusMenuTests()
        let service = ManagedCodexAccountService(
            store: InMemoryManagedCodexAccountStoreForStatusMenuTests(),
            homeFactory: TestManagedCodexHomeFactoryForStatusMenuTests(root: root),
            loginRunner: runner,
            identityReader: StubManagedCodexIdentityReaderForStatusMenuTests(email: "managed@example.com"))
        let coordinator = ManagedCodexAccountCoordinator(service: service)
        let authTask = Task { try await coordinator.authenticateManagedAccount() }
        await runner.waitUntilStarted()

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.canAddAccount == false)
        #expect(state.isAuthenticatingManagedAccount)
        #expect(state.addAccountTitle == "Adding Account…")

        await runner.resume()
        _ = try await authTask.value
    }

    @Test
    func `codex account state disables add account when managed store is unreadable`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_unreadableManagedCodexAccountStore = true
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_unreadableManagedCodexAccountStore = false
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.hasUnreadableManagedAccountStore)
        #expect(state.canAddAccount == false)
    }

    @Test
    func `codex account switcher promotes managed row when same email rows split by identity`() async throws {
        self.disableMenuCardsForTesting()
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "StatusMenuCodexSwitcherTests-card-promotes-split")
        defer { container.tearDown() }
        self.enableOnlyCodex(container.settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let managedAccount = try container.createManagedAccount(
            id: managedAccountID,
            persistedEmail: "same@example.com",
            authAccountID: "account-managed")
        try container.persistAccounts([managedAccount])
        try container.writeLiveOAuthAuthFile(email: "same@example.com")
        container.settings.codexActiveSource = .liveSystem
        container.usageStore._setSnapshotForTesting(Self.makeSnapshot(email: "same@example.com"), provider: .codex)

        let projection = container.settings.codexVisibleAccountProjection
        #expect(projection.visibleAccounts.count == 2)
        let managedVisibleAccount = try #require(projection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })

        let controller = self.makeController(
            fetcher: UsageFetcher(),
            store: container.usageStore,
            settings: container.settings,
            codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator(service: container.makeService()))
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let switcher = try #require(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
        switcher._test_select(accountID: managedVisibleAccount.id)

        for _ in 0..<20 {
            let updatedProjection = container.settings.codexVisibleAccountProjection
            let liveAccount = updatedProjection.visibleAccounts
                .first { $0.id == updatedProjection.liveVisibleAccountID }
            if liveAccount?.storedAccountID == managedAccountID {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let updatedProjection = container.settings.codexVisibleAccountProjection
        let liveAccount = try #require(updatedProjection.visibleAccounts
            .first { $0.id == updatedProjection.liveVisibleAccountID })
        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(liveAccount.storedAccountID == managedAccountID)
        #expect(try container.liveAuthData() == container.managedAuthData(for: managedAccount))
    }
}

private struct StatusMenuTestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "status-menu-test-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "status-menu-test-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor StatusMenuCodexFetchContextRecorder {
    private var recordedEnvironments: [[String: String]] = []

    func record(_ environment: [String: String]) {
        self.recordedEnvironments.append(environment)
    }

    func environments() -> [[String: String]] {
        self.recordedEnvironments
    }
}

private struct CapturingStatusMenuCodexFetchStrategy: ProviderFetchStrategy {
    let recorder: StatusMenuCodexFetchContextRecorder
    let managedHomePath: String
    let managedEmail: String
    let liveEmail: String

    var id: String {
        "status-menu-capturing-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.record(context.env)
        let email = context.env["CODEX_HOME"] == self.managedHomePath ? self.managedEmail : self.liveEmail
        return self.makeResult(
            usage: StatusMenuCodexSwitcherTests.makeSnapshot(email: email, usedPercent: 12),
            sourceLabel: "status-menu-capturing-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct FailingStatusMenuCodexFetchStrategy: ProviderFetchStrategy {
    let message: String

    var id: String {
        "status-menu-failing-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw StatusMenuCodexFetchError(message: self.message)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct StatusMenuCodexFetchError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

private actor BlockingStatusMenuCodexFetchStrategy {
    private var waiters: [CheckedContinuation<Result<UsageSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> UsageSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<UsageSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private actor BlockingManagedCodexLoginRunnerForStatusMenuTests: ManagedCodexLoginRunning {
    private var waiters: [CheckedContinuation<CodexLoginRunner.Result, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume() {
        let result = CodexLoginRunner.Result(outcome: .success, output: "ok")
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private final class InMemoryManagedCodexAccountStoreForStatusMenuTests: ManagedCodexAccountStoring,
@unchecked Sendable {
    private var snapshot = ManagedCodexAccountSet(version: 1, accounts: [])

    func loadAccounts() throws -> ManagedCodexAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        self.snapshot = accounts
    }

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private struct TestManagedCodexHomeFactoryForStatusMenuTests: ManagedCodexHomeProducing {
    let root: URL

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexIdentityReaderForStatusMenuTests: ManagedCodexIdentityReading {
    let email: String

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        CodexAuthBackedAccount(
            identity: CodexIdentityResolver.resolve(accountId: nil, email: self.email),
            email: self.email,
            plan: "Pro")
    }
}
