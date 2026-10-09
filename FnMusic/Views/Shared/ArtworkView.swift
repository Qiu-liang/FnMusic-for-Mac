import SwiftUI
import CoreGraphics

/// A flexible square; the caller owns its frame. Images are never loaded via
/// SwiftUI.AsyncImage: all bytes go through the shared authenticated APIClient.
@MainActor
struct ArtworkView: View {
    let coverId: String?
    let cache: ImageCache?
    let size: Int

    @State private var image: CGImage?
    @State private var failed = false
    @State private var retry = 0
    @State private var displayedRequest: RequestID?

    private struct RequestID: Hashable {
        let coverId: String?
        let cache: ObjectIdentifier?
        let size: Int
        let retry: Int
    }

    init(coverId: String?, cache: ImageCache?, size: Int = 600) {
        self.coverId = coverId
        self.cache = cache
        self.size = size
    }

    private var requestID: RequestID {
        RequestID(coverId: coverId, cache: cache.map { ObjectIdentifier($0) },
                  size: size <= 160 ? 160 : 600, retry: retry)
    }

    var body: some View {
        let request = requestID
        let isCurrent = displayedRequest == request
        Color.secondary.opacity(0.12)
            .overlay {
                if isCurrent, let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("暂无封面")
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if isCurrent, failed {
                    Button {
                        retry &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("封面加载失败，点击重试")
                    .accessibilityLabel("重试加载封面")
                }
            }
            .task(id: request) { await load(request) }
    }

    private func load(_ request: RequestID) async {
        guard !Task.isCancelled else { return }
        displayedRequest = request
        image = nil
        failed = false
        guard let cache, let coverId,
              !coverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // A failed preview must not prevent the full-size variant from loading.
        // Keep a successful preview visible if the 600px upgrade fails.
        if request.size == 600 {
            do {
                let preview = try await cache.image(id: coverId, size: 160)
                try Task.checkCancellation()
                guard displayedRequest == request else { return }
                image = preview
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, displayedRequest == request else { return }
            }
        }
        do {
            let fullSize = try await cache.image(id: coverId, size: request.size)
            try Task.checkCancellation()
            guard displayedRequest == request else { return }
            image = fullSize
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, displayedRequest == request else { return }
            failed = true
        }
    }
}
