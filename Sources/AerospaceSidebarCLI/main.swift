import Foundation
import SidebarCLI

exit(await SidebarCLI.main(arguments: Array(CommandLine.arguments.dropFirst())))
