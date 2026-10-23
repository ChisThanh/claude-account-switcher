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
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Đang chờ bạn đăng nhập…").font(.callout.weight(.medium))
                Text("Làm theo Terminal và trình duyệt. Muốn tài khoản khác mà trình duyệt tự chọn tài khoản cũ? Mở link trong Terminal bằng cửa sổ ẩn danh.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Huỷ", action: cancel).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
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
    @EnvironmentObject var store: AccountStore
    let account: Account

    var body: some View {
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
    @EnvironmentObject var store: AccountStore
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
    @EnvironmentObject var store: AccountStore
    let account: Account

    var body: some View {
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
