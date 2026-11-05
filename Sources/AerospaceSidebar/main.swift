import AppKit
import SidebarKit

guard let delegate = SidebarAppDelegate.launching(arguments: CommandLine.arguments) else { exit(EXIT_SUCCESS) }
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
