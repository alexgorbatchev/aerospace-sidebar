import AppKit
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

    /// Where and how the mouse went up.
    enum Release: Equatable {
        /// Outside the button, which cancels the click.
        case outside
        /// Inside the button: run its action.
        case primary
        /// Inside the button with Option held: run its alternate action.
        case alternate
    }

    /// What the view does next.
    enum Step: Equatable {
        case none
        case pressIn
        /// Animate back out, running the action that `release` asks for at the same time.
        case release(Release)
    }

    private(set) var phase = Phase.idle
    /// A release that arrived while pressing in.
    private var pendingRelease: Release?

    /// The mouse went down on the button.
    mutating func press() -> Step {
        guard phase == .idle else { return .none }
        phase = .pressing
        return .pressIn
    }

    /// The mouse went up. A release without a press, as for a click too quick to report the press, plays
    /// the whole press first.
    mutating func release(_ release: Release) -> Step {
        switch phase {
        case .idle:
            phase = .pressing
            pendingRelease = release
            return .pressIn
        case .pressing:
            pendingRelease = release
            return .none
        case .held:
            phase = .releasing
            return .release(release)
        case .releasing:
            return .none
        }
    }

    /// The press-in animation finished.
    mutating func pressFinished() -> Step {
        guard phase == .pressing else { return .none }
        guard let release = pendingRelease else {
            phase = .held
            return .none
        }
        pendingRelease = nil
        phase = .releasing
        return .release(release)
    }

    /// The release animation finished.
    mutating func releaseFinished() {
        if phase == .releasing { phase = .idle }
    }
}

/// Scales the button down while pressed and back up on release, running its action as the release
/// starts. The press always plays in full first; with Reduce Motion the button does not scale. An
/// Option-click runs `alternateAction` instead, when there is one.
struct PressableButtonStyle: PrimitiveButtonStyle {
    var alternateAction: (() -> Void)?
    /// The modifier keys held down right now; tests pass their own.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    func makeBody(configuration: Configuration) -> some View {
        PressableButton(configuration: configuration, alternateAction: alternateAction, modifierFlags: modifierFlags)
    }
}

struct PressableButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let alternateAction: (() -> Void)?
    let modifierFlags: () -> NSEvent.ModifierFlags

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
                    .onEnded { perform(sequence.release(release(at: $0.location))) }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { configuration.trigger() }
    }

    /// Where the mouse went up, and whether Option is held as it does.
    private func release(at location: CGPoint) -> PressSequence.Release {
        guard CGRect(origin: .zero, size: size).contains(location) else { return .outside }
        return modifierFlags().contains(.option) ? .alternate : .primary
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
        case .release(let release):
            withAnimation(reduceMotion ? nil : Self.release, completionCriteria: .logicallyComplete) {
                isPressedIn = false
            } completion: {
                sequence.releaseFinished()
            }
            switch release {
            case .outside: break
            case .primary: configuration.trigger()
            case .alternate: (alternateAction ?? configuration.trigger)()
            }
        }
    }
}
