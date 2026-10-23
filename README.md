# Claude Switcher

App trên thanh menu macOS để giữ nhiều tài khoản Claude Code và chuyển qua lại giữa chúng.

## Cài đặt

```sh
./scripts/build-app.sh --install   # build, copy vào ~/Applications rồi mở
```

Cần macOS 15 và Xcode (Swift 6). App được ký ad-hoc, không cần Apple Developer ID.

## Cách hoạt động

Claude Code lưu login ở hai chỗ:

| Nơi lưu | Nội dung |
|---|---|
| Keychain `Claude Code-credentials` | access token, refresh token và hạn của chúng |
| `~/.claude.json` → `oauthAccount` | email, tổ chức, gói |

App lưu bản sao của từng tài khoản trong Keychain (dịch vụ `ClaudeSwitcher`, mục `<accountUuid>.login` và `<accountUuid>.setup`). Các thông tin không bí mật nằm ở `~/Library/Application Support/ClaudeSwitcher/state.json`.

- **Chuyển tài khoản:** ghi login của tài khoản được chọn vào `Claude Code-credentials` và `oauthAccount`. Thư mục `~/.claude` (settings, plugin, MCP, memory) vẫn dùng chung, không bị đổi. Các phiên `claude` đang mở cần khởi động lại.
- **Đồng bộ mỗi 30 giây:**
  - Claude Code đổi token mới (rotate) thì app lưu lại, để bản sao không bị cũ.
  - Có login mới qua `claude auth login` thì app tự thêm tài khoản đó.
  - Một phiên cũ ghi đè lại token của tài khoản khác thì app giữ token đó cho đúng tài khoản rồi đặt lại tài khoản đang chọn.
- **Token dự phòng:** token tạo bằng `claude setup-token` sống khoảng 1 năm. Khi login của tài khoản đang dùng hết hạn (hoặc bật "Luôn dùng token dự phòng"), app ghi token này vào `~/.claude/settings.json` ở `env.CLAUDE_CODE_OAUTH_TOKEN`. Khi login dùng được lại, app gỡ token ra. Token này có thể không hỗ trợ một số tính năng gắn với claude.ai.
- **Tự gia hạn hằng ngày:** mọi tài khoản đã đăng nhập, kể cả tài khoản đang dùng, được gia hạn ít nhất 1 lần mỗi 24 giờ. Mỗi lần Claude Code làm mới token, hạn login được đẩy thêm khoảng 30 ngày, nên login không hết hạn. Gia hạn chỉ chạy khi access token (sống khoảng 8 giờ) đã hết hạn, vì Claude Code chỉ làm mới lúc đó. Lượt nào Claude Code đã tự làm mới trong ngày thì app bỏ qua. Cách làm: tạm chuyển sang tài khoản vài giây, chạy `/usage` (miễn phí). Nếu token vẫn chưa đổi thì gửi `claude -p "Reply with OK" --model haiku`. Sau đó chuyển lại.

## Usage

App đọc usage bằng `claude -p /usage --no-session-persistence`. Đây là lệnh chạy cục bộ: không tốn lượt chat và không lưu lịch sử phiên.

- **Tài khoản đang dùng:** khi mở panel hoặc cửa sổ thì đọc lại nếu số liệu cũ hơn 60 giây (mỗi 3 phút khi cửa sổ vẫn mở), và ngay sau khi chuyển tài khoản. Khi chạy ngầm thì 15 phút một lần, ở mức ưu tiên thấp, vì mỗi lần tốn khoảng 6 giây CPU.
- **Tài khoản khác:** hiện lần đọc gần nhất. Phần nào đã qua giờ reset thì tính về 0%. Nút ↻ tạm chuyển sang tài khoản đó vài giây để đọc rồi chuyển lại. Lần tự làm mới login cũng đọc luôn usage.
- **Gợi ý chuyển tài khoản:** khi tài khoản đang dùng đã dùng từ 80% trở lên, panel gợi ý tài khoản còn nhiều hạn mức nhất.
- Token dự phòng không đọc được usage của gói, vì nó không có quyền đọc hồ sơ tài khoản.

## Thêm tài khoản

1. Menu → **Thêm tài khoản…** mở Terminal với lệnh `claude auth login`. Đăng nhập tài khoản mới trên trình duyệt.
2. App tự nhận tài khoản mới, tối đa 30 giây sau.
3. Trong **Quản lý tài khoản…**, bấm **Mở Terminal: claude setup-token**. Trên trình duyệt chọn đúng tài khoản đó, rồi dán token vào ô **Dán token** và bấm **Lưu**.

Chỉ dùng các tài khoản do chính bạn sở hữu. Dùng chung tài khoản với người khác là trái điều khoản của Anthropic.
