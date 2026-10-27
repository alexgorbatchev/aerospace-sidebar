import SwiftUI

/// The order of a press animation: the press-in always finishes before the release starts, however
/// quickly the mouse goes down and up. The action runs as the release starts, so whatever it sets off,
/// such as the card fading out, plays alongside the release.
struct PressSequence: Equatable {
    enum Phase: Equatable {
        case idle
        /// Animating in; a release that arrives now waits for it.
        case pressing
        /// Pressed in, waiting for the mouse to go up.
        case held
        /// Animating back out.
        case releasing
    }

    /// What the view does next.
    enum Step: Equatable {
        case none
        case pressIn
        /// Animate back out, running the action at the same time when `triggers`.
        case release(triggers: Bool)
    }

    private(set) var phase = Phase.idle
    /// A release that arrived while pressing in: whether it ended inside the button.
    private var pendingRelease: Bool?

    /// The mouse went down on the button.
    mutating func press() -> Step {
        guard phase == .idle else { return .none }
        phase = .pressing
        return .pressIn
    }

    /// The mouse went up, `inside` the button or not. A release without a press, as for a click too
    /// quick to report the press, plays the whole press first.
    mutating func release(inside: Bool) -> Step {
        switch phase {
        case .idle:
            phase = .pressing
            pendingRelease = inside
            return .pressIn
        case .pressing:
            pendingRelease = inside
            return .none
        case .held:
            phase = .releasing
            return .release(triggers: inside)
        case .releasing:
            return .none
        }
    }

    /// The press-in animation finished.
    mutating func pressFinished() -> Step {
        guard phase == .pressing else { return .none }
        guard let inside = pendingRelease else {
            phase = .held
            return .none
        }
        pendingRelease = nil
        phase = .releasing
        return .release(triggers: inside)
    }

    /// The release animation finished.
    mutating func releaseFinished() {
        if phase == .releasing { phase = .idle }
    }
}

/// Scales the button down while pressed and back up on release, running its action as the release
/// starts. The press always plays in full first; with Reduce Motion the button does not scale.
struct PressableButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableButton(configuration: configuration)
    }
}

struct PressableButton: View {
    let configuration: PrimitiveButtonStyleConfiguration

    static let pressedScale: CGFloat = 0.97
    static let pressIn = Animation.easeOut(duration: 0.1)
    static let release = Animation.easeOut(duration: 0.15)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sequence = PressSequence()
    @State private var isPressedIn = false
    @State private var size = CGSize.zero

    var body: some View {
        configuration.label
            .scaleEffect(isPressedIn && !reduceMotion ? Self.pressedScale : 1)
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in perform(sequence.press()) }
                    .onEnded { perform(sequence.release(inside: CGRect(origin: .zero, size: size).contains($0.location))) }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { configuration.trigger() }
    }

    private func perform(_ step: PressSequence.Step) {
        switch step {
        case .none:
            break
        case .pressIn:
            withAnimation(reduceMotion ? nil : Self.pressIn, completionCriteria: .logicallyComplete) {
                isPressedIn = true
            } completion: {
                perform(sequence.pressFinished())
            }
        case .release(let triggers):
            withAnimation(reduceMotion ? nil : Self.release, completionCriteria: .logicallyComplete) {
                isPressedIn = false
            } completion: {
                sequence.releaseFinished()
            }
            if triggers { configuration.trigger() }
        }
    }
}
