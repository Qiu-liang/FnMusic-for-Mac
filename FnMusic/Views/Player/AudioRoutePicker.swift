import SwiftUI
import AVKit

struct AudioRoutePicker: NSViewRepresentable {
    let player: AudioPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.player = player.routePickerPlayer
        picker.setRoutePickerButtonColor(.labelColor, for: .normal)
        picker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.systemPink, for: .active)
        picker.setRoutePickerButtonColor(.systemPink, for: .activeHighlighted)
        picker.toolTip = "AirPlay 与音频输出"
        picker.setAccessibilityLabel("AirPlay 与音频输出")
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.player = player.routePickerPlayer
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        // AVKit's default 41pt intrinsic width would overlap adjacent controls.
        CGSize(width: proposal.width ?? 28, height: proposal.height ?? 28)
    }

    static func dismantleNSView(_ picker: AVRoutePickerView, coordinator: ()) {
        picker.player = nil
    }
}
