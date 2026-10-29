// Prints the sRGB components (0-255) and alpha of pixels in a PNG, to measure colors instead of eyeballing them.
// Usage: swift pixels.swift <in.png> <x,y> [x,y ...]   (pixel coordinates, top-left origin)
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let data = FileManager.default.contents(atPath: args[1]), let bitmap = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("usage: pixels.swift <in.png> <x,y> [x,y ...]\n".data(using: .utf8)!)
    exit(2)
}
for point in args.dropFirst(2) {
    let xy = point.split(separator: ",").compactMap { Int($0) }
    guard xy.count == 2, let color = bitmap.colorAt(x: xy[0], y: xy[1])?.usingColorSpace(.sRGB) else {
        print("\(point) out of range")
        continue
    }
    let c = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    print("\(point) rgb(\(c[0]), \(c[1]), \(c[2])) alpha \(String(format: "%.3f", color.alphaComponent))")
}
