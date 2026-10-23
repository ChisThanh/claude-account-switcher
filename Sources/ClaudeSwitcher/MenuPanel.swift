import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    private var others: [Account] { store.state.accounts.filter { $0.id != store.state.activeId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = store.banner {
                BannerView(banner: banner) { store.dismissBanner() }
            }
            if store.addingSince != nil {
                WaitingForLogin { store.cancelAdding() }
            }
            if !store.staleSessions.isEmpty {
                RestartHint(count: store.staleSessions.count)
            }

            if let active = store.active {
                activeCard(active)
            } else {
                emptyState
            }

            if !others.isEmpty {
                Text("CHUYỂN SANG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(others) { AccountRow(account: $0) }
                }
            }

            Divider()
            HStack {
                Button {
                    store.addAccount()
                } label: {
                    Label("Thêm tài khoản", systemImage: "plus.circle.fill")
                }
                .disabled(store.addingSince != nil)
                Spacer()
                Button("Quản lý…") {
                    dismiss()
                    ManageWindow.show()
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Claude Switcher").font(.headline)
            Spacer()
            SettingsMenu()
        }
    }

    private func activeCard(_ acc: Account) -> some View {
        let health = store.health(acc)
        return VStack(alignment: .leading, spacing: 8) {
            Text("ĐANG DÙNG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Avatar(account: acc, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(acc.title).font(.headline).lineLimit(1)
                        PlanPill(plan: acc.subscriptionType)
                    }
                    if acc.title != acc.email {
                        Text(acc.email).font(.caption).foregroundStyle(.secondary)
                    }
                    HealthLine(level: health.level, text: health.text)
                }
                Spacer(minLength: 0)
            }
            if !acc.hasSetupToken {
                Button {
                    dismiss()
                    ManageWindow.show()
                } label: {
                    Label("Thêm token dự phòng 1 năm để không bị đăng xuất", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chưa có tài khoản nào").font(.callout.weight(.medium))
            Text("Bấm Thêm tài khoản để đăng nhập. Nếu bạn đã đăng nhập claude trong Terminal, app sẽ tự nhận sau vài giây.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var hovering = false

    var body: some View {
        let health = store.health(account)
        HStack(spacing: 10) {
            Avatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.title).lineLimit(1)
                    PlanPill(plan: account.subscriptionType)
                }
                HealthLine(level: health.level, text: health.text)
            }
            Spacer(minLength: 0)
            if health.level == .expired {
                Button("Đăng nhập lại") { store.addAccount(email: account.email) }
                    .controlSize(.small)
            } else {
                Button("Chuyển") { store.switchTo(account.id) }
                    .controlSize(.small)
                    .disabled(store.busy)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        Menu {
            Toggle("Tự làm mới login sắp hết hạn", isOn: Binding(
                get: { store.state.autoKeepAlive },
                set: { store.setAutoKeepAlive($0) }))
            Toggle("Mở cùng macOS", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            Divider()
            Button("Đồng bộ ngay") { store.tick(force: true) }
            Button("Thoát Claude Switcher") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
