import Foundation
import SidebarProtocol
import Testing

struct NotificationPayloadTests {
    @Test func requiresTitleOrBody() throws {
        #expect(throws: SidebarRequestError.emptyNotification) { try NotificationPayload(subtitle: "only") }
        #expect(try NotificationPayload(title: "t").title == "t")
        #expect(try NotificationPayload(body: "b").body == "b")
    }

    @Test(arguments: [
        ("title", NotificationPayload.maxTitleLength),
        ("subtitle", NotificationPayload.maxSubtitleLength),
        ("body", NotificationPayload.maxBodyLength),
    ])
    func rejectsOverlongFields(field: String, limit: Int) {
        let long = String(repeating: "x", count: limit + 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: field, limit: limit)) {
            try NotificationPayload(
                title: field == "title" ? long : "t",
                subtitle: field == "subtitle" ? long : "",
                body: field == "body" ? long : ""
            )
        }
    }

    @Test func iconIsOptionalAndLimited() throws {
        #expect(try NotificationPayload(title: "t", icon: "slack").icon == "slack")
        #expect(try NotificationPayload(title: "t", icon: "").icon == nil)
        let long = String(repeating: "x", count: NotificationPayload.maxIconLength + 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "icon", limit: NotificationPayload.maxIconLength)) {
            try NotificationPayload(title: "t", icon: long)
        }
    }

    @Test func decodingAppliesValidation() throws {
        let valid = Data(#"{"title":"t","action":{"open":{"_0":"https://example.com"}}}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: valid)
            == NotificationPayload(title: "t", action: .open(URL(string: "https://example.com")!)))
        let withIcon = try NotificationPayload(title: "t", icon: ":slack:")
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: JSONEncoder().encode(withIcon)) == withIcon)
        #expect(throws: SidebarRequestError.emptyNotification) {
            try JSONDecoder().decode(NotificationPayload.self, from: Data(#"{"subtitle":"s"}"#.utf8))
        }
    }
}

struct SidebarRequestTests {
    @Test func urlRoundTripsSpecialCharacters() throws {
        let payload = try NotificationPayload(
            title: "a+b & c=d",
            subtitle: "50% done",
            body: "line 1\nline 2 #hash",
            icon: ":slack:",
            action: .open(URL(string: "https://example.com/path?x=1&y=2")!)
        )

        let url = try SidebarRequest.pushNotification(payload).url()

        #expect(url.absoluteString.hasPrefix("aerospace-sidebar://notification/push?"))
        #expect(!url.query!.contains("+"))
        #expect(try SidebarRequest(url: url) == .pushNotification(payload))
    }

    @Test func omitsEmptyFields() throws {
        let url = try SidebarRequest.pushNotification(NotificationPayload(title: "t")).url()

        #expect(url.absoluteString == "aerospace-sidebar://notification/push?title=t")
    }

    @Test func parsesHandWrittenURL() throws {
        let url = URL(string: "AEROSPACE-SIDEBAR://notification/push?body=from%20a%20page&body=last&icon=slack&open=http://example.com")!

        #expect(try SidebarRequest(url: url) == .pushNotification(NotificationPayload(
            body: "last",
            icon: "slack",
            action: .open(URL(string: "http://example.com")!)
        )))
    }

    @Test(arguments: [
        ("https://notification/push?title=t", SidebarRequestError.unsupportedScheme("https")),
        ("aerospace-sidebar://notification/pull?title=t", .unknownRoute("notification/pull")),
        ("aerospace-sidebar://toast?title=t", .unknownRoute("toast")),
        ("aerospace-sidebar://notification/push", .emptyNotification),
        ("aerospace-sidebar://notification/push?title=t&open=javascript:alert(1)", .invalidOpenURL("javascript:alert(1)")),
        ("aerospace-sidebar://notification/push?title=t&open=file:///Applications/Calculator.app", .invalidOpenURL("file:///Applications/Calculator.app")),
    ])
    func rejectsInvalidURLs(url: String, error: SidebarRequestError) {
        #expect(throws: error) { try SidebarRequest(url: URL(string: url)!) }
    }

    @Test func urlsNeverCarryCommandsOrNonWebLinks() throws {
        let run = try NotificationPayload(title: "t", action: .run(command: "ls", workingDirectory: "/"))
        let file = try NotificationPayload(title: "t", action: .open(URL(fileURLWithPath: "/tmp")))

        #expect(throws: SidebarRequestError.actionNotAllowedInURL) { try SidebarRequest.pushNotification(run).url() }
        #expect(throws: SidebarRequestError.invalidOpenURL("file:///tmp")) { try SidebarRequest.pushNotification(file).url() }
    }

    @Test(arguments: [
        (SidebarRequestError.unsupportedScheme("https"), "'https'"),
        (.unsupportedScheme(nil), "(none)"),
        (.unknownRoute("x"), "'x'"),
        (.emptyNotification, "title or a body"),
        (.fieldTooLong(field: "body", limit: 9), "body is longer than 9"),
        (.invalidOpenURL("ftp://x"), "'ftp://x'"),
        (.actionNotAllowedInURL, "aerospace-sidebar CLI"),
    ])
    func describesErrors(error: SidebarRequestError, fragment: String) {
        #expect(error.description.contains(fragment))
    }

    @Test func controlSocketLivesInPerUserTemporaryDirectory() {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        #expect(SidebarApp.controlSocketPath == URL(fileURLWithPath: directory)
            .appendingPathComponent("com.alexgorbatchev.aerospace-sidebar.sock").path)
    }
}
