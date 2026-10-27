import Foundation
import os
import SidebarProtocol

extension Logger {
    /// A logger in `category` under `loggingSubsystem`.
    init(category: String) {
        self.init(subsystem: Self.loggingSubsystem, category: category)
    }

    /// The app's bundle identifier inside the app, so `log stream` for that subsystem shows only the app.
    /// Any other process running this code, such as the test runner, logs under `<bundle id>.tests`.
    static let loggingSubsystem = subsystem(forMainBundle: Bundle.main.bundleIdentifier)

    static func subsystem(forMainBundle identifier: String?) -> String {
        identifier == SidebarApp.bundleIdentifier ? SidebarApp.bundleIdentifier : "\(SidebarApp.bundleIdentifier).tests"
    }
}
