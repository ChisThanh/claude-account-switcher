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
                Text("Làm theo Terminal và trình duyệt. App tự nhận tài khoản khi xong.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Huỷ", action: cancel).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
    }
}
