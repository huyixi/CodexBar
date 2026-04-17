import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountsSectionStateTests {
    @Test
    func `live badge still shows for merged live row`() {
        let accountID = UUID()
        let mergedLiveAccount = CodexVisibleAccount(
            id: "merged@example.com",
            email: "merged@example.com",
            storedAccountID: accountID,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [mergedLiveAccount],
            currentVisibleAccountID: mergedLiveAccount.id,
            systemVisibleAccountID: mergedLiveAccount.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.showsLiveBadge(for: mergedLiveAccount))
    }

    @Test
    func `single account state uses static current row instead of picker`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            currentVisibleAccountID: managedAccount.id,
            systemVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.showsCurrentPicker == false)
        #expect(state.singleVisibleAccount?.id == managedAccount.id)
        #expect(state.currentVisibleAccount?.id == managedAccount.id)
    }

    @Test
    func `legacy selection notice surfaces when current and system differ`() {
        let managedAccountID = UUID()
        let liveAccount = CodexVisibleAccount(
            id: "live@example.com",
            email: "live@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [liveAccount, managedAccount],
            currentVisibleAccountID: managedAccount.id,
            systemVisibleAccountID: liveAccount.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.showsCurrentPicker)
        #expect(state.showsLegacySelectionNotice)
    }

    @Test
    func `remove in flight blocks add reauth and remove actions`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            currentVisibleAccountID: managedAccount.id,
            systemVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: true,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.canAddAccount == false)
        #expect(state.canReauthenticate(managedAccount) == false)
        #expect(state.canRemove(managedAccount) == false)
    }

    @Test
    func `promotion in flight blocks add reauth and remove actions`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            currentVisibleAccountID: managedAccount.id,
            systemVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: true,
            notice: nil)

        #expect(state.canAddAccount == false)
        #expect(state.canReauthenticate(managedAccount) == false)
        #expect(state.canRemove(managedAccount) == false)
    }
}
