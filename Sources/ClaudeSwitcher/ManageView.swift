import Combine
import SwiftUI

struct ManageView: View {
    @Environment(AccountStore.self) private var store
    @State private var selection: String?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section("Tài khoản") {
                    ForEach(store.state.accounts) { acc in
                        HStack(spacing: 10) {
                            Avatar(account: acc, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(acc.title).lineLimit(1)
                                    if acc.id == store.state.activeId {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                    }
                                }
                                let h = store.health(acc)
                                HealthLine(level: h.level, text: h.text)
                                UsageCompact(account: acc)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(acc.id)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if store.addingSince != nil {
                        WaitingForLogin { store.cancelAdding() }
                    }
                    Button {
                        store.addAccount()
                    } label: {
                        Label("Thêm tài khoản", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.addingSince != nil)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if let banner = store.banner {
                        BannerView(banner: banner) { store.dismissBanner() }
                    }
                    if !store.staleSessions.isEmpty {
                        RestartHint(count: store.staleSessions.count)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, store.banner == nil && store.staleSessions.isEmpty ? 0 : 16)

                if let id = selection, let acc = store.account(id) {
                    AccountDetail(account: acc).id(acc.id)
                } else if store.state.accounts.isEmpty {
                    Onboarding()
                } else {
                    Text("Chọn một tài khoản bên trái").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem { SettingsMenu() }
        }
        .onAppear {
            selection = selection ?? store.state.activeId
            store.viewAppeared()
        }
        .onDisappear { store.viewDisappeared() }
        .onChange(of: store.state.accounts.count) { _, _ in
            if selection == nil || store.account(selection!) == nil { selection = store.state.activeId }
        }
    }
}

private struct Onboarding: View {
    @Environment(AccountStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bắt đầu").font(.largeTitle.bold())
            step(1, "Thêm tài khoản", "Bấm Thêm tài khoản. Terminal mở ra, trình duyệt hỏi đăng nhập — chọn tài khoản Claude của bạn.")
            step(2, "Lặp lại cho từng tài khoản", "Mỗi lần đăng nhập xong, app tự nhận và lưu tài khoản đó.")
            step(3, "Thêm token dự phòng 1 năm", "Chọn từng tài khoản và làm theo mục Token dự phòng để không bị đăng xuất khi lâu không dùng.")
            step(4, "Chuyển tài khoản", "Bấm icon ✦ trên thanh menu và chọn Chuyển.")
            Button("Thêm tài khoản đầu tiên") { store.addAccount() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct AccountDetail: View {
    @Environment(AccountStore.self) private var store
    let account: Account
    @State private var label = ""
    @State private var token = ""
    @State private var clipboardToken: String?
    @State private var confirmRemove = false
    @State private var saving = false

    private var isActive: Bool { account.id == store.state.activeId }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card(title: "Usage", icon: "chart.bar.fill") {
                    UsageDetail(account: account)
                    if !isActive {
                        Text("Số liệu của tài khoản không dùng là lần đọc gần nhất. Cập nhật = tạm chuyển sang tài khoản này vài giây để đọc rồi chuyển lại, không tốn lượt chat.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                loginCard
                backupCard
                otherCard
            }
            .padding(24)
        }
        .onAppear { label = account.label ?? "" }
        .task(id: account.hasSetupToken) {
            // Only while a token is missing, and the clipboard text is read only
            // when its change count moves (a plain integer check otherwise).
            guard !account.hasSetupToken else { return clipboardToken = nil }
            var seen = -1
            while !Task.isCancelled {
                let count = NSPasteboard.general.changeCount
                if count != seen {
                    seen = count
                    let found = store.clipboardSetupToken()
                    if found != clipboardToken { clipboardToken = found }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog("Xoá \(account.email) khỏi app?", isPresented: $confirmRemove) {
            Button("Xoá", role: .destructive) { store.remove(account.id) }
        } message: {
            Text("App sẽ quên login và token dự phòng đã lưu của tài khoản này. Tài khoản Claude của bạn không bị ảnh hưởng.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Avatar(account: account, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(account.title).font(.title2.bold()).lineLimit(1)
                    PlanPill(plan: account.subscriptionType)
                }
                if account.title != account.email {
                    Text(account.email).foregroundStyle(.secondary)
                }
                if let org = account.organizationName {
                    Text(org).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Label("Đang dùng", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Button("Dùng tài khoản này") { store.switchTo(account.id) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy || store.health(account).level == .expired)
            }
        }
    }

    private var loginCard: some View {
        let health = store.health(account)
        return Card(title: "Đăng nhập", icon: "person.badge.key") {
            HealthLine(level: health.level, text: health.text)
            Text(loginExplanation(health.level))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if health.level == .expired || !account.loginUsable {
                    Button("Đăng nhập lại") { store.addAccount(email: account.email) }
                } else if !isActive {
                    Button(store.busy ? "Đang làm mới…" : "Làm mới ngay") {
                        Task { await store.refreshLogin(account.id) }
                    }
                    .disabled(store.busy)
                }
                Spacer()
                Text("Hết hạn: \(Fmt.date(account.refreshTokenExpiresAt))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loginExplanation(_ level: AccountStore.HealthLevel) -> String {
        switch level {
        case .good, .soon:
            return isActive
                ? "Tài khoản đang dùng tự gia hạn mỗi khi bạn dùng claude."
                : "Khi tài khoản không dùng còn dưới 5 ngày, app tạm chuyển sang nó, chạy một lệnh claude rất nhỏ để gia hạn rồi chuyển lại."
        case .backup:
            return "Login thường đã hết hạn hoặc đang tắt, claude dùng token dự phòng. Đăng nhập lại để có đủ tính năng."
        case .expired:
            return "Login đã hết hạn và chưa có token dự phòng. Bấm Đăng nhập lại và chọn đúng \(account.email)."
        }
    }

    private var backupCard: some View {
        Card(title: "Token dự phòng 1 năm", icon: "shield.lefthalf.filled") {
            if account.hasSetupToken {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Đã có. Hết hạn khoảng \(Fmt.date(account.setupTokenExpiresAt)).")
                }
                Text("Khi login thường hết hạn, app tự chuyển claude sang token này để bạn không bị đăng xuất.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Nâng cao") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Luôn dùng token dự phòng thay cho login thường", isOn: Binding(
                            get: { account.preferSetupToken },
                            set: { store.setPreferSetupToken($0, for: account.id) }))
                        HStack {
                            Button("Tạo token mới…") { store.createSetupToken() }
                            Button("Xoá token", role: .destructive) { store.removeSetupToken(account.id) }
                        }
                    }
                    .padding(.top, 6)
                }
            } else {
                Text("Login thường chỉ sống khoảng 30 ngày nếu không dùng. Token này sống khoảng 1 năm và giữ bạn luôn đăng nhập.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                stepRow(1, "Tạo token") {
                    Button("Mở Terminal và tạo token") { store.createSetupToken() }
                    Text("Trình duyệt mở ra — đăng nhập đúng \(account.email). Terminal in ra một dòng bắt đầu bằng sk-ant-oat…, hãy copy dòng đó.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                stepRow(2, "Lưu token") {
                    if let clip = clipboardToken {
                        Button {
                            save(clip) { clipboardToken = nil }
                        } label: {
                            Label("Lưu token vừa copy (…\(clip.suffix(6)))", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving)
                    }
                    HStack {
                        SecureField(clipboardToken == nil ? "Dán token vào đây" : "hoặc dán token khác", text: $token)
                        Button("Lưu") {
                            save(token) { token = "" }
                        }
                        .disabled(token.isEmpty || saving)
                    }
                }
            }
        }
    }

    private func save(_ value: String, onSuccess: @escaping () -> Void) {
        saving = true
        Task {
            if await store.saveSetupToken(value, for: account.id) { onSuccess() }
            saving = false
        }
    }

    private func stepRow<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                content()
            }
        }
    }

    private var otherCard: some View {
        Card(title: "Khác", icon: "slider.horizontal.3") {
            HStack {
                TextField("Tên gợi nhớ, ví dụ: Công ty, Cá nhân", text: $label)
                    .onSubmit { store.setLabel(label, for: account.id) }
                Button("Lưu tên") { store.setLabel(label, for: account.id) }
                    .disabled(label == (account.label ?? ""))
            }
            HStack {
                Button("Xoá tài khoản khỏi app", role: .destructive) { confirmRemove = true }
                    .disabled(isActive)
                if isActive {
                    Text("Chuyển sang tài khoản khác trước khi xoá.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
