import SwiftUI

/// A notification's choices on its card, a native notification's or those pushed with it: one button each,
/// wrapping onto more lines when they do not fit beside each other, and for a choice that asks for text, such as
/// Reply, a field with its send button under them. macOS shows more than two choices under an Options menu; a card
/// has room to show them all, and a menu would not draw in the configured font.
struct CardChoices: View {
    let choices: [NativeChoice]
    @Bindable var draft: ReplyDraft
    let choose: (String) -> Void
    /// Sends the text typed for a choice that asks for it.
    let reply: (_ choice: String, _ text: String) -> Void
    /// Whether the typed text can be sent; empty text never is.
    var acceptsReply: (String) -> Bool = { !$0.isEmpty }

    @FocusState private var fieldFocused: Bool
    @Environment(\.typography) private var typography
    @Environment(\.requestKeyboard) private var requestKeyboard

    static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            WrappingLayout(spacing: Self.spacing) {
                ForEach(choices, id: \.title) { choice in
                    ChoiceButton(title: choice.title, isDestructive: choice.isDestructive) { select(choice) }
                }
            }
            if let replying = draft.choice, let input = replying.textInput {
                HStack(spacing: Self.spacing) {
                    TextField(replying.title, text: $draft.text, prompt: input.placeholder.isEmpty ? nil : Text(input.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .font(typography.font(.callout))
                        .focused($fieldFocused)
                        .onSubmit(send)
                        .onExitCommand(perform: cancel)
                        // Focused once, when the user opens it: a field shown again (the list scrolled it back
                        // into view) leaves the keyboard where it is. Focus set as the field appears does not
                        // take (measured on macOS 26.6, in the sidebar's panel and in a bare one); a turn of the
                        // main actor later, once SwiftUI has installed the field, it does.
                        .task {
                            await Task.yield()
                            guard draft.focusRequested, !Task.isCancelled else { return }
                            draft.focusRequested = false
                            fieldFocused = true
                        }
                    ChoiceButton(title: input.sendTitle.isEmpty ? replying.title : input.sendTitle, action: send)
                        .disabled(!acceptsReply(draft.text))
                }
            }
        }
    }

    /// A choice that asks for text opens its field, or closes it when it is open; any other runs at once.
    func select(_ choice: NativeChoice) {
        guard choice.textInput != nil else { return choose(choice.title) }
        if draft.choice == choice {
            cancel()
        } else {
            draft.open(choice)
            requestKeyboard()
            fieldFocused = true
        }
    }

    func send() {
        guard let choice = draft.choice, acceptsReply(draft.text) else { return }
        reply(choice.title, draft.text)
    }

    func cancel() {
        draft.choice = nil
        draft.text = ""
    }
}

/// Lays its subviews out in a row at their ideal sizes, starting a new row where the next one would not fit.
struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    /// Places the rows `sizeThatFits` measured: at the proposed width, which the bounds may exceed.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = proposal.width ?? bounds.width
        var y = bounds.minY
        for row in rows(for: subviews, width: width) {
            var x = bounds.minX
            for index in row.indices {
                let size = fitted(subviews[index], width: width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// A subview's ideal size, or the size it takes at `width` when its ideal one is wider, such as a long
    /// title in a narrow sidebar, which then truncates instead of spilling past the card.
    private func fitted(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Fills each row with as many subviews as fit `width`; a subview wider than that gets a row of its own.
    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = fitted(subviews[index], width: width)
            let widened = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, widened > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// What is typed on a card for a choice that asks for text, kept while the card shows.
@MainActor
@Observable
final class ReplyDraft {
    /// The choice whose field is open.
    var choice: NativeChoice?
    var text = ""
    /// The user opened the field, which then takes the keyboard focus once.
    var focusRequested = false

    /// Opens the field of a choice that asks for text.
    func open(_ choice: NativeChoice) {
        self.choice = choice
        focusRequested = true
    }
}
