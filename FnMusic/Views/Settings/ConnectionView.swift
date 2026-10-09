import SwiftUI

struct ConnectionView: View {
    @Environment(AppState.self) private var app
    @State private var model = ConnectionViewModel()
    @State private var action: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 68, weight: .light)).foregroundStyle(.pink)
                Text("音乐，\n回到你身边。")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text("你的服务器。你的收藏。\n一个为 Mac 打造的聆听空间。")
                    .font(.title3).foregroundStyle(.secondary).lineSpacing(6)
                Spacer()
                Text("FnMusic").font(.title2.weight(.medium))
                Text("Unofficial Fn Music Client").font(.caption).foregroundStyle(.secondary)
            }
            .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.pink.opacity(0.045))
            VStack(alignment: .leading, spacing: 22) {
                Text("连接服务器").font(.largeTitle.weight(.semibold))
                Text("登录飞牛音乐，开始浏览你的资料库。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    TextField("服务器地址，例如 https://music.example.com", text: $model.server)
                        .textContentType(.URL)
                    TextField("用户名", text: $model.username)
                        .textContentType(.username)
                    SecureField("密码", text: $model.password)
                        .textContentType(.password)
                        .onSubmit { login() }
                }
                .textFieldStyle(.roundedBorder).controlSize(.large)
                if model.server.lowercased().hasPrefix("http://") {
                    Label("HTTP 不加密登录材料与音频传输，建议使用 HTTPS。", systemImage: "lock.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let message = model.message ?? app.sessionMessage {
                    Text(message).font(.callout)
                        .foregroundStyle(model.testSucceeded ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("测试连接") { action = Task { await model.testConnection() } }
                        .disabled(model.isBusy || model.server.isEmpty)
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button("登录", action: login)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.isBusy || model.server.isEmpty || model.username.isEmpty || model.password.isEmpty)
                }
                Text("会话保存在 macOS 钥匙串。密码不会存储。\n此应用非官方客户端，不属于 Apple 或飞牛。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
            .padding(48).frame(maxWidth: 520)
        }
        .onDisappear { action?.cancel() }
    }

    private func login() {
        guard !model.isBusy, !model.username.isEmpty, !model.password.isEmpty else { return }
        action = Task { await model.login(app: app) }
    }
}
