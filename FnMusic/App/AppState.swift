import Foundation
import Observation

@MainActor @Observable
final class AppState {
    var client: APIClient?
    var library: LibraryContext?
    var user: User?
    var configuration: SystemConfiguration?
    var systemInfo: SystemInfo?
    let network = NetworkMonitor()
    var isRestoring = true
    var sessionMessage: String?
    var selection: SidebarDestination? = .home
    private let keychain: KeychainStore
    private var restored = false
    private var generation = UUID()

    init(keychain: KeychainStore = KeychainStore()) { self.keychain = keychain }

    var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "deviceId") { return existing }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(value, forKey: "deviceId")
        return value
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        let identity = generation
        defer { if identity == generation { isRestoring = false } }
        do {
            guard let saved = try keychain.load() else { return }
            let candidate = APIClient(origin: saved.origin, token: saved.token)
            do {
                let current: User = try await candidate.value(APIRequest(path: "/user/me"))
                try await prepareAndCommit(candidate, user: current, saved: nil, identity: identity)
            } catch {
                await candidate.close()
                throw error
            }
        } catch is CancellationError { }
        catch {
            guard identity == generation else { return }
            if error as? APIError == .sessionExpired { try? keychain.clear() }
            sessionMessage = error.localizedDescription
        }
    }

    func login(server: String, username: String, password: String) async throws {
        struct Credentials: Encodable { let username: String; let password: String; let deviceId: String }
        let identity = UUID()
        generation = identity
        let origin = try APIClient.serverURL(server)
        let candidate = APIClient(origin: origin)
        do {
            let response: LoginResponse = try await candidate.value(.post(
                "/user/password-login", body: Credentials(username: username, password: KeychainStore.passwordHash(password), deviceId: deviceId),
                authenticated: false))
            guard !response.userToken.isEmpty,
                  !response.userToken.contains(where: { $0 == ";" || $0 == "\r" || $0 == "\n" }) else { throw APIError.decoding }
            await candidate.setToken(response.userToken)
            try await prepareAndCommit(candidate, user: response.user,
                                       saved: SavedSession(origin: origin, token: response.userToken, user: response.user), identity: identity)
        } catch {
            await candidate.close()
            throw error
        }
    }

    private func prepareAndCommit(_ candidate: APIClient, user: User, saved: SavedSession?, identity: UUID) async throws {
        let config: SystemConfiguration? = try? await candidate.value(APIRequest(path: "/sys/config", authenticated: false))
        let info: SystemInfo? = try? await candidate.value(APIRequest(path: "/sys/info"))
        await candidate.onSessionInvalidated { [weak self, weak candidate] in
            guard let candidate else { return }
            await self?.expire(candidate)
        }
        guard await candidate.hasSession() else { throw APIError.sessionExpired }
        try Task.checkCancellation()
        guard generation == identity else { throw CancellationError() }
        // This commit has no suspension: older auth/logout tasks cannot clear or
        // overwrite a newly saved token between persistence and state publication.
        if let saved { try keychain.save(saved) }
        let previous = client
        library?.downloads.cancel()
        library?.artistBrowser.invalidate()
        library?.player.shutdown()
        client = candidate
        library = LibraryContext(client: candidate, user: user)
        self.user = user
        // UI-only acceptance option; no injected data or authentication bypass.
        selection = CommandLine.arguments.contains("--show-artists") ? .artists : .home
        configuration = config
        systemInfo = info
        sessionMessage = nil
        isRestoring = false
        UserDefaults.standard.set(candidate.origin.absoluteString, forKey: "serverAddress")
        if let previous { Task { await previous.close() } }
    }

    private func detach(message: String?) -> (ImageCache?, String?) {
        generation = UUID()
        library?.downloads.cancel()
        library?.artistBrowser.invalidate()
        library?.player.shutdown()
        let images = library?.images
        library = nil
        client = nil
        user = nil
        configuration = nil
        systemInfo = nil
        isRestoring = false
        var message = message
        do { try keychain.clear() }
        catch { message = (message.map { $0 + "\n" } ?? "") + error.localizedDescription }
        sessionMessage = message
        return (images, message)
    }

    private func expire(_ candidate: APIClient) async {
        guard client === candidate else { return }
        let (images, _) = detach(message: APIError.sessionExpired.localizedDescription)
        // All shared state was cleared before the first await.
        try? await images?.clear()
        await candidate.close()
    }

    func logout() async {
        guard let previous = client else { return }
        let (images, initialMessage) = detach(message: nil)
        let identity = generation
        let remote = await previous.logoutTransport()
        try? await images?.clear()
        var message = initialMessage
        if let remote {
            do { try await remote.perform(.post("/user/logout", body: EmptyBody())) }
            catch { message = "已在本机退出，但服务器会话注销未确认：\(error.localizedDescription)" }
            await remote.close()
        }
        if identity == generation { sessionMessage = message }
    }
}
