import SwiftUI

@main
struct FnMusicApp: App {
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
            CommandMenu("Playback") {
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
        }

        Settings {
            SettingsView().environment(app).tint(.pink)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}
