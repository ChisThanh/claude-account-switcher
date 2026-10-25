import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = AccountStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar-only app shows nothing when started, so open the window the
        // first time and whenever there is nothing to manage yet.
        Task { @MainActor in
            let store = AccountStore.shared
            if CommandLine.arguments.contains("--preview-panel") { return PanelPreview.show() }
            // `--renew <email>`: runs the same renewal as the button, for testing.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--renew"), i + 1 < args.count,
               let acc = store.state.accounts.first(where: { $0.email == args[i + 1] }) {
                ManageWindow.show()
                await store.refreshLogin(acc.id)
                return
            }
            if store.isFirstLaunch || store.state.accounts.isEmpty { ManageWindow.show() }
        }
    }

    /// Opening the app again from Finder, Spotlight or Launchpad brings the window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in ManageWindow.show() }
        return false
    }
}

/// The menu bar shows who is logged in, not just an icon. It reads the store
/// itself, so Observation redraws it only when the active account changes.
struct MenuBarLabel: View {
    private let store = AccountStore.shared

    var body: some View {
        let account = store.active
        let warn = account.map { store.health($0).level == .expired } ?? false
        HStack(spacing: 3) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "sparkle")
            if let account {
                Text(shortName(account))
            }
        }
    }

    private func shortName(_ acc: Account) -> String {
        if let label = acc.label, !label.isEmpty { return String(label.prefix(14)) }
        return String(acc.email.split(separator: "@").first?.prefix(14) ?? "")
    }
}

/// `--preview-panel`: the menu bar panel in a plain window, for screenshots.
@MainActor
enum PanelPreview {
    private static var window: NSWindow?

    static func show() {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Panel preview"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: MenuPanel().environment(AccountStore.shared))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum ManageWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Claude Switcher"
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: ManageView().environment(AccountStore.shared))
            // By default the hosting controller sizes the window to the content's
            // ideal size: the ~1700 pt detail column made it taller than the
            // screen, title bar off the top. Let SwiftUI set only the minimum;
            // the window (and the user) choose the rest and the content scrolls.
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.minSize = NSSize(width: 720, height: 420)
            w.setContentSize(NSSize(width: 860, height: 600))
            w.center()
            w.setFrameAutosaveName("ClaudeSwitcherManage")   // remembers the user's size and place
            window = w
        }
        if let w = window { fitOnScreen(w) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Otherwise AppKit focuses the first text field (the label field at the
        // bottom of the detail) and scrolls the page down to it.
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }

    /// Keeps the whole window, title bar included, inside the screen's usable area.
    private static func fitOnScreen(_ w: NSWindow) {
        guard let visible = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: true) }
    }
}
