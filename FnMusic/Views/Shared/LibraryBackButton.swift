import SwiftUI

@MainActor
enum LibraryNavigationActions {
    static func goBack(in library: LibraryContext) {
        library.goBack()
    }
}

/// Reusable navigation control that returns to the previous library level.
struct LibraryBackButton: View {
    @Environment(LibraryContext.self) private var library

    var body: some View {
        Button { LibraryNavigationActions.goBack(in: library) } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: PageToolbarMetrics.controlHeight, height: PageToolbarMetrics.controlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(FloatingTopControlGlass(shape: Circle()))
        .help("返回上一级")
        .accessibilityLabel("返回上一级")
        .accessibilityIdentifier("FnMusic.PageBack")
        .disabled(library.navigation.isEmpty)
    }
}
