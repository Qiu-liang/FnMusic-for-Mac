import SwiftUI
import AppKit

/// macOS injects an untranslated “Toggle Sidebar” item into the Help menu for
/// every window. Sidebar visibility is fixed in FnMusic, so remove that command.
@MainActor
final class ApplicationMenuLocalizer: NSObject, NSApplicationDelegate {
    private static let systemSidebarSelector = NSSelectorFromString("toggleSidebar:")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // SwiftUI can install the toolbar item after the first window appears,
            // so sweep after the window and toolbar have settled.
            for delay in [250, 600, 1400] {
                try? await Task.sleep(for: .milliseconds(delay))
                Self.removeSystemSidebarControls()
            }
        }
    }

    private static func removeSystemSidebarControls() {
        if let mainMenu = NSApp.mainMenu {
            for topLevel in mainMenu.items {
                guard let submenu = topLevel.submenu else { continue }
                for item in submenu.items where item.action == systemSidebarSelector {
                    submenu.removeItem(item)
                }
            }
        }

        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            for (index, item) in toolbar.items.enumerated().reversed()
            where item.action == systemSidebarSelector {
                toolbar.removeItem(at: index)
            }
        }
    }
}

@main
struct FnMusicApp: App {
    @NSApplicationDelegateAdaptor(ApplicationMenuLocalizer.self) private var menuLocalizer
    @State private var app = AppState()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup("FnMusic") {
            Group {
                if app.isRestoring {
                    ProgressView("正在恢复会话…")
                } else if let library = app.library {
                    RootView().environment(library)
                } else {
                    ConnectionView()
                }
            }
            .environment(app)
            .frame(minWidth: 820, minHeight: 600)
            .tint(.pink)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .focusEffectDisabled()
            .task {
                #if DEBUG
                // Hosted tests inject their own clients/windows. Never let test
                // launch access the user's real Keychain or restore a NAS session.
                if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    app.isRestoring = false
                    return
                }
                #endif
                await app.restore()
            }
        }
        .defaultSize(width: 1280, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("播放") {
                Button("播放 / 暂停") { app.library?.player.toggle() }
                    .keyboardShortcut(" ", modifiers: [])
                    .disabled(app.library?.player.currentTrack == nil)
                Button("下一首") { app.library?.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { app.library?.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索音乐") {
                    if let library = app.library { library.toolbarSearchFocus = UUID() }
                    else { app.selection = .search }
                }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // Suppress the system View-menu sidebar toggle as well.
            CommandGroup(replacing: .sidebar) {}
        }

        Settings {
            SettingsView().environment(app).tint(.pink)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .focusEffectDisabled()
        }
    }

}
