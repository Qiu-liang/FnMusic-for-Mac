import AppKit
import Observation

/// Own this in the shared LibraryContext, not a transient row/view. The parent
/// session/logout coordinator must call cancel(); view disappearance must NOT.
@MainActor @Observable
final class DownloadViewModel {
    private(set) var activeTrackGUID: String?
    private(set) var progress: Double = 0
    private(set) var isPreparing = false
    private(set) var isDownloading = false
    private(set) var message: String?
    private(set) var error: String?

    @ObservationIgnored private let service: any TrackDownloadServiceProtocol
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: NSSavePanel?

    init(service: any TrackDownloadServiceProtocol) { self.service = service }

    /// Synchronous button action. Never auto-start from selection, playback or a view task.
    func download(_ track: Track) {
        guard task == nil else {
            error = "已有下载正在准备或进行，请等待完成或明确取消。"
            return
        }
        clearMessages()
        activeTrackGUID = track.guid
        progress = 0
        isPreparing = true
        task = Task { [weak self] in await self?.performDownload(track) }
    }

    func cancel() {
        task?.cancel()
        panel?.cancel(nil) // Ends the asynchronous panel and resumes its continuation.
    }

    func clearMessages() { message = nil; error = nil }

    private func performDownload(_ track: Track) async {
        var authorization: UUID?
        var scopedURL: URL?
        do {
            let filename = try await service.suggestedFilename(for: track)
            try Task.checkCancellation()
            guard let destination = try await chooseDestination(filename: filename) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            if destination.startAccessingSecurityScopedResource() { scopedURL = destination }
            // NSSavePanel .OK includes its native existing-file replacement confirmation.
            // No path supplied by a server, drag/drop, defaults or AudioSpec is authorized here.
            authorization = try await DownloadSaveAuthorization.recordPanelSelection(destination)
            try Task.checkCancellation()
            isPreparing = false
            isDownloading = true
            try await service.download(track, to: destination) { [weak self] value in
                await self?.updateProgress(value)
            }
            // Commit is the success boundary: cancellation after commit cannot undo a save.
            progress = 1
            error = nil
            message = "已保存：\(destination.lastPathComponent)"
        } catch is CancellationError {
            error = nil
            message = "已取消下载。"
        } catch {
            self.error = error.localizedDescription
            message = nil
        }
        if let authorization { await DownloadSaveAuthorization.revoke(authorization) }
        scopedURL?.stopAccessingSecurityScopedResource()
        panel = nil
        isPreparing = false
        isDownloading = false
        activeTrackGUID = nil
        task = nil
    }

    private func updateProgress(_ value: Double) {
        guard value.isFinite else { return }
        progress = max(progress, min(1, max(0, value)))
    }

    private func chooseDestination(filename: String) async throws -> URL? {
        try Task.checkCancellation()
        let savePanel = NSSavePanel()
        savePanel.title = "下载曲目原文件"
        savePanel.prompt = "保存"
        savePanel.message = "保存服务器提供的原文件，不转码；文件格式不代表本机一定可以播放。"
        savePanel.nameFieldStringValue = filename
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        panel = savePanel
        let panelIdentity = ObjectIdentifier(savePanel)
        let response = await withTaskCancellationHandler {
            // AppKit's async sheet API; no runModal or nested main-thread event loop.
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                return await savePanel.beginSheetModal(for: window)
            }
            return await withCheckedContinuation { continuation in
                savePanel.begin { result in continuation.resume(returning: result) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                // A delayed cancellation handler must not close a later download's panel.
                if let panel = self?.panel, ObjectIdentifier(panel) == panelIdentity { panel.cancel(nil) }
            }
        }
        panel = nil
        try Task.checkCancellation()
        return response == .OK ? savePanel.url : nil
    }
}
