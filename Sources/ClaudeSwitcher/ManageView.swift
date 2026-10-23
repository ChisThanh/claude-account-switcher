import SwiftUI

struct ManageView: View {
    @EnvironmentObject var store: AccountStore
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(store.state.accounts, selection: $selection) { acc in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(acc.title).bold()
                        if acc.id == store.state.activeId {
                            Text("đang dùng").font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text(store.status(acc)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(acc.id)
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let id = selection, let acc = store.account(id) {
                AccountDetail(account: acc).id(acc.id)
            } else {
                Text("Chọn một tài khoản").foregroundStyle(.secondary)
            }
        }
        .onAppear { selection = selection ?? store.state.activeId }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Thêm tài khoản…") { store.addAccount() }
            Toggle("Tự làm mới login sắp hết hạn", isOn: Binding(
                get: { store.state.autoKeepAlive },
                set: { store.setAutoKeepAlive($0) }))
            Toggle("Mở cùng macOS", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }
}

struct AccountDetail: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var label = ""
    @State private var token = ""

    private var isActive: Bool { account.id == store.state.activeId }

    var body: some View {
        Form {
            Section("Tài khoản") {
                LabeledContent("Email", value: account.email)
                if let name = account.displayName { LabeledContent("Tên", value: name) }
                if let org = account.organizationName { LabeledContent("Tổ chức", value: org) }
                if let plan = account.subscriptionType { LabeledContent("Gói", value: plan.capitalized) }
                TextField("Tên gợi nhớ", text: $label)
                    .onSubmit { store.setLabel(label, for: account.id) }
                HStack {
                    Button("Dùng tài khoản này") { store.switchTo(account.id) }
                        .disabled(isActive || store.busy)
                    Spacer()
                    Button("Xoá khỏi app", role: .destructive) { store.remove(account.id) }
                        .disabled(isActive)
                        .help(isActive ? "Chuyển sang tài khoản khác trước khi xoá" : "")
                }
            }

            Section("Login thường") {
                LabeledContent("Hạn login", value: Fmt.date(account.refreshTokenExpiresAt))
                LabeledContent("Làm mới gần nhất", value: Fmt.date(account.lastKeepAliveAt))
                Button(store.busy ? "Đang làm mới…" : "Làm mới login ngay") {
                    Task { await store.refreshLogin(account.id) }
                }
                .disabled(!account.loginUsable || store.busy)
                Text("Làm mới = tạm dùng tài khoản này, chạy một lệnh claude -p rất nhỏ để Claude Code tự lấy token mới, rồi chuyển lại tài khoản cũ.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Token dự phòng (claude setup-token, khoảng 1 năm)") {
                LabeledContent("Trạng thái", value: account.hasSetupToken
                    ? "Lưu \(Fmt.date(account.setupTokenAddedAt)) · hết hạn ~\(Fmt.date(account.setupTokenExpiresAt))"
                    : "Chưa có")
                HStack {
                    Button("Mở Terminal: claude setup-token") { store.createSetupToken() }
                    Text("Trên trình duyệt chọn đúng \(account.email)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    SecureField("Dán token sk-ant-oat01-…", text: $token)
                    Button("Lưu") {
                        if store.saveSetupToken(token, for: account.id) { token = "" }
                    }
                    .disabled(token.isEmpty)
                }
                Toggle("Luôn dùng token dự phòng thay cho login", isOn: Binding(
                    get: { account.preferSetupToken },
                    set: { store.setPreferSetupToken($0, for: account.id) }))
                    .disabled(!account.hasSetupToken)
                if account.hasSetupToken {
                    Button("Xoá token dự phòng", role: .destructive) { store.removeSetupToken(account.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { label = account.label ?? "" }
    }
}
