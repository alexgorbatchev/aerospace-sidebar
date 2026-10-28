import ApplicationServices
import Foundation
import PermissionFlow
@testable import SidebarKit
import Testing

@MainActor
struct PermissionGuideTests {
    /// Full Disk Access counts as granted when the notification database opens; a database that fails for
    /// another reason than macOS refusing access, here a missing one, leaves it unknown.
    @Test func reportsFullDiskAccessByTheNotificationDatabase() throws {
        let fixture = try NotificationDatabaseFixture()
        let access = NotificationDatabaseAccess(database: fixture.database)
        #expect(access.capability == .preflightSupported)
        #expect(access.authorizationState() == .unknown)

        try fixture.create()

        #expect(access.authorizationState() == .granted)
    }

    @Test func readsStatusThroughPermissionFlow() throws {
        let fixture = try NotificationDatabaseFixture()
        try fixture.create()
        let guide = PermissionFlowGuide(notificationDatabase: fixture.database)

        #expect(guide.state(of: .fullDiskAccess) == .granted)
        #expect(guide.state(of: .accessibility) == (AXIsProcessTrusted() ? .granted : .notGranted))
    }

    /// Remove runs `tccutil reset` for the app's bundle identifier with the permission's TCC service name.
    @Test(arguments: [(PermissionFlowPane.accessibility, "Accessibility"), (.fullDiskAccess, "SystemPolicyAllFiles")])
    func removesThroughTCCUtil(pane: PermissionFlowPane, service: String) async throws {
        let fixture = try NotificationDatabaseFixture()
        let calls = Calls()
        let guide = PermissionFlowGuide(notificationDatabase: fixture.database, bundleIdentifier: "com.example.sidebar") { executable, arguments in
            await calls.record([executable] + arguments)
            return CommandResult(status: 0, output: "Successfully reset")
        }

        let result = await guide.reset(pane)

        #expect(result.status == 0)
        #expect(await calls.all == [["/usr/bin/tccutil", "reset", service, "com.example.sidebar"]])
    }

    @Test func refusesToRemovePermissionsTheSidebarDoesNotUse() async throws {
        let fixture = try NotificationDatabaseFixture()
        let calls = Calls()
        let guide = PermissionFlowGuide(notificationDatabase: fixture.database, bundleIdentifier: "com.example.sidebar") { executable, arguments in
            await calls.record([executable] + arguments)
            return CommandResult(status: 0, output: "")
        }

        let result = await guide.reset(.camera)

        #expect(result.status == 64)
        #expect(result.output == "The sidebar does not use the camera permission.")
        #expect(await calls.all.isEmpty)
    }

    /// `tccutil` itself: an unknown bundle identifier fails without touching any permission.
    @Test func runsTCCUtil() async throws {
        let result = await SystemCommand.run("/usr/bin/tccutil", ["reset", "SystemPolicyAllFiles", "com.example.does-not-exist"])

        #expect(result.status != 0)
        #expect(result.output.contains("com.example.does-not-exist"))
    }

    @Test func reportsCommandsThatCannotStart() async {
        let result = await SystemCommand.run("/nonexistent/tool", [])

        #expect(result.status == 127)
    }
}

private actor Calls {
    private(set) var all: [[String]] = []

    func record(_ call: [String]) {
        all.append(call)
    }
}
