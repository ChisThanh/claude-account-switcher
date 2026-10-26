A native macOS menu bar app to switch between multiple Claude Code accounts. It shows each account's usage limits and renews every login once a day. Universal build for Apple silicon and Intel, macOS 15 or later.

### Install

1. Download `ClaudeSwitcher-<version>.zip` below and unzip it.
2. Move `ClaudeSwitcher.app` to `/Applications` (or `~/Applications`).
3. Open it. The app is ad-hoc signed, not notarized by Apple, so macOS blocks it the first time. To allow it:
   - Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, or
   - run `xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app` in Terminal, then open the app again.

You need [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed. See the [README](https://github.com/ChisThanh/claude-account-switcher#readme) to get started.

### Cài đặt (Tiếng Việt)

Tải file `.zip` bên dưới, giải nén, rồi kéo `ClaudeSwitcher.app` vào thư mục Applications. App không được Apple công chứng, nên lần mở đầu tiên macOS sẽ chặn. Mở **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, bấm **Vẫn mở**. Cách khác là chạy `xattr -dr com.apple.quarantine /Applications/ClaudeSwitcher.app` trong Terminal rồi mở lại app. Xem [README tiếng Việt](https://github.com/ChisThanh/claude-account-switcher/blob/main/README.vi.md).

Unofficial project, not affiliated with Anthropic.
