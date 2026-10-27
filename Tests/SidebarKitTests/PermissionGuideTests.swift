import ApplicationServices
import Foundation
import PermissionFlow
@testable import SidebarKit
import Testing

@MainActor
struct PermissionGuideTests {
    /// Full Disk Access counts as granted exactly when the notification database opens.
    @Test func reportsFullDiskAccessByTheNotificationDatabase() throws {
        let fixture = try NotificationDatabaseFixture()
        let access = NotificationDatabaseAccess(database: fixture.database)
        #expect(access.capability == .preflightSupported)
        #expect(access.authorizationState() == .notGranted)

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
}
