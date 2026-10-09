import Foundation
import Observation

/// A reference shared by a page and an optional enclosing page's toolbar.
@MainActor @Observable
final class CatalogControls {
    var query = ""
    var sort: String
    var refreshRevision = 0

    init(sort: String) { self.sort = sort }

    func refresh() { refreshRevision += 1 }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Structured identity avoids collisions between query text, sort and revisions.
struct CatalogRequestIdentity: Equatable {
    let sort: String
    let query: String
    let refreshRevision: Int
    var actionsRevision: Int = 0
}
