// Stacks PNGs vertically at 2x with nearest-neighbour sampling, to compare variants or animation frames.
// Usage: swift stack.swift <out.png> <in1.png> [in2.png ...]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: stack.swift <out.png> <in1.png> [in2.png ...]\n".data(using: .utf8)!)
    exit(2)
}
let images = args.dropFirst(2).map { path -> CGImage in
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}
let gap = 10, scale = 2
let width = images.map(\.width).max()!, height = images.map(\.height).reduce(0, +) + gap * images.count
let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(.white)
context.fill(CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
context.interpolationQuality = .none
var y = height * scale
for image in images {
    y -= (image.height + gap) * scale
    context.draw(image, in: CGRect(x: 0, y: y, width: image.width * scale, height: image.height * scale))
}
try! NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[1]))
