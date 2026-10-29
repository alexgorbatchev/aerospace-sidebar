import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct CardChoicesTests {
    static let reply = NativeChoice(title: "Reply", textInput: NativeChoice.TextInput(placeholder: "Message", sendTitle: "Send"))

    final class Recorder {
        var chosen: [String] = []
        var replies: [String] = []
    }

    func choices(_ choices: [NativeChoice], draft: ReplyDraft, recorder: Recorder) -> CardChoices {
        CardChoices(choices: choices, draft: draft, choose: { recorder.chosen.append($0) }, reply: { recorder.replies.append("\($0): \($1)") })
    }

    @Test func runsAChoiceAtOnce() throws {
        let recorder = Recorder()
        let sut = choices([NativeChoice(title: "Approve"), NativeChoice(title: "Reject", isDestructive: true)], draft: ReplyDraft(), recorder: recorder)

        try sut.inspect().find(button: "Reject").tap()

        #expect(recorder.chosen == ["Reject"])
        #expect(try sut.inspect().find(button: "Reject").role() == .destructive)
        #expect(try sut.inspect().find(button: "Approve").role() == nil)
    }

    /// A choice that asks for text opens a field with the app's send button, which sends what was typed.
    @Test func repliesThroughAField() throws {
        let recorder = Recorder()
        let draft = ReplyDraft()
        let sut = choices([NativeChoice(title: "Later"), Self.reply], draft: draft, recorder: recorder)
        #expect(throws: (any Error).self) { try sut.inspect().find(ViewType.TextField.self) }

        try sut.inspect().find(button: "Reply").tap()
        #expect(draft.choice == Self.reply)
        #expect(recorder.chosen.isEmpty)
        try sut.inspect().find(ViewType.TextField.self).setInput("On my way")
        #expect(draft.text == "On my way")
        try sut.inspect().find(button: "Send").tap()

        #expect(recorder.replies == ["Reply: On my way"])
    }

    /// Nothing is sent empty; pressing the choice again closes its field and drops the text.
    @Test func closesTheFieldWithoutSending() throws {
        let recorder = Recorder()
        let draft = ReplyDraft()
        let sut = choices([Self.reply], draft: draft, recorder: recorder)
        try sut.inspect().find(button: "Reply").tap()
        #expect(try sut.inspect().find(button: "Send").isDisabled())

        draft.text = "draft"
        try sut.inspect().find(button: "Reply").tap()

        #expect(draft.choice == nil)
        #expect(draft.text.isEmpty)
        #expect(recorder.replies.isEmpty)
        #expect(throws: (any Error).self) { try sut.inspect().find(ViewType.TextField.self) }
    }

    /// An app that names no send button gets the choice's own title on it.
    @Test func sendsUnderTheChoicesTitleWithoutASendTitle() throws {
        let recorder = Recorder()
        let draft = ReplyDraft()
        draft.choice = NativeChoice(title: "Answer", textInput: NativeChoice.TextInput())
        draft.text = "yes"
        let sut = choices([draft.choice!], draft: draft, recorder: recorder)

        try sut.inspect().findAll(ViewType.Button.self, where: { try $0.labelView().text().string() == "Answer" }).last?.tap()

        #expect(recorder.replies == ["Answer: yes"])
    }

    /// Opening a field makes the sidebar take the keyboard and focuses the field once; a field shown again, as
    /// when the list scrolls it back into view, takes neither. Return sends what was typed, Escape closes it.
    @Test func fieldTakesTheKeyboardOnceAndAnswersReturnAndEscape() async throws {
        let recorder = Recorder()
        let draft = ReplyDraft()
        var keyboardRequests = 0
        let sut = choices([Self.reply], draft: draft, recorder: recorder).environment(\.requestKeyboard) { keyboardRequests += 1 }

        try sut.inspect().find(button: "Reply").tap()
        #expect(keyboardRequests == 1)
        #expect(draft.focusRequested)
        try await sut.inspect().find(ViewType.TextField.self).callTask()
        #expect(!draft.focusRequested)
        try await sut.inspect().find(ViewType.TextField.self).callTask()
        #expect(keyboardRequests == 1)

        draft.text = "On my way"
        try sut.inspect().find(ViewType.TextField.self).callOnSubmit()
        #expect(recorder.replies == ["Reply: On my way"])
        try sut.inspect().find(ViewType.TextField.self).callOnExitCommand()
        #expect(draft.choice == nil)
        #expect(draft.text.isEmpty)
    }

    /// Each row starts at the leading edge, one row height and the spacing below the last.
    @Test func placesButtonsRowByRow() {
        final class Frames { var byIndex: [Int: CGRect] = [:] }
        let frames = Frames()
        let host = NSHostingView(rootView: WrappingLayout(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Color.clear.frame(width: 60, height: 20)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("layout")) }) { frames.byIndex[index] = $0 }
            }
        }.frame(width: 130, alignment: .topLeading).coordinateSpace(.named("layout")))
        host.frame = CGRect(x: 0, y: 0, width: 130, height: 46)
        host.layoutSubtreeIfNeeded()

        #expect(frames.byIndex[0]?.origin == CGPoint(x: 0, y: 0))
        #expect(frames.byIndex[1]?.origin == CGPoint(x: 66, y: 0))
        #expect(frames.byIndex[2]?.origin == CGPoint(x: 0, y: 26))
    }

    /// A button wider than the column takes the column's width and a row of its own, as measured.
    @Test func narrowsButtonsWiderThanTheColumn() {
        final class Frames { var byIndex: [Int: CGRect] = [:] }
        let frames = Frames()
        let host = NSHostingView(rootView: WrappingLayout(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let width: CGFloat = index == 0 ? 100 : 30
                Color.clear.frame(minWidth: 10, idealWidth: width, maxWidth: width).frame(height: 20)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("layout")) }) { frames.byIndex[index] = $0 }
            }
        }.frame(width: 80, alignment: .topLeading).coordinateSpace(.named("layout")))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.height == 46)
        #expect(frames.byIndex[0] == CGRect(x: 0, y: 0, width: 80, height: 20))
        #expect(frames.byIndex[1]?.origin == CGPoint(x: 0, y: 26))
        #expect(frames.byIndex[2]?.origin == CGPoint(x: 36, y: 26))
    }

    /// AppKit's push buttons draw no role in a color, so a destructive choice draws its title red itself.
    @Test func drawsDestructiveChoicesRed() {
        func redPixels(_ button: ChoiceButton) -> Int {
            let host = NSHostingView(rootView: button)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var count = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4, color.alphaComponent > 0.5 { count += 1 }
                }
            }
            return count
        }

        #expect(redPixels(ChoiceButton(title: "Delete", isDestructive: true) {}) > 20)
        #expect(redPixels(ChoiceButton(title: "Delete") {}) == 0)
    }

    /// Buttons that do not fit beside each other start a new row.
    @Test func wrapsButtonsOntoNewRows() {
        func size(width: CGFloat) -> CGSize {
            NSHostingView(rootView: WrappingLayout(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Color.clear.frame(width: 60, height: 20) }
            }.frame(width: width)).fittingSize
        }

        #expect(size(width: 200).height == 20)
        #expect(size(width: 130).height == 46)
        #expect(size(width: 50).height == 72)
    }
}
