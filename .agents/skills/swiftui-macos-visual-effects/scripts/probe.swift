// A real-window probe: shows a SwiftUI view in a borderless, non-activating panel and screenshots it at set times.
// Unlike ImageRenderer it draws AppKit-backed controls (push buttons, glass), materials and real compositing.
// Copy this file, replace `Probe` with the variants to compare, then:
//   swiftc -O probe.swift -o probe && ./probe /path/to/out_
// It writes out_0.png, out_1.png, ... one per entry in `captures` and exits. `model.on` flips at `toggleAt`, so a
// slowed animation (e.g. `.animation(.snappy(duration: 3), value: model.on)`) can be caught mid-flight.
// Pass `transparent` as a second argument to make the window clear and capture the screen region instead, so
// materials blur what is really behind the window.
import AppKit
import SwiftUI

final class Model: ObservableObject { @Published var on = false }

struct Probe: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 17, height: 17)
                .background(.regularMaterial, in: Capsule())
            Button("Glass") {}.buttonBorderShape(.capsule)
        }
        .padding(16)
        .scaleEffect(model.on ? 1.1 : 1)
        .animation(.snappy(duration: 3), value: model.on)
        .background(Color(red: 0.35, green: 0.45, blue: 0.25))
    }
}

let toggleAt = 1.0
let captures: [Double] = [0.9, 1.25, 1.6, 2.2, 5.0]
let size = NSSize(width: 240, height: 80)

let transparent = CommandLine.arguments.dropFirst(2).first == "transparent"
let model = Model()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0]
let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.appearance = NSAppearance(named: .darkAqua)
panel.level = .statusBar
if transparent {
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
}
panel.contentView = NSHostingView(rootView: Probe(model: model))
panel.orderFrontRegardless()

func capture(_ index: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let out = CommandLine.arguments[1] + "\(index).png"
    if transparent {
        let rect = "\(Int(frame.minX)),\(Int(screen.frame.height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        process.arguments = ["-x", "-R", rect, out]
    } else {
        process.arguments = ["-x", "-o", "-l", String(panel.windowNumber), out]
    }
    try! process.run()
    process.waitUntilExit()
}
DispatchQueue.main.asyncAfter(deadline: .now() + toggleAt) { model.on = true }
for (index, time) in captures.enumerated() {
    DispatchQueue.main.asyncAfter(deadline: .now() + time) {
        capture(index)
        if index == captures.count - 1 { exit(0) }
    }
}
app.run()
