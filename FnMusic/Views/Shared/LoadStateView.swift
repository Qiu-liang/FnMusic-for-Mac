import SwiftUI

struct LoadStateView: View {
    let isLoading: Bool
    let isEmpty: Bool
    let error: String?
    var emptyTitle = "这里还没有音乐"
    let retry: () async -> Void
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let error {
                ContentUnavailableView {
                    Label("无法加载", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("重试") {
                        retryTask?.cancel()
                        retryTask = Task {
                            guard !Task.isCancelled else { return }
                            await retry()
                        }
                    }
                }
            } else if isLoading && isEmpty {
                ProgressView("正在加载资料库…").frame(maxWidth: .infinity).padding(70)
            } else if isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "music.note", description: Text("内容将从你的飞牛音乐服务器加载。"))
            }
        }
        .onDisappear {
            retryTask?.cancel()
            retryTask = nil
        }
    }
}

struct PageFooter<Item: Codable & Identifiable & Sendable>: View where Item.ID: Sendable {
    let model: PagedViewModel<Item>
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            if let error = model.error, !model.items.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if model.isLoading && !model.items.isEmpty { ProgressView().controlSize(.small) }
            if model.hasMore && !model.items.isEmpty {
                Button(model.error == nil ? "加载更多" : "重试加载") {
                    loadTask?.cancel()
                    loadTask = Task {
                        guard !Task.isCancelled else { return }
                        await model.loadMore()
                    }
                }
                .disabled(model.isLoading)
            }
            if let total = model.total, !model.items.isEmpty {
                Text("已加载 \(model.items.count) / \(total)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity).padding(20)
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }
}

struct ArtworkCard: View {
    let coverId: String?
    let title: String
    let subtitle: String
    let cache: ImageCache
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(coverId: coverId, cache: cache)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Image(systemName: "arrow.up.right")
                            .padding(10).background(.regularMaterial, in: Circle()).padding(10)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 9 : 2, y: 3)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                .foregroundStyle(.primary)
            Text(subtitle).font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.easeInOut(duration: 0.15)) { hovering = value } }
        .accessibilityElement(children: .combine)
    }
}
