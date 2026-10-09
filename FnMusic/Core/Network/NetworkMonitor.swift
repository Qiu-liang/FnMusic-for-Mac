import Foundation
import Network
import Observation

@MainActor @Observable
final class NetworkMonitor {
    var hasNetworkPath = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.hasNetworkPath = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "dev.fnmusic.network-monitor"))
    }

    deinit { monitor.cancel() }
}
