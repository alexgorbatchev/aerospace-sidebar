// Crops a PNG and enlarges it with nearest-neighbour sampling, so single pixels stay visible.
// Usage: swift zoom.swift <in.png> <out.png> <x> <y> <width> <height> <factor>   (pixel coordinates, top-left origin)
import AppKit

let args = CommandLine.arguments
guard args.count == 8, let x = Int(args[3]), let y = Int(args[4]), let w = Int(args[5]), let h = Int(args[6]), let factor = Int(args[7]) else {
    FileHandle.standardError.write("usage: zoom.swift <in.png> <out.png> <x> <y> <width> <height> <factor>\n".data(using: .utf8)!)
    exit(2)
}
guard let image = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let crop = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
    FileHandle.standardError.write("cannot read or crop \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let context = CGContext(data: nil, width: crop.width * factor, height: crop.height * factor, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .none
context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * factor, height: crop.height * factor))
try! NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
