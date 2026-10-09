import Foundation
import Observation

@MainActor @Observable
final class SharedLibrariesViewModel {
    private(set) var items: [SharedLibrary] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private let service: any BrowseServiceProtocol
    private var generation = UUID()

    init(service: any BrowseServiceProtocol) { self.service = service }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let identity = UUID()
        generation = identity
        isLoading = true
        error = nil
        defer { if generation == identity { isLoading = false } }
        do {
            let result = try await service.libraries()
            try Task.checkCancellation()
            guard generation == identity else { return }
            items = result
        } catch is CancellationError { }
        catch {
            if generation == identity && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// Also rejects a late response from a transport that does not honor cancellation.
    func invalidate() {
        generation = UUID()
        isLoading = false
    }
}

@MainActor @Observable
final class SharedLibraryDetailViewModel {
    private(set) var library: SharedLibrary?
    private(set) var isLoading = false
    private(set) var error: String?
    let guid: String
    private let service: any BrowseServiceProtocol
    private var generation = UUID()

    init(guid: String, service: any BrowseServiceProtocol) {
        self.guid = guid
        self.service = service
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let identity = UUID()
        generation = identity
        isLoading = true
        error = nil
        defer { if generation == identity { isLoading = false } }
        do {
            let result = try await service.library(guid: guid)
            try Task.checkCancellation()
            guard generation == identity else { return }
            library = result
        } catch is CancellationError { }
        catch {
            if generation == identity && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func invalidate() {
        generation = UUID()
        isLoading = false
    }
}
