---
name: swiftui-macos-visual-effects
description: Use when building, tuning, or debugging visual effects in SwiftUI or AppKit views on macOS, including shadows, outlines and rims, materials, glass push buttons, hover and press effects, scale and expand animations, edge antialiasing, pixel alignment, and jagged, blurry, or black-rendering controls.
author: alexgorbatchev
metadata:
  created_on: 2026-10-28 20:55
  last_modified: 2026-10-29 10:02
  status: current
---

Rules learned by measuring real windows on macOS 26 (Retina, dark appearance). Each came from a bug that looked right in code and wrong on screen.

## Shadows

- Never apply `.shadow`, `.compositingGroup()`, or another filter to an AppKit-backed control (`Button` push buttons, macOS 26 glass bezels, anything SwiftUI draws through `NSView`). It renders the control into an offscreen layer where the glass has nothing behind it to sample, and the bezel turns solid black. Even a 0.4 pt shadow that covers nothing does it.
- Cast a shadow for translucent content (glass, materials, translucent fills) from a copy of its outline behind it, with the outline cut out:

  ```swift
  content.background {
      Capsule().fill(.black)                      // opaque: an unfilled Shape uses labelColor, ~85% alpha
          .shadow(color: .black.opacity(o), radius: r, y: dy)   // or .offset(y:) for a hard shadow
          .mask {
              Rectangle().padding(-3 * max(r, dy))  // room for the blur
                  .overlay { Capsule().blendMode(.destinationOut) }
                  .compositingGroup()
          }
  }
  ```

  Draw the black copy one device pixel smaller than the shape (`.padding(1 / displayScale)`). An exact copy leaves a sliver in the partly covered edge pixels, which the cut-out only removes in proportion to coverage, and darkens them. A plain shadow under translucent content also shows through it and darkens it.
- Make the outline known: `.buttonBorderShape(.capsule)` (or `.roundedRectangle(radius:)`) sets a push button's bezel shape, so the cut-out matches it exactly.
- A shadow is darkest right at the edge. Applied to the composited view (`compositingGroup().shadow`), it shows through the partly covered antialiased edge pixels and draws a stepped, one-pixel dark ring that looks like jaggies, worst over busy wallpaper. Cards shadowed as a whole get it too. Cut-out shadows avoid the ring, but a soft halo still reads as a dark line over high-contrast backgrounds. Diagnose by turning the shadows off in the real app before touching anything else. Measured along a card corner's diagonal (inside / edge / outside): a direct shadow gave 127 / 113 / 164, with the edge darker than both neighbours; an exact cut-out gave 126 / 136 / 165; a cut-out from a one-pixel-smaller copy gave 126 / 148 / 169.
- SwiftUI's `shadow(radius:)` is roughly half a CSS `blur`. Translate when a design comes from HTML.

## Edges and pixels

- Edges are crisp only on whole device pixels. Anything under `scaleEffect` (including a parent's hover scale), or sized from a font-relative factor, lands between pixels. Draw at the final size instead of scaling, and round sizes and offsets to `@Environment(\.displayScale)`: `(points * displayScale).rounded() / displayScale`.
- To keep a child crisp inside a scaled parent, move it outside the `scaleEffect` and offset it to where the scaled corner lands: `overhang + size * (scale - 1) / 2` per axis, rounded to pixels, with the parent's size from `onGeometryChange`. Draw it at the size it appeared inside the scale (its size × the parent's scale), so it looks the same.
- A hairline (0.5 pt = one Retina pixel), high-contrast rim on a small round control steps visibly around the curve however well it is aligned. Drop the rim, or make it wider and fainter so antialiasing has room.
- Nothing system-wide smooths shape edges. `AppleFontSmoothing` only affects text, and `antialiased:` on strokes and fills can only turn antialiasing off.

## Animation

- `.scaleEffect` anchors at the center. When the view's width also animates, the edge meant to stay put drifts. Anchor on the stationary side (`anchor: .trailing` for a view that grows leading).
- Revealing a label: don't insert the title with a `.transition`. It is laid out at full width at once and rides along with the container's growing edge, sliding in. Keep it laid out, `fixedSize()` the row, and collapse it with `.frame(width: collapsed ? iconWidth : nil, alignment: <icon side>)`. Clip to the shape and fade the title's opacity, so widening uncovers it in place.
- `.animation(_:body:)` scopes animation to the modifiers in its body, such as `opacity`, but cannot reach a color passed into a Shape (`strokeBorder(color)`), which follows the outer `.animation(_:value:)`. To change a stroke's color without fading it through grey, or at its own speed, draw one layer per color and switch them with `opacity` inside a scoped `.animation`. Changing only the transaction would also freeze the layer's geometry while its parent animates.
- Vibrant `.secondary` and white don't interpolate; animating between them flashes. Fade a white copy of the label over the secondary one instead.

## Verifying on screen

- Check effects in a real window, not `ImageRenderer`: it can't draw AppKit-backed controls, glass or real material compositing. Copy `scripts/probe.swift`, put the variants side by side in its `Probe` view, build with `swiftc -O`, and run it. It shows a borderless, non-activating panel that never takes focus, captures it at set times, and exits.
- To see an animation, slow it (`duration: 3`) and capture mid-flight. A one-pixel reference line at the edge meant to stay put shows any drift.
- Run `scripts/probe.swift` with `transparent` when the real window is transparent (overlays, sidebars). Materials then blur what is behind the window, which an opaque probe does not reproduce.
- Zoom with nearest-neighbour sampling, never a smoothing resize, which hides the pixel steps you are looking for: `swift scripts/zoom.swift in.png out.png x y w h 8`. Compare variants or frames with `swift scripts/stack.swift out.png a.png b.png`.
- Measure colors instead of eyeballing them: `swift scripts/pixels.swift shot.png x,y …`. For example, the white overlay that matches a native bezel is `(button - card) / (255 - card)` per channel; a macOS 26 push button's bezel measured 16% white.
- A user's screenshot is evidence. Check its pixel size against the expected point size × 2 to confirm Retina scale, then zoom the edge.
- When the user is iterating on a look, give them a bench: an HTML artifact with sliders for every value at rest and on hover, which prints the values to paste back. Translate its CSS units (blur, `box-shadow` rings) into SwiftUI when applying them.

## Testing

- Render with animations off (`.transaction { $0.disablesAnimations = true }`) so a view draws its final state. Even so, a render occasionally came back showing another test's view: a "draws nothing" check saw a neighbouring test's shadow about one run in five. A fresh `.id(UUID())` didn't stop it. Assert absence through the view tree (ViewInspector `findAll(SomeView.self).isEmpty`) rather than pixels, and rerun pixel tests several times before trusting them.
- Test an effect by rendering it on `Color.clear` with known padding at `renderer.scale = 4` and sampling alpha at computed pixels: just outside the edge, just inside it, and the middle. That catches a missing layer, a shadow that leaks inside a cut-out, and wrong state.
- Give the content a translucent fill when testing a shadow. With an opaque fill, `ImageRenderer` keeps a direct shadow's edge pixels between their neighbours and the test can't tell it from a cut-out. With a translucent one, a direct shadow darkens the inside, so assert the inside matches an unshadowed render. Before trusting a pixel test, swap in the broken implementation once and confirm it fails.
- `AnyShapeStyle` can't be compared, and `String(describing:)` gives the same text for different colors. Put a style decision behind an `Equatable` value (an enum case, a struct of numbers) and test that, or test pixels.
- ViewInspector can't call `onHover` (its support is commented out). Give hover-driven views an initial-state parameter (`State(initialValue:)`) and inspect both states. Find custom effects by their `ViewModifier` type and assert on `actualView()`.
- Parameterized `@Test(arguments:)` can't read main-actor statics such as a SwiftUI view's constants; pass a `Bool` and choose inside. Mark constant statics on views that nonisolated code reads `nonisolated static let`.
