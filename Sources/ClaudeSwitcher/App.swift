import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Image(systemName: "person.2.circle")
        }

        Window("Tài khoản Claude", id: "manage") {
            ManageView()
                .environmentObject(store)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.state.accounts.isEmpty {
            Text("Chưa có tài khoản — đăng nhập claude để app tự nhận")
        }
        ForEach(store.state.accounts) { acc in
            Button((acc.id == store.state.activeId ? "✓ " : "     ") + acc.title + "  —  " + store.status(acc)) {
                store.switchTo(acc.id)
            }
            .disabled(store.busy || acc.id == store.state.activeId)
        }
        Divider()
        Button("Thêm tài khoản…") { store.addAccount() }
        Button("Quản lý tài khoản…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "manage")
        }
        Button("Đồng bộ ngay") { store.tick() }
        if let message = store.message {
            Divider()
            Text(message)
        }
        Divider()
        Button("Thoát") { NSApp.terminate(nil) }
    }
}
