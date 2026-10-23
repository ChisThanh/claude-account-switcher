import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AccountStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            MenuBarLabel(account: store.active, warn: store.active.map { store.health($0).level == .expired } ?? false)
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
            if store.isFirstLaunch || store.state.accounts.isEmpty { ManageWindow.show() }
        }
    }

    /// Opening the app again from Finder, Spotlight or Launchpad brings the window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in ManageWindow.show() }
        return false
    }
}

/// The menu bar shows who is logged in, not just an icon.
struct MenuBarLabel: View {
    let account: Account?
    let warn: Bool

    var body: some View {
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
        w.contentViewController = NSHostingController(rootView: MenuPanel().environmentObject(AccountStore.shared))
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
            w.contentViewController = NSHostingController(
                rootView: ManageView().environmentObject(AccountStore.shared))
            w.setContentSize(NSSize(width: 860, height: 600))
            w.minSize = NSSize(width: 760, height: 480)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
