import os
@testable import SidebarKit
import SidebarProtocol
import Testing

struct LoggingTests {
    /// Only the app logs under its bundle identifier, so watching that subsystem never shows a test run.
    @Test(arguments: [
        (SidebarApp.bundleIdentifier as String?, SidebarApp.bundleIdentifier),
        (nil, "\(SidebarApp.bundleIdentifier).tests"),
        ("com.apple.dt.xctest.tool", "\(SidebarApp.bundleIdentifier).tests"),
    ])
    func logsUnderTheAppsSubsystemOnlyInsideTheApp(bundle: String?, subsystem: String) {
        #expect(Logger.subsystem(forMainBundle: bundle) == subsystem)
    }

    @Test func testsLogApartFromTheApp() {
        #expect(Logger.loggingSubsystem == "\(SidebarApp.bundleIdentifier).tests")
    }
}
