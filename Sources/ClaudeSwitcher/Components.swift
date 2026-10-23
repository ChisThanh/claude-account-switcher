import SwiftUI

struct Avatar: View {
    let account: Account
    var size: CGFloat = 32

    private var initials: String {
        let source = account.label?.isEmpty == false ? account.label! : (account.displayName ?? account.email)
        let words = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.orange, .blue, .purple, .teal, .pink, .indigo, .green, .brown]
        let sum = account.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
    }
}

struct HealthLine: View {
    let level: AccountStore.HealthLevel
    let text: String

    var color: Color {
        switch level {
        case .good: return .green
        case .soon: return .orange
        case .backup: return .blue
        case .expired: return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlanPill: View {
    let plan: String?

    var body: some View {
        if let plan {
            Text(plan.capitalized)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    private var style: (icon: String, color: Color) {
        switch banner.kind {
        case .info: return ("info.circle.fill", .blue)
        case .success: return ("checkmark.circle.fill", .green)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .error: return ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.icon).foregroundStyle(style.color)
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(style.color.opacity(0.12)))
    }
}

/// "N phiên claude vẫn chạy tài khoản cũ" after a switch.
struct RestartHint: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            Text("\(count) phiên claude đang mở vẫn dùng tài khoản cũ. Thoát và mở lại chúng (gõ /exit rồi chạy claude) để dùng tài khoản mới.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct WaitingForLogin: View {
    @Environment(AccountStore.self) private var store
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang chờ bạn đăng nhập…").font(.callout.weight(.medium))
                    Text(store.loginURL == nil
                         ? "Đang lấy link đăng nhập…"
                         : store.loginNeedsCode
                            ? "Đăng nhập trên trình duyệt. Trang sẽ hiện một mã — copy và dán vào ô bên dưới."
                            : "Đăng nhập trên trình duyệt vừa mở. App tự nhận tài khoản khi xong.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Huỷ") { store.cancelAdding() }.controlSize(.small)
            }
            if store.loginURL != nil {
                HStack(spacing: 6) {
                    TextField(store.loginNeedsCode ? "Dán mã từ trang đăng nhập" : "Trang hiện mã? Dán vào đây", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(send)
                    Button("Gửi mã", action: send)
                        .controlSize(.small)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Menu("Mở lại link…") {
                    LoginModeItems { store.openLoginURL($0) }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
    }

    private func send() {
        store.submitLoginCode(code)
        code = ""
    }
}

/// The ways to open a sign-in link: a private window first, since that is how
/// a second account gets in while the main browser is signed in to another.
struct LoginModeItems: View {
    let pick: (LoginOpenMode) -> Void
    private static let privateApps = LoginBrowser.privateCapable()

    var body: some View {
        let apps = Self.privateApps
        if apps.isEmpty {
            Text("Trình duyệt trên máy không mở được cửa sổ ẩn danh — dùng Chỉ copy link")
        }
        ForEach(apps) { app in
            Button {
                pick(.privateWindow(app))
            } label: {
                Label("Cửa sổ ẩn danh — \(app.name)", systemImage: "eyeglasses")
            }
        }
        Button {
            pick(.normal)
        } label: {
            Label("Trình duyệt chính — \(LoginBrowser.defaultBrowserName)", systemImage: "safari")
        }
        Divider()
        Button {
            pick(.copyOnly)
        } label: {
            Label("Chỉ copy link đăng nhập", systemImage: "doc.on.doc")
        }
    }
}

/// "Thêm tài khoản" / "Đăng nhập lại" as a pull-down of the open modes.
struct AddAccountMenu<MenuLabel: View>: View {
    @Environment(AccountStore.self) private var store
    var email: String? = nil
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            Section(email == nil ? "Mở trang đăng nhập bằng" : "Đăng nhập lại \(email!) bằng") {
                LoginModeItems { store.addAccount(email: email, open: $0) }
            }
        } label: {
            label()
        }
        .disabled(store.addingSince != nil)
    }
}

// MARK: Usage

private func usageColor(_ percent: Int) -> Color {
    percent >= 90 ? .red : percent >= 70 ? .orange : .green
}

struct UsageBar: View {
    let percent: Int
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(usageColor(percent).gradient)
                    .frame(width: max(geo.size.width * CGFloat(min(percent, 100)) / 100, percent > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}

/// Every plan limit with its bar and reset time, plus when it was read.
struct UsageDetail: View {
    @Environment(AccountStore.self) private var store
    let account: Account

    var body: some View {
        // Minute ticks keep "x phút trước" and passed resets current without a store change.
        TimelineView(.everyMinute) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let usage = account.usage {
                ForEach(usage.windows) { w in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(w.title).font(.callout)
                            Spacer()
                            Text("\(w.currentPercent)%").font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(usageColor(w.currentPercent))
                        }
                        UsageBar(percent: w.currentPercent)
                        if let reset = w.resetsAt {
                            Text(w.currentPercent < w.percent ? "Đã reset" : "Reset \(Fmt.reset(reset))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(store.canReadUsage(account) ? "Chưa có số liệu — bấm Cập nhật." : "Không đọc được usage khi đang dùng token dự phòng hoặc login đã hết hạn.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            UsageFooter(account: account)
        }
    }
}

struct UsageFooter: View {
    @Environment(AccountStore.self) private var store
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            if let usage = account.usage {
                Text("Cập nhật \(Fmt.ago(usage.fetchedAt))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if store.usageLoading.contains(account.id) {
                ProgressView().controlSize(.mini)
                Text("Đang đọc…").font(.caption2).foregroundStyle(.secondary)
            } else if store.canReadUsage(account) {
                Button {
                    Task { await store.refreshUsage(account.id) }
                } label: {
                    Label("Cập nhật", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(store.busy)
                .help(account.id == store.state.activeId
                      ? "Đọc lại usage"
                      : "Tạm chuyển sang tài khoản này vài giây để đọc usage, rồi chuyển lại")
            }
        }
    }
}

/// "Phiên ▮▮▯ 19% · Tuần ▮▮▮ 75%" for list rows.
struct UsageCompact: View {
    @Environment(AccountStore.self) private var store
    let account: Account

    var body: some View {
        // Minute ticks keep "x phút trước" and passed resets current without a store change.
        TimelineView(.everyMinute) { _ in content }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if store.usageLoading.contains(account.id) {
                ProgressView().controlSize(.mini)
                Text("Đang đọc usage…").font(.caption2).foregroundStyle(.secondary)
            } else if let usage = account.usage {
                ForEach([usage.session, usage.week].compactMap { $0 }) { w in
                    HStack(spacing: 4) {
                        Text(w.shortTitle).font(.caption2).foregroundStyle(.secondary)
                        UsageBar(percent: w.currentPercent, height: 4).frame(width: 34)
                        Text("\(w.currentPercent)%").font(.caption2.monospacedDigit())
                            .foregroundStyle(usageColor(w.currentPercent))
                    }
                }
                if account.id != store.state.activeId {
                    Text(Fmt.ago(usage.fetchedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text("Chưa có usage").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
