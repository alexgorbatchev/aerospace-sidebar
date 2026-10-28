import AppKit
import SwiftUI

/// Where a SwiftUI view is on screen, for something that starts from it outside its window, such as
/// PermissionFlow's drag panel flying from the clicked button to System Settings. SwiftUI reports frames
/// only within the window, so the anchor keeps an AppKit view behind the SwiftUI one and asks its window.
@MainActor
final class ScreenFrameAnchor {
    weak var view: NSView?

    /// The view's frame in screen coordinates, or nil while it is not in a window.
    var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// The AppKit view behind a SwiftUI view that `ScreenFrameAnchor` measures.
struct ScreenFrameReader: NSViewRepresentable {
    let anchor: ScreenFrameAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

extension View {
    /// Lets `anchor` find this view on screen.
    func screenFrameAnchor(_ anchor: ScreenFrameAnchor) -> some View {
        background(ScreenFrameReader(anchor: anchor))
    }
}
