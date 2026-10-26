import Combine
import SwiftUI

struct ManageView: View {
    @Environment(AccountStore.self) private var store
    @State private var selection: String?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // A plain ScrollView, not List: the List-backed sidebar went blank
            // after a while of rows changing height (usage loading ↔ bars).
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Tài khoản", "Accounts"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(store.state.accounts) { acc in
                        SidebarRow(account: acc, selected: selection == acc.id) { selection = acc.id }
                    }
                }
                .padding(10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if store.addingSince != nil {
                        WaitingForLogin()
                    }
                    AddAccountMenu {
                        Label(L("Thêm tài khoản", "Add account"), systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
                    Text(L("Chọn một tài khoản bên trái", "Pick an account on the left")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .id(store.language)   // strings come from L(); a new language rebuilds them
        .frame(minWidth: 720, minHeight: 420)
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

private struct SidebarRow: View {
    @Environment(AccountStore.self) private var store
    let account: Account
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.title).lineLimit(1)
                    if account.id == store.state.activeId {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                let h = store.health(account)
                HealthLine(level: h.level, text: h.text)
                UsageCompact(account: account)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.28) : hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

private struct Onboarding: View {
    @Environment(AccountStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Bắt đầu", "Get started")).font(.largeTitle.bold())
            step(1, L("Thêm tài khoản", "Add account"), L("Bấm Thêm tài khoản và chọn cách mở: cửa sổ ẩn danh để đăng nhập một tài khoản khác với tài khoản đang mở trên trình duyệt chính.", "Click Add account and choose how to open it: a private window signs in an account other than the one open in your main browser."))
            step(2, L("Lặp lại cho từng tài khoản", "Repeat for each account"), L("Mỗi lần đăng nhập xong, app tự nhận và lưu tài khoản đó.", "After each login the app picks up and saves the account."))
            step(3, L("Thêm token dự phòng 1 năm", "Add a 1-year backup token"), L("Chọn từng tài khoản và làm theo mục Token dự phòng để không bị đăng xuất khi lâu không dùng.", "For each account, follow the backup token section so you aren't logged out after a long break."))
            step(4, L("Chuyển tài khoản", "Switch accounts"), L("Bấm icon ✦ trên thanh menu và chọn Chuyển.", "Click the ✦ icon in the menu bar and choose Switch."))
            AddAccountMenu { Text(L("Thêm tài khoản đầu tiên", "Add your first account")) }
                .menuStyle(.button).buttonStyle(.borderedProminent).controlSize(.large).fixedSize()
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
    @State private var advancedOpen = false

    private var isActive: Bool { account.id == store.state.activeId }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card(title: "Usage", icon: "chart.bar.fill") {
                    UsageDetail(account: account)
                    if !isActive {
                        Text(L("Số liệu của tài khoản không dùng là lần đọc gần nhất. Cập nhật chạy trong hồ sơ riêng của tài khoản này: không đổi tài khoản đang dùng, không làm gián đoạn phiên claude nào, không tốn lượt chat.", "Numbers for an account not in use are from the last read. Refresh runs in this account's own profile: the account in use doesn't change, no claude session is interrupted, and no messages are used."))
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
        .confirmationDialog(L("Xoá \(account.email) khỏi app?", "Remove \(account.email) from the app?"), isPresented: $confirmRemove) {
            Button(L("Xoá", "Remove"), role: .destructive) { store.remove(account.id) }
        } message: {
            Text(L("App sẽ quên login và token dự phòng đã lưu của tài khoản này. Tài khoản Claude của bạn không bị ảnh hưởng.", "The app will forget this account's saved login and backup token. Your Claude account itself is not affected."))
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
                Label(L("Đang dùng", "In use"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Button(L("Dùng tài khoản này", "Use this account")) { store.switchTo(account.id) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.health(account).level == .expired)
            }
        }
    }

    private var loginCard: some View {
        let health = store.health(account)
        return Card(title: L("Đăng nhập", "Login"), icon: "person.badge.key") {
            HealthLine(level: health.level, text: health.text)
            Text(loginExplanation(health.level))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if account.loginUsable {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text(L("Gia hạn gần nhất", "Last renewed")).foregroundStyle(.secondary)
                        Text(account.lastRenewedAt.map { Fmt.ago($0) } ?? L("chưa ghi nhận", "not recorded"))
                    }
                    GridRow {
                        Text(L("Lần tới", "Next")).foregroundStyle(.secondary)
                        Text(nextRenewalText)
                    }
                    GridRow {
                        Text(L("Hết hạn login", "Login expires")).foregroundStyle(.secondary)
                        Text(Fmt.date(account.refreshTokenExpiresAt))
                    }
                }
                .font(.callout)
            }
            HStack {
                if health.level == .expired || !account.loginUsable {
                    AddAccountMenu(email: account.email) { Text(L("Đăng nhập lại", "Log in again")) }.fixedSize()
                } else {
                    renewButton
                }
                Spacer()
            }
            if let note = store.renewNotes[account.id] {
                BannerView(banner: note) { store.dismissRenewNote(account.id) }
            }
        }
    }

    private func loginExplanation(_ level: AccountStore.HealthLevel) -> String {
        switch level {
        case .good, .soon:
            guard store.state.autoKeepAlive else {
                return L("Tự gia hạn hằng ngày đang tắt. Bật lại trong ⚙ để login không bao giờ hết hạn.", "Daily renewal is off. Turn it on in ⚙ to keep tokens fresh.")
            }
            return isActive
                ? L("App gia hạn mọi tài khoản ít nhất 1 lần mỗi ngày, kể cả tài khoản đang dùng, để token luôn mới. Lượt nào Claude Code đã tự làm mới thì app bỏ qua. Hạn login (khoảng 30 ngày từ lúc đăng nhập) không phải lúc nào cũng được máy chủ đẩy thêm — gần hết hạn thì token dự phòng 1 năm hoặc đăng nhập lại giữ tài khoản chạy.", "The app renews every account at least once a day, including the one in use, so its token stays fresh. If Claude Code already refreshed it that day, the app skips it. The login's own expiry (about 30 days from login) isn't always extended by the server — near the end, the 1-year backup token or a new login keeps the account working.")
                : L("App gia hạn mọi tài khoản ít nhất 1 lần mỗi ngày trong hồ sơ riêng của tài khoản này, không đổi tài khoản đang dùng: đọc /usage (miễn phí) để Claude Code lấy token mới, chỉ khi không được mới gửi 1 câu rất nhỏ bằng haiku. Hạn login không phải lúc nào cũng được đẩy thêm — gần hết hạn thì token dự phòng 1 năm hoặc đăng nhập lại giữ tài khoản chạy.", "The app renews every account at least once a day in that account's own profile, without changing the account in use: it reads /usage (free) so Claude Code gets a new token, and only if that doesn't work sends one tiny haiku message. The login's expiry isn't always extended — near the end, the 1-year backup token or a new login keeps the account working.")
        case .backup:
            return L("Login thường đã hết hạn hoặc đang tắt, claude dùng token dự phòng. Đăng nhập lại để có đủ tính năng.", "The regular login has expired or is turned off, so claude uses the backup token. Log in again for every feature.")
        case .expired:
            return L("Login đã hết hạn và chưa có token dự phòng. Bấm Đăng nhập lại và chọn đúng \(account.email).", "The login has expired and there is no backup token. Click Log in again and pick \(account.email).")
        }
    }

    /// Claude Code only swaps tokens once the access token (~8 h) has expired, so
    /// before that the button says when it becomes possible instead of doing nothing.
    @ViewBuilder private var renewButton: some View {
        let renewing = store.renewingIds.contains(account.id)
        TimelineView(.everyMinute) { _ in
            if let exp = account.accessTokenExpiresAt, exp > Date(), !renewing {
                VStack(alignment: .leading, spacing: 4) {
                    Button(L("Gia hạn được sau \(Fmt.reset(exp))", "Can renew after \(Fmt.reset(exp))")) {}.disabled(true)
                    Text(L("Token hiện tại còn hạn. Claude Code chỉ đổi token khi token cũ hết hạn, nên chưa gia hạn sớm hơn được.", "The current token is still valid. Claude Code only swaps tokens once the old one expires, so it can't be renewed earlier."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    Button(renewing ? L("Đang gia hạn…", "Renewing…") : L("Gia hạn ngay", "Renew now")) {
                        Task { await store.refreshLogin(account.id) }
                    }
                    .disabled(renewing)
                    if renewing { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var nextRenewalText: String {
        guard store.state.autoKeepAlive else { return L("tự gia hạn đang tắt", "daily renewal is off") }
        guard let next = store.nextRenewal(account), next > Date() else { return L("trong vài phút tới", "within a few minutes") }
        return Fmt.reset(next)
    }

    private var backupCard: some View {
        Card(title: L("Token dự phòng 1 năm", "1-year backup token"), icon: "shield.lefthalf.filled") {
            if account.hasSetupToken {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(L("Đã có. Hết hạn khoảng \(Fmt.date(account.setupTokenExpiresAt)).", "Saved. Expires around \(Fmt.date(account.setupTokenExpiresAt))."))
                }
                Text(L("Khi login thường hết hạn, app tự chuyển claude sang token này để bạn không bị đăng xuất.", "When the regular login expires, the app switches claude to this token so you aren't logged out."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $advancedOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L("Luôn dùng token dự phòng thay cho login thường", "Always use the backup token instead of the regular login"), isOn: Binding(
                            get: { account.preferSetupToken },
                            set: { store.setPreferSetupToken($0, for: account.id) }))
                        HStack {
                            Button(L("Tạo token mới…", "Create a new token…")) { store.createSetupToken() }
                            Button(L("Xoá token", "Remove token"), role: .destructive) { store.removeSetupToken(account.id) }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    // On macOS only the chevron toggles a DisclosureGroup; make the
                    // whole row a target.
                    Text(L("Nâng cao", "Advanced"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { advancedOpen.toggle() } }
                }
            } else {
                Text(L("Login thường chỉ sống khoảng 30 ngày nếu không dùng. Token này sống khoảng 1 năm và giữ bạn luôn đăng nhập.", "A regular login only lasts about 30 days if unused. This token lasts about a year and keeps you logged in."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                stepRow(1, L("Tạo token", "Create the token")) {
                    Button(L("Mở Terminal và tạo token", "Open Terminal and create a token")) { store.createSetupToken() }
                    Text(L("Trình duyệt mở ra — đăng nhập đúng \(account.email). Terminal in ra một dòng bắt đầu bằng sk-ant-oat…, hãy copy dòng đó.", "A browser opens — sign in as \(account.email). Terminal prints a line starting with sk-ant-oat…; copy that line."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                stepRow(2, L("Lưu token", "Save the token")) {
                    if let clip = clipboardToken {
                        Button {
                            save(clip) { clipboardToken = nil }
                        } label: {
                            Label(L("Lưu token vừa copy (…\(clip.suffix(6)))", "Save the copied token (…\(clip.suffix(6)))"), systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving)
                    }
                    HStack {
                        SecureField(clipboardToken == nil ? L("Dán token vào đây", "Paste the token here") : L("hoặc dán token khác", "or paste another token"), text: $token)
                        Button(L("Lưu", "Save")) {
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
        Card(title: L("Khác", "Other"), icon: "slider.horizontal.3") {
            HStack {
                TextField(L("Tên gợi nhớ, ví dụ: Công ty, Cá nhân", "Nickname, e.g. Work, Personal"), text: $label)
                    .onSubmit { store.setLabel(label, for: account.id) }
                Button(L("Lưu tên", "Save name")) { store.setLabel(label, for: account.id) }
                    .disabled(label == (account.label ?? ""))
            }
            HStack {
                Button(L("Xoá tài khoản khỏi app", "Remove account from app"), role: .destructive) { confirmRemove = true }
                    .disabled(isActive)
                if isActive {
                    Text(L("Chuyển sang tài khoản khác trước khi xoá.", "Switch to another account before removing.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
