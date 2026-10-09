import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Keep this loader alive for as long as its asset is in use. The owner should
/// call cancelAll() when replacing the item or tearing down playback.
@MainActor
final class AudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "fnmusic-stream"
    private static let maximumChunkLength = 512 * 1_024

    private struct ResourceInformation {
        let totalLength: Int64
        let contentType: String
        let supportsRanges: Bool
    }

    private struct PendingRequest {
        let request: AVAssetResourceLoadingRequest
        let task: Task<Void, Never>
    }

    private let client: APIClient
    private let guid: String
    private let audioSpec: AudioSpec?
    private var information: ResourceInformation?
    private(set) var failure: APIError?
    private var pending: [ObjectIdentifier: PendingRequest] = [:]

    init(client: APIClient, guid: String, audioSpec: AudioSpec?) {
        self.client = client
        self.guid = guid
        self.audioSpec = audioSpec
        super.init()
    }

    func makeAsset() throws -> AVURLAsset {
        guard !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.unavailable("歌曲缺少有效的标识。")
        }
        // This is an opaque AVFoundation routing URL, never a server URL. In
        // particular, neither server-local paths nor credentials belong here.
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "track"
        components.path = "/\(UUID().uuidString)"
        guard let url = components.url else { throw APIError.invalidServer }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func cancelAll() {
        let requests = Array(pending.values)
        // Remove first: an in-flight task must not respond or finish afterwards.
        pending.removeAll()
        for entry in requests {
            entry.task.cancel()
            if !entry.request.isCancelled && !entry.request.isFinished {
                entry.request.finishLoading(with: CancellationError())
            }
        }
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // makeAsset() installs this delegate exclusively on the main queue.
        MainActor.assumeIsolated {
            begin(loadingRequest)
        }
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        MainActor.assumeIsolated {
            // AVFoundation owns cancellation completion. Never finish a request
            // from this callback, even if its cancelled flag has not updated yet.
            pending.removeValue(forKey: ObjectIdentifier(loadingRequest))?.task.cancel()
        }
    }

    private func begin(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme?.lowercased() == Self.scheme else { return false }
        guard !request.isCancelled && !request.isFinished else { return false }
        let id = ObjectIdentifier(request)
        guard pending[id] == nil else { return true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.fulfill(request)
                self.finish(request)
            } catch {
                self.finish(request, error: error)
            }
        }
        // The MainActor task cannot run until this synchronous callback returns.
        pending[id] = PendingRequest(request: request, task: task)
        return true
    }

    private func checkActive(_ request: AVAssetResourceLoadingRequest) throws {
        try Task.checkCancellation()
        guard pending[ObjectIdentifier(request)] != nil,
              !request.isCancelled, !request.isFinished else { throw CancellationError() }
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error? = nil) {
        guard pending.removeValue(forKey: ObjectIdentifier(request)) != nil,
              !request.isCancelled, !request.isFinished else { return }
        if let error {
            if let apiError = error as? APIError { failure = apiError }
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }

    private func fulfill(_ request: AVAssetResourceLoadingRequest) async throws {
        try checkActive(request)
        let resource: ResourceInformation
        if let information {
            resource = information
        } else {
            // APIClient only accepts validated 206 Content-Range responses.
            // A tiny probe also handles information-only loading requests without
            // downloading the complete track. Do not trust catalog size metadata.
            let probe = try await client.stream(guid: guid, offset: 0, length: 2)
            try checkActive(request)
            try validate(probe, offset: 0, maximumLength: 2)
            let probed = ResourceInformation(
                totalLength: probe.totalLength,
                contentType: try contentType(for: probe.mimeType),
                supportsRanges: probe.supportsRanges
            )
            // Independent requests may probe concurrently across the await.
            if let information, information.totalLength != probed.totalLength {
                throw APIError.invalidRange
            }
            information = probed
            resource = probed
        }

        try checkActive(request)
        if let content = request.contentInformationRequest {
            content.contentType = resource.contentType
            content.contentLength = resource.totalLength
            content.isByteRangeAccessSupported = resource.supportsRanges
        }
        guard let dataRequest = request.dataRequest else { return }
        guard dataRequest.requestedOffset >= 0, dataRequest.currentOffset >= 0,
              dataRequest.requestedLength >= 0 else { throw APIError.invalidRange }

        var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        let end: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            end = resource.totalLength
        } else {
            let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(
                Int64(dataRequest.requestedLength)
            )
            guard !overflow else { throw APIError.invalidRange }
            end = min(requestedEnd, resource.totalLength)
        }
        guard offset <= end else { throw APIError.invalidRange }

        while offset < end {
            try checkActive(request)
            // currentOffset is authoritative if AVFoundation has already consumed
            // bytes; the local cursor also guarantees progress after every reply.
            offset = max(offset, dataRequest.currentOffset)
            guard offset <= end else { throw APIError.invalidRange }
            if offset == end { break }
            let length = Int(min(Int64(Self.maximumChunkLength), end - offset))
            let chunk = try await client.stream(guid: guid, offset: offset, length: length)
            try checkActive(request)
            try validate(chunk, offset: offset, maximumLength: length)
            guard chunk.totalLength == resource.totalLength else { throw APIError.invalidRange }
            // No suspension between the cancellation check and this response.
            dataRequest.respond(with: chunk.data)
            offset += Int64(chunk.data.count)
        }
    }

    private func validate(_ chunk: MediaChunk, offset: Int64, maximumLength: Int) throws {
        // Defend against overlong, empty, shifted, or inconsistent chunks even
        // though APIClient already validates status and Content-Range syntax.
        guard chunk.supportsRanges, chunk.totalLength > 0,
              chunk.rangeStart == offset, offset >= 0, offset < chunk.totalLength,
              !chunk.data.isEmpty, chunk.data.count <= maximumLength,
              Int64(chunk.data.count) <= chunk.totalLength - offset else {
            throw APIError.invalidRange
        }
    }

    private func contentType(for mimeType: String) throws -> String {
        let mime = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let type = UTType(mimeType: mime), type.conforms(to: .audio), !type.isDynamic {
            return type.identifier
        }
        // Some servers use legacy MIME aliases that UTType does not recognize.
        switch mime {
        case "audio/mp3", "audio/x-mp3", "audio/mpeg", "audio/mpeg3":
            return "public.mp3"
        case "audio/flac", "audio/x-flac":
            return "org.xiph.flac"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "video/mp4":
            return "com.apple.m4a-audio"
        case "audio/wav", "audio/wave", "audio/x-wav", "audio/vnd.wave":
            return "com.microsoft.waveform-audio"
        default:
            break
        }

        // Container hints precede codec hints: AAC/ALAC may live inside M4A,
        // and PCM may live inside WAV. Never infer a URL or type from a path.
        let hints = [audioSpec?.extension, audioSpec?.container, audioSpec?.format, audioSpec?.codec]
        for hint in hints {
            guard let hint else { continue }
            let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if tokens.contains("mp3") { return "public.mp3" }
            if tokens.contains("flac") { return "org.xiph.flac" }
            if tokens.contains(where: { ["m4a", "mp4"].contains($0) }) {
                return "com.apple.m4a-audio"
            }
            if tokens.contains(where: { ["wav", "wave"].contains($0) }) {
                return "com.microsoft.waveform-audio"
            }
        }
        throw APIError.unsupportedAudio
    }
}
