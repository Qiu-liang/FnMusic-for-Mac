import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultVolume") private var defaultVolume = 0.7
    @AppStorage("autoAdvance") private var autoAdvance = true
    @AppStorage("defaultRepeat") private var defaultRepeat = "off"
    @AppStorage("experimentalWrites") private var experimentalWrites = false
    @State private var confirmExperimental = false
    @State private var cacheBytes: Int64 = 0
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        TabView {
            Form {
                Section("服务器") {
                    LabeledContent("地址", value: app.client?.origin.absoluteString ?? "未连接")
                    LabeledContent("名称", value: app.configuration?.serverName ?? "—")
                    LabeledContent("服务版本", value: app.configuration?.serverVersion ?? "—")
                    LabeledContent("媒体服务", value: app.configuration?.mediasrvVersion ?? "—")
                    LabeledContent("系统连接状态（原始值）", value: app.systemInfo?.connect?.status?.display ?? "未提供")
                    LabeledContent("连接状态", value: app.client == nil ? "未登录" : (app.network.hasNetworkPath ? "已登录 · 网络路径可用" : "网络不可用"))
                    Text("网络路径可用不代表服务器始终在线；请求失败时会显示实际错误。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("账户") {
                    LabeledContent("当前用户", value: app.user?.name ?? "—")
                    LabeledContent("角色", value: app.user?.role ?? "—")
                    Button("退出登录", role: .destructive) { Task { await app.logout() } }
                        .disabled(app.client == nil)
                    Text("只保存钥匙串会话，不保存密码。会话过期后需重新输入密码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.tabItem { Label("服务器", systemImage: "server.rack") }

            Form {
                Section("播放器") {
                    Slider(value: $defaultVolume, in: 0...1) { Text("默认音量") }
                        .onChange(of: defaultVolume) { _, value in app.library?.player.volume = value }
                    Toggle("播完自动播放下一首", isOn: $autoAdvance)
                    Picker("默认循环模式", selection: $defaultRepeat) {
                        ForEach(RepeatMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.onChange(of: defaultRepeat) { _, value in app.library?.player.queue.repeatMode = RepeatMode(rawValue: value) ?? .off }
                    LabeledContent("默认播放质量", value: "原始音频 · 不转码")
                    Text("转码 / HLS 为 H/F 级接口，暂未启用。格式支持取决于 macOS 原生解码器；CUE 虚拟分轨待验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
            }.tabItem { Label("播放与外观", systemImage: "play.circle") }

            Form {
                Section("缓存") {
                    LabeledContent("当前账户封面缓存", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                    Text("封面：内存 64 MB / 256 张，磁盘每账户 200 MB。搜索：最多 12 次查询，30 秒过期。音频不持久化。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清理当前账户缓存") { clearCache() }.disabled(busy || app.library == nil)
                    if busy { ProgressView().controlSize(.small) }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
                Section("实验性功能") {
                    Toggle("启用收藏和歌单写操作（H 级）", isOn: Binding(get: { experimentalWrites }, set: { value in
                        if value { confirmExperimental = true } else { experimentalWrites = false }
                    }))
                    Text("这些接口只有历史证据，不能保证所有服务器版本的行为。每次修改由你主动触发；成功后读回确认。不提供清理、扫描、任务控制或管理员操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("缓存与安全", systemImage: "externaldrive.badge.checkmark") }
            .task { await updateCacheSize() }

            VStack(spacing: 18) {
                Image(systemName: "music.note.house.fill").font(.system(size: 60)).foregroundStyle(.pink)
                Text("FnMusic").font(.largeTitle.weight(.semibold))
                Text("Unofficial Fn Music Client").foregroundStyle(.secondary)
                Text("版本 1.0.0 · macOS 原生客户端")
                Text("API 依据：FnMusicAPI.md\n文档范围：server 1.0.10 / mediasrv 0.8.43\n非官方逆向接口，不构成跨版本兼容承诺。")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("无 Apple 或飞牛品牌素材，不隶属于 Apple 或飞牛。")
                    .font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .formStyle(.grouped)
        .padding(16).frame(width: 580, height: 500)
        .alert("启用未经充分验证的写接口？", isPresented: $confirmExperimental) {
            Button("取消", role: .cancel) { }
            Button("我了解风险，启用") { experimentalWrites = true }
        } message: { Text("仅建议在可接受风险的音乐库中使用。网络失败不代表修改没有发生；客户端不会自动重试写入。") }
    }

    private func clearCache() {
        guard let library = app.library else { return }
        busy = true
        Task {
            do {
                try await library.images.clear()
                await library.search.clear()
                await library.client.clearCache()
                message = "已清理当前账户缓存"
            } catch { message = error.localizedDescription }
            await updateCacheSize()
            busy = false
        }
    }

    private func updateCacheSize() async {
        do { cacheBytes = try await app.library?.images.diskUsage() ?? 0 }
        catch { message = error.localizedDescription }
    }
}
