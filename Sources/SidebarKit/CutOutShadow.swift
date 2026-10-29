import SwiftUI

extension View {
    /// Draws `shadows` behind this view with `shape`'s area cut out, so shadows fall only around it.
    ///
    /// A shadow on the view itself (`compositingGroup().shadow`) is darkest right at the edge and shows
    /// through the edge pixels the view only partly covers, which turns them darker than both the inside and
    /// the outside: a stepped dark ring around curves. It also darkens translucent views (materials, glass)
    /// and renders a glass push button into a layer of its own, where it turns black. `reach` is how far the
    /// shadows extend past the shape.
    func cutOutShadows(_ shape: some Shape, reach: CGFloat, @ViewBuilder _ shadows: () -> some View) -> some View {
        background {
            shadows().mask {
                Rectangle()
                    .padding(-reach)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
        }
    }
}

/// A black copy of `shape` casting a shadow, for `cutOutShadows`. The copy is one pixel smaller than the
/// shape, so the cut-out removes all of it: an exact copy would leave a sliver in the partly covered edge
/// pixels, which darkens them.
struct ShadowCaster<S: Shape>: View {
    let shape: S
    let opacity: Double
    let radius: CGFloat
    var y: CGFloat = 0

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        shape
            .fill(.black)
            .padding(1 / displayScale)
            .shadow(color: .black.opacity(opacity), radius: radius, y: y)
    }
}
