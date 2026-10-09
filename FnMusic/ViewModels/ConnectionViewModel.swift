import Foundation
import Observation

@MainActor @Observable
final class ConnectionViewModel {
    var server = UserDefaults.standard.string(forKey: "serverAddress") ?? ""
    var username = ""
    var password = ""
    var isBusy = false
    var message: String?
    var testSucceeded = false

    func testConnection() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        testSucceeded = false
        defer { isBusy = false }
        do {
            let client = APIClient(origin: try APIClient.serverURL(server))
            let config: SystemConfiguration = try await client.value(APIRequest(path: "/sys/config", authenticated: false))
            let state: InitializationState = try await client.value(APIRequest(path: "/initialization/state", authenticated: false))
            guard state.initialized else { throw APIError.unavailable("服务器尚未初始化，请先在官方客户端完成初始化。") }
            testSucceeded = true
            message = "连接成功 · \(config.serverName ?? "飞牛音乐") · \(config.serverVersion ?? "未知版本")"
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }

    func login(app: AppState) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false; password = "" }
        do { try await app.login(server: server, username: username, password: password) }
        catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
