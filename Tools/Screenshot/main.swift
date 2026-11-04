// Helper for `just screenshot`: finds the demo sidebar's panel window and quits an app by process id.
//
//   screenshot-helper window <pid>   prints the window number of the panel the process shows, once it is on screen
//   screenshot-helper quit <pid>     asks the app to quit, as `just stop` does, without touching other copies
//   screenshot-helper crop <png>     cuts the capture below the cards, where the transparent strip begins
import AppKit
import ImageIO
import UniformTypeIdentifiers

func panelWindow(of pid: pid_t) -> Int? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    // The sidebar panel sits one level below the menu bar (`SidebarPanelController.level`).
    let level = Int(CGWindowLevelForKey(.mainMenuWindow)) - 1
    return windows.first { window in
        window[kCGWindowOwnerPID as String] as? Int32 == pid && window[kCGWindowLayer as String] as? Int == level
    }?[kCGWindowNumber as String] as? Int
}

/// Cuts `url`'s image at the first gap of at least `gap` transparent rows below its content, keeping a margin as tall
/// as the one above the content, so that the image holds the cards and not the empty strip under them.
func crop(_ url: URL, gap: Int = 200) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Rows from the top; the panel's backing is 1% black, so anything at or below 10/255 alpha counts as empty.
    func isEmpty(_ row: Int) -> Bool {
        let start = row * width * 4
        return stride(from: start + 3, to: start + width * 4, by: 4).allSatisfy { pixels[$0] <= 10 }
    }
    guard let top = (0..<height).first(where: { !isEmpty($0) }) else { return false }
    var row = top, emptyRun = 0
    while row < height, emptyRun < gap {
        emptyRun = isEmpty(row) ? emptyRun + 1 : 0
        row += 1
    }
    guard emptyRun >= gap else { return true }
    let bottom = min(height, row - emptyRun + top)
    guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: bottom)),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, cropped, nil)
    return CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: screenshot-helper window|quit <pid> | crop <png>\n".utf8))
    exit(64)
}
switch arguments[1] {
case "crop":
    guard crop(URL(fileURLWithPath: arguments[2])) else { exit(1) }
case "window":
    guard let pid = pid_t(arguments[2]), let window = panelWindow(of: pid) else { exit(1) }
    print(window)
case "quit":
    guard let pid = pid_t(arguments[2]), let app = NSRunningApplication(processIdentifier: pid), app.terminate() else { exit(1) }
default:
    FileHandle.standardError.write(Data("unknown command \(arguments[1])\n".utf8))
    exit(64)
}
