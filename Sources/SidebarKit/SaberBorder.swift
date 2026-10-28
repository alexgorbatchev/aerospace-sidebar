import SwiftUI

extension View {
    /// Overlays a `SaberBorder` whose beam starts where the pointer entered the view.
    func saberBorder(_ shape: some InsettableShape, color: Color, isActive: Bool) -> some View {
        modifier(SaberBorderModifier(shape: shape, color: color, isActive: isActive))
    }
}

/// Tracks where the pointer entered the view and hands it to the border in the view's own coordinates.
/// The entry is kept in screen space, so it stays where the pointer was while the view resizes (an icon
/// button widening into a capsule) or moves.
struct SaberBorderModifier<Border: InsettableShape>: ViewModifier {
    let shape: Border
    let color: Color
    let isActive: Bool

    @State private var entry: CGPoint?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .overlay {
                SaberBorder(shape: shape, color: color, isActive: isActive, entry: entry.map {
                    CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY)
                })
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $1 }
            .onContinuousHover(coordinateSpace: .global) { entry = Self.entry(entry, after: $0) }
    }

    /// The first point the pointer reported since it entered, or nil once it left.
    static func entry(_ current: CGPoint?, after phase: HoverPhase) -> CGPoint? {
        switch phase {
        case let .active(location): current ?? location
        case .ended: nil
        }
    }
}

/// A faint glow along `shape`'s edge while `isActive`, and a beam of light that runs once around it when
/// it becomes active, like a saber blade tracing the border. Cards and the round icon buttons show it
/// under the pointer. The beam fades in as it grows out of the outline's point nearest `entry` (or the
/// outline's start), moves along the outline at a constant speed, so it crosses long and short edges at
/// the same pace, and fades out as its head runs on past that point. It is clipped to the shape, so it
/// never spills onto neighbors or the shadow under them. With Reduce Motion the edge glows without the beam.
struct SaberBorder<Border: InsettableShape>: View {
    let shape: Border
    let color: Color
    let isActive: Bool
    /// Where the pointer entered, in the border's coordinates.
    var entry: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the beam's head has run along the outline, from 0 to `SaberBeam.end`.
    @State private var head: CGFloat = 0

    var body: some View {
        ZStack {
            shape.strokeBorder(color.opacity(reduceMotion ? SaberBeam.stillOutlineOpacity : SaberBeam.outlineOpacity), lineWidth: SaberBeam.lineWidth)
            if !reduceMotion {
                SaberBlade(shape: shape, color: color, entry: entry, head: head)
            }
        }
        .clipShape(shape)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                withAnimation(.linear(duration: SaberBeam.duration)) { head = SaberBeam.end }
            } else {
                // Back to the start without running backwards, ready for the next hover.
                withTransaction(Transaction(animation: nil)) { head = 0 }
            }
        }
    }
}

/// The beam at one point of its lap. Animatable, so its fade follows the head frame by frame.
struct SaberBlade<Border: InsettableShape>: View, @MainActor Animatable {
    let shape: Border
    let color: Color
    let entry: CGPoint?
    var head: CGFloat

    var animatableData: CGFloat {
        get { head }
        set { head = newValue }
    }

    var body: some View {
        let outline = shape.inset(by: SaberBeam.coreWidth / 2)
        ZStack {
            // Each layer is a longer, faint stretch ending at the head; together they brighten toward it.
            ForEach(1...SaberBeam.tailLayers, id: \.self) { layer in
                let trail = SaberTrail(outline: outline, entry: entry, head: head, length: SaberBeam.length * CGFloat(layer) / CGFloat(SaberBeam.tailLayers))
                trail.stroke(color.opacity(SaberBeam.layerOpacity * SaberBeam.glowOpacity), lineWidth: SaberBeam.glowWidth)
                    .blur(radius: SaberBeam.glowWidth / 2)
                trail.stroke(SaberBeam.core(color).opacity(SaberBeam.layerOpacity), style: StrokeStyle(lineWidth: SaberBeam.coreWidth, lineCap: .round))
            }
        }
        .opacity(SaberBeam.fade(at: head))
    }
}

/// The stretch of `outline` that ends at `head`, both measured as fractions of the outline's length from
/// the point nearest `entry` (or from the outline's start). The part before that point is cut off, so the
/// beam grows out of it; past one lap the head runs on into the next.
struct SaberTrail<Outline: Shape>: Shape {
    let outline: Outline
    var entry: CGPoint?
    var head: CGFloat
    let length: CGFloat

    var animatableData: CGFloat {
        get { head }
        set { head = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lapFrom = max(head - length, 0)
        let lapTo = max(head, 0)
        guard lapTo > lapFrom else { return Path() }
        let full = outline.path(in: rect)
        let start = entry.map { Self.fraction(nearest: $0, along: full) } ?? 0
        // The same stretch within the first time round the outline; it is shorter than one lap.
        let laps = (start + lapFrom).rounded(.down)
        let (from, to) = (start + lapFrom - laps, start + lapTo - laps)
        // `trimmedPath` measures by arc length, which keeps the beam's speed the same on every edge.
        // A stretch crossing the outline's start is drawn as its two pieces.
        if to <= 1 { return full.trimmedPath(from: from, to: to) }
        var path = full.trimmedPath(from: from, to: 1)
        path.addPath(full.trimmedPath(from: 0, to: to - 1))
        return path
    }

    /// How far along `path`, as a fraction of its length, its point nearest `point` lies.
    static func fraction(nearest point: CGPoint, along path: Path) -> CGFloat {
        var travelled: CGFloat = 0
        var best = (distance: CGFloat.infinity, at: CGFloat(0))
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        func segment(to end: CGPoint) {
            let (dx, dy) = (end.x - current.x, end.y - current.y)
            let length = hypot(dx, dy)
            if length > 0 {
                let t = min(max(((point.x - current.x) * dx + (point.y - current.y) * dy) / (length * length), 0), 1)
                let distance = hypot(current.x + t * dx - point.x, current.y + t * dy - point.y)
                if distance < best.distance { best = (distance, travelled + t * length) }
                travelled += length
            }
            current = end
        }
        // Flattened, the outline holds only straight segments.
        Path(path.cgPath.flattened(threshold: 0.25)).forEach { element in
            switch element {
            case let .move(to):
                current = to
                subpathStart = to
            case let .line(to), let .quadCurve(to, _), let .curve(to, _, _): segment(to: to)
            case .closeSubpath: segment(to: subpathStart)
            }
        }
        return travelled > 0 ? best.at / travelled : 0
    }
}

/// The look and timing shared by every `SaberBorder`.
enum SaberBeam {
    /// Seconds from the head entering until the tail has left, one lap.
    static let duration: TimeInterval = 0.35
    /// The beam's length as a fraction of the outline.
    static let length: CGFloat = 0.25
    /// Where the head stops: one lap plus the beam's length, by which time the beam has faded out.
    static let end: CGFloat = 1 + length
    static let tailLayers = 4
    /// How opaque the beam is at its head, where every layer overlaps.
    static let peakOpacity: Double = 0.15
    /// Each layer's opacity, so that `tailLayers` of them stacked reach `peakOpacity`: 1 - (1 - a)^n = peak.
    static let layerOpacity: Double = 1 - pow(1 - peakOpacity, 1 / Double(tailLayers))
    /// The outline's width.
    static let lineWidth: CGFloat = 1
    static let coreWidth: CGFloat = 1.5
    static let glowWidth: CGFloat = 6
    static let glowOpacity: Double = 1

    /// Like a saber blade, the beam has a pale core inside a glow of its color. A core in the color itself
    /// would vanish into the matching stroke of a high or critical card.
    static func core(_ color: Color) -> Color {
        color.mix(with: .white, by: 0.75)
    }
    /// How visible the beam is with its head at `head`: it fades in while it grows out of its starting point
    /// to its full length, and fades out while the head runs on past that point, so it never looks cut off.
    static func fade(at head: CGFloat) -> Double {
        let ramp = min(head / length, (end - head) / length, 1)
        let t = Double(max(ramp, 0))
        // Smoothstep: the fade starts and settles gently.
        return t * t * (3 - 2 * t)
    }

    /// The whole edge glows faintly while active, and more where no beam runs.
    static let outlineOpacity: Double = 0.2
    static let stillOutlineOpacity: Double = 0.5
}
