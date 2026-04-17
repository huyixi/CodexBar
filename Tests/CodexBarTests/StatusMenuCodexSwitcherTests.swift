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
        settings: SettingsStore) -> StatusItemController
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
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
    func `codex menu shows account cards and add account action for multiple visible accounts`() throws {
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
        let cardIDs = ids.filter { $0.hasPrefix("codexAccountCard-") }

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com", "managed@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(cardIDs == ["codexAccountCard-live@example.com", "codexAccountCard-managed@example.com"])
        #expect(ids.contains("menuCard") == false)
        #expect(menu.items.contains { $0.view is CodexAccountSwitcherView } == false)
        #expect(menu.items.contains { $0.title == "Add Account..." })
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
        #expect(menu.items.contains { $0.title == "Add Account..." })
    }

    @Test
    func `codex account card title redacts personal labels while preserving team workspace labels`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.hidePersonalInfo = true
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
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

        let titles = accounts.map { controller._test_codexAccountCardTitle(for: $0) }

        #expect(titles == ["Hidden", "Hidden — IDconcepts"])
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
            isActive: true,
            width: 310)

        #expect(view.displayMetrics.map(\.id) == ["session", "weekly"])
    }

    @Test
    func `codex account card selection activates the visible managed account`() throws {
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
        self.installCodexProvider(on: store, strategy: StatusMenuTestCodexFetchStrategy {
            Self.makeSnapshot(email: "managed@example.com", usedPercent: 9)
        })
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let item = try #require(menu.items.first {
            ($0.representedObject as? String) == "codexAccountCard-managed@example.com"
        })
        let action = try #require(item.action)
        let target = try #require(item.target as? StatusItemController)
        _ = target.perform(action, with: item)

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
    }

    @Test
    func `codex account card clears stale account state on the first click`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = false
        settings.codexCookieSource = .off
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
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")),
            provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let blocker = BlockingStatusMenuCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let item = try #require(menu.items.first {
            ($0.representedObject as? String) == "codexAccountCard-managed@example.com"
        })
        let action = try #require(item.action)
        let target = try #require(item.target as? StatusItemController)
        _ = target.perform(action, with: item)

        await blocker.waitUntilStarted()
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
        #expect(store.snapshots[.codex] == nil)

        await blocker.resume(with: .success(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 9, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro"))))
        for _ in 0..<10 where store.snapshots[.codex]?.accountEmail(for: .codex) != "managed@example.com" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "managed@example.com")
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
    func `codex account card can select managed row when same email rows split by identity`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "same@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "same@example.com",
            plan: "pro",
            accountID: "account-managed")
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "same@example.com"))
        settings.codexActiveSource = .liveSystem

        let projection = settings.codexVisibleAccountProjection
        #expect(projection.visibleAccounts.count == 2)
        let managedVisibleAccount = try #require(projection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(Self.makeSnapshot(email: "same@example.com"), provider: .codex)
        self.installCodexProvider(on: store, strategy: StatusMenuTestCodexFetchStrategy {
            Self.makeSnapshot(email: "same@example.com", usedPercent: 9)
        })
        let controller = self.makeController(fetcher: fetcher, store: store, settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let item = try #require(menu.items.first {
            ($0.representedObject as? String) == "codexAccountCard-\(managedVisibleAccount.id)"
        })
        let action = try #require(item.action)
        let target = try #require(item.target as? StatusItemController)
        _ = target.perform(action, with: item)

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
    }
}

extension StatusMenuCodexSwitcherTests {
    private static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountID: String? = nil) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountID: accountID),
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, accountID: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var payloadObject: [String: Any] = [
            "email": email,
            "chatgpt_plan_type": plan,
        ]
        if let accountID {
            payloadObject["https://api.openai.com/auth"] = [
                "chatgpt_account_id": accountID,
            ]
        }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
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
