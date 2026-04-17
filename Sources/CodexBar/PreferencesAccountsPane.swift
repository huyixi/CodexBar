import SwiftUI

@MainActor
struct AccountsPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    private static let cardWidth: CGFloat = 332
    private static let columns = [
        GridItem(.adaptive(minimum: Self.cardWidth, maximum: Self.cardWidth), spacing: 12, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProviderSettingsSection(title: "Codex Usage") {
                    if let notice = self.state.notice {
                        Text(notice.text)
                            .font(.footnote)
                            .foregroundStyle(notice.tone == .warning ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if self.state.isEmpty {
                        Text("No Codex accounts detected yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                            ForEach(self.state.entries) { entry in
                                CodexAccountUsageCardView(
                                    accountTitle: entry.title,
                                    model: entry.model,
                                    badgeText: entry.badgeText,
                                    width: Self.cardWidth)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear {
            self.refreshAccountCards()
        }
        .onChange(of: self.settings.codexVisibleAccountProjection.visibleAccounts.map(\.id)) { _, _ in
            self.refreshAccountCards()
        }
        .onChange(of: self.settings.codexVisibleAccountProjection.activeVisibleAccountID) { _, _ in
            self.refreshAccountCards()
        }
    }

    var state: CodexAccountUsagePaneState {
        CodexAccountUsagePaneStateBuilder.make(settings: self.settings, store: self.store)
    }

    private func refreshAccountCards() {
        let visibleAccounts = self.settings.codexVisibleAccountProjection.visibleAccounts
        guard visibleAccounts.count > 1 else { return }
        self.store.refreshCodexVisibleAccountCards(
            visibleAccounts: visibleAccounts,
            selectedDidUpdate: {},
            didFinish: {})
    }
}
