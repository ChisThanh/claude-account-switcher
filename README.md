# Claude Switcher

App trên thanh menu macOS để giữ nhiều tài khoản Claude Code và chuyển qua lại giữa chúng.

## Cài đặt

```sh
./scripts/build-app.sh --install   # build, copy vào ~/Applications rồi mở
```

Cần macOS 15 và Xcode (Swift 6). App được ký ad-hoc, không cần Apple Developer ID.

## Ngôn ngữ

App có tiếng Việt (mặc định) và tiếng Anh. Đổi trong menu ⚙ → **Ngôn ngữ / Language**. Đổi xong, panel và cửa sổ hiển thị lại ngay. Trong code, mỗi câu được viết song ngữ ngay tại chỗ dùng: `L("tiếng Việt", "English")`.

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
- **Tự gia hạn hằng ngày:** mọi tài khoản đã đăng nhập, kể cả tài khoản đang dùng, được gia hạn ít nhất 1 lần mỗi 24 giờ để token luôn mới. Lưu ý: ngày 23/10 một lần làm mới token *không* đẩy hạn login (khoảng 30 ngày kể từ lúc đăng nhập) ra xa hơn. Vì vậy khi login còn dưới 5 ngày mà chưa có token dự phòng, app nhắc đăng nhập lại. Gia hạn chỉ chạy khi access token (sống khoảng 8 giờ) đã hết hạn. Lượt nào Claude Code đã tự làm mới trong ngày thì app bỏ qua. Cách làm: chạy `/usage` (miễn phí), nếu token chưa đổi thì gửi `claude -p "Reply with OK" --model haiku`.

## Usage

App đọc usage bằng `claude -p /usage --no-session-persistence`. Đây là lệnh chạy cục bộ: không tốn lượt chat và không lưu lịch sử phiên.

- **Tài khoản đang dùng:** khi mở panel hoặc cửa sổ thì đọc lại nếu số liệu cũ hơn 60 giây (mỗi 3 phút khi cửa sổ vẫn mở), và ngay sau khi chuyển tài khoản. Khi chạy ngầm thì 15 phút một lần, ở mức ưu tiên thấp, vì mỗi lần tốn khoảng 6 giây CPU.
- **Tài khoản khác:** hiện lần đọc gần nhất. Phần nào đã qua giờ reset thì tính về 0%. Nút ↻ đọc lại trong hồ sơ riêng của tài khoản đó (xem dưới). Lần gia hạn hằng ngày cũng đọc luôn usage.
- **Gợi ý chuyển tài khoản:** khi tài khoản đang dùng đã dùng từ 80% trở lên, panel gợi ý tài khoản còn nhiều hạn mức nhất.
- Token dự phòng không đọc được usage của gói, vì nó không có quyền đọc hồ sơ tài khoản.

## Hồ sơ riêng: không đổi tài khoản đang dùng

Đọc usage và gia hạn **không bao giờ chuyển login đang dùng**, nên các phiên agent đang chạy không bị gián đoạn.

- **Tài khoản không dùng:** chạy trong hồ sơ riêng `~/Library/Application Support/ClaudeSwitcher/profiles/<id>/`, bằng `CLAUDE_CONFIG_DIR`. Với biến này, Claude Code dùng mục Keychain riêng `Claude Code-credentials-<8 ký tự hex đầu của sha256(đường dẫn)>`. App chép login mới nhất vào hồ sơ trước khi chạy, và lưu ngược token Claude Code đã đổi sau khi chạy.
- **Tài khoản đang dùng:** chạy thẳng trên login hiện tại, giống như mở thêm một phiên của chính tài khoản đó. App không bao giờ chạy hồ sơ riêng cho tài khoản này, vì như vậy sẽ đổi refresh token mà các phiên đang mở đang giữ. Trường hợp ngoại lệ: khi tài khoản này đang chạy bằng token dự phòng thì vẫn dùng hồ sơ riêng.
- Bấm Chuyển sang một tài khoản đúng lúc hồ sơ của nó đang chạy thì app chờ chạy xong rồi mới chuyển, để không mất token vừa đổi.

## Thêm tài khoản

1. Bấm **Thêm tài khoản** và chọn cách mở trang đăng nhập:
   - **Cửa sổ ẩn danh** (Brave, Chrome, Edge, Firefox…): dùng để đăng nhập một tài khoản *khác* với tài khoản claude.ai đang mở trên trình duyệt chính.
   - **Trình duyệt chính:** dùng tài khoản claude.ai đang đăng nhập sẵn.
   - **Chỉ copy link:** dán vào trình duyệt nào cũng được. Safari không mở ẩn danh bằng dòng lệnh được, nên với Safari hãy chọn cách này rồi dán vào cửa sổ riêng tư (Cmd+Shift+N).

   App chạy `claude auth login` ở nền với `BROWSER=/usr/bin/true`, nên Claude Code không tự mở trình duyệt, và đọc link đăng nhập từ output. Không cần Terminal.
2. Đăng nhập xong, app tự nhận tài khoản sau vài giây. Trong lúc chờ có thể **Mở lại link…** hoặc **Huỷ**.

3. Trong **Quản lý tài khoản…**, bấm **Mở Terminal: claude setup-token**. Trên trình duyệt chọn đúng tài khoản đó, rồi dán token vào ô **Dán token** và bấm **Lưu**.

Chỉ dùng các tài khoản do chính bạn sở hữu. Dùng chung tài khoản với người khác là trái điều khoản của Anthropic.
