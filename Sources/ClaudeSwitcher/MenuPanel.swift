import SwiftUI

struct MenuPanel: View {
    @Environment(AccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var others: [Account] { store.state.accounts.filter { $0.id != store.state.activeId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = store.banner {
                BannerView(banner: banner) { store.dismissBanner() }
            }
            if store.addingSince != nil {
                WaitingForLogin()
            }
            if !store.staleSessions.isEmpty {
                RestartHint(count: store.staleSessions.count)
            }

            if let active = store.active {
                activeCard(active)
            } else {
                emptyState
            }

            if let tip = store.suggestion() {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text("Tài khoản đang dùng đã dùng \(store.active?.usage?.load ?? 0)%. \(tip.account.title) mới dùng \(tip.load)%.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Chuyển") { store.switchTo(tip.account.id) }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
            }

            if !others.isEmpty {
                Text("CHUYỂN SANG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                // Past four accounts the list scrolls, so the panel never outgrows the screen.
                if others.count > 4 {
                    ScrollView {
                        VStack(spacing: 2) { ForEach(others) { AccountRow(account: $0) } }
                    }
                    .frame(height: 4 * 62)
                } else {
                    VStack(spacing: 2) { ForEach(others) { AccountRow(account: $0) } }
                }
            }

            Divider()
            HStack {
                AddAccountMenu {
                    Label("Thêm tài khoản", systemImage: "plus.circle.fill")
                }
                .fixedSize()
                Spacer()
                Button("Quản lý…") {
                    dismiss()
                    ManageWindow.show()
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
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
            Divider()
            UsageDetail(account: acc)
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
    @Environment(AccountStore.self) private var store
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
                UsageCompact(account: account)
            }
            Spacer(minLength: 0)
            if store.canReadUsage(account), !store.usageLoading.contains(account.id) {
                Button {
                    Task { await store.refreshUsage(account.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Cập nhật usage — chạy trong hồ sơ riêng, không đổi tài khoản đang dùng")
            }
            if health.level == .expired {
                AddAccountMenu(email: account.email) { Text("Đăng nhập lại") }.fixedSize()
                    .controlSize(.small)
            } else {
                Button("Chuyển") { store.switchTo(account.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
    }
}

struct SettingsMenu: View {
    @Environment(AccountStore.self) private var store

    var body: some View {
        Menu {
            Toggle("Tự gia hạn mọi tài khoản mỗi ngày", isOn: Binding(
                get: { store.state.autoKeepAlive },
                set: { store.setAutoKeepAlive($0) }))
            Toggle("Mở cùng macOS", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            Divider()
            Button("Cập nhật usage mọi tài khoản") { Task { await store.refreshAllUsage() } }
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
