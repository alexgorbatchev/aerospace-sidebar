import AppKit
import SidebarKit

let delegate = SidebarAppDelegate.launching(arguments: CommandLine.arguments)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
