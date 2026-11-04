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

    /// A letter with any number of combining marks is one character, so characters alone would let a
    /// "one-character" title of any size through.
    @Test func limitsBytesAsWellAsCharacters() throws {
        let stacked = "e" + String(repeating: "\u{301}", count: 50_000)
        #expect(stacked.count == 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "title", limit: NotificationPayload.maxTitleLength)) {
            try NotificationPayload(title: stacked)
        }

        // A family emoji is one character of 25 bytes: text of them fits while it stays within four bytes per
        // character of the limit.
        let family = "👨‍👩‍👧‍👦"
        let fitting = NotificationPayload.maxBodyLength * NotificationPayload.maxBytesPerCharacter / family.utf8.count
        #expect(try NotificationPayload(body: String(repeating: family, count: fitting)).body.count == fitting)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "body", limit: NotificationPayload.maxBodyLength)) {
            try NotificationPayload(body: String(repeating: family, count: fitting + 1))
        }
    }

    @Test func limitsTheClickAction() throws {
        let command = String(repeating: "x", count: NotificationPayload.maxCommandLength + 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "command", limit: NotificationPayload.maxCommandLength)) {
            try NotificationPayload(title: "t", action: .run(command: command, workingDirectory: "/"))
        }
        let directory = "/" + String(repeating: "d", count: NotificationPayload.maxWorkingDirectoryLength)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "workingDirectory", limit: NotificationPayload.maxWorkingDirectoryLength)) {
            try NotificationPayload(title: "t", action: .run(command: "ls", workingDirectory: directory))
        }
        let url = try #require(URL(string: "https://example.com/" + String(repeating: "p", count: NotificationPayload.maxOpenURLLength)))
        #expect(throws: SidebarRequestError.fieldTooLong(field: "open", limit: NotificationPayload.maxOpenURLLength)) {
            try NotificationPayload(title: "t", action: .open(url))
        }
        #expect(try NotificationPayload(title: "t", action: .run(command: "ls", workingDirectory: "/tmp")).action
            == .run(command: "ls", workingDirectory: "/tmp"))
    }

    @Test func iconIsOptionalAndLimited() throws {
        #expect(try NotificationPayload(title: "t", icon: "slack").icon == "slack")
        #expect(try NotificationPayload(title: "t", icon: "").icon == nil)
        let long = String(repeating: "x", count: NotificationPayload.maxIconLength + 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "icon", limit: NotificationPayload.maxIconLength)) {
            try NotificationPayload(title: "t", icon: long)
        }
    }

    @Test func bundleIdentifierIsOptionalAndLimited() throws {
        let payload = try NotificationPayload(title: "t", bundleIdentifier: "com.mitchellh.ghostty")
        #expect(payload.bundleIdentifier == "com.mitchellh.ghostty")
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: JSONEncoder().encode(payload)) == payload)
        #expect(try NotificationPayload(title: "t", bundleIdentifier: "").bundleIdentifier == nil)
        let limit = NotificationPayload.maxBundleIdentifierLength
        #expect(throws: SidebarRequestError.fieldTooLong(field: "bundleIdentifier", limit: limit)) {
            try NotificationPayload(title: "t", bundleIdentifier: String(repeating: "x", count: limit + 1))
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

    /// A markdown body keeps its flag through the socket's JSON; a payload from a client that sends none is plain.
    @Test func carriesTheMarkdownFlag() throws {
        let markdown = try NotificationPayload(body: "**done**", markdown: true)
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: JSONEncoder().encode(markdown)) == markdown)
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: Data(#"{"body":"**done**"}"#.utf8)).markdown == false)
        // The limits apply to the markdown as written, syntax included.
        let syntax = String(repeating: "*", count: NotificationPayload.maxBodyLength - 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "body", limit: NotificationPayload.maxBodyLength)) {
            try NotificationPayload(body: syntax + "ab", markdown: true)
        }
    }
}

struct PushedChoiceTests {
    static let docs = URL(string: "https://example.com/docs")!

    @Test func validatesTitleAndAction() throws {
        #expect(throws: SidebarRequestError.emptyChoiceTitle) { try PushedChoice(title: "", action: .answer) }
        let long = String(repeating: "x", count: PushedChoice.maxTitleLength + 1)
        #expect(throws: SidebarRequestError.fieldTooLong(field: "choice title", limit: PushedChoice.maxTitleLength)) {
            try PushedChoice(title: long, action: .answer)
        }
        #expect(throws: SidebarRequestError.missingChoiceCommand("Deploy")) {
            try PushedChoice(title: "Deploy", action: .run(command: "", workingDirectory: "/"))
        }
        #expect(throws: SidebarRequestError.fieldTooLong(field: "choice command", limit: NotificationPayload.maxCommandLength)) {
            try PushedChoice(title: "Deploy", action: .run(
                command: String(repeating: "x", count: NotificationPayload.maxCommandLength + 1), workingDirectory: "/"
            ))
        }
        #expect(throws: SidebarRequestError.fieldTooLong(field: "choice workingDirectory", limit: NotificationPayload.maxWorkingDirectoryLength)) {
            try PushedChoice(title: "Deploy", action: .run(
                command: "make", workingDirectory: "/" + String(repeating: "d", count: NotificationPayload.maxWorkingDirectoryLength)
            ))
        }
        let longURL = try #require(URL(string: "https://example.com/" + String(repeating: "p", count: NotificationPayload.maxOpenURLLength)))
        #expect(throws: SidebarRequestError.fieldTooLong(field: "choice URL", limit: NotificationPayload.maxOpenURLLength)) {
            try PushedChoice(title: "Docs", action: .open(longURL))
        }
        #expect(throws: SidebarRequestError.invalidOpenURL("file:///tmp")) {
            try PushedChoice(title: "Docs", action: .open(URL(fileURLWithPath: "/tmp")))
        }
        #expect(throws: SidebarRequestError.linkChoiceAsksForText("Docs")) {
            try PushedChoice(title: "Docs", action: .open(Self.docs), asksForText: true)
        }
        let reply = try PushedChoice(title: "Reply", action: .run(command: "say \"$AEROSPACE_SIDEBAR_REPLY\"", workingDirectory: "/"), asksForText: true)
        #expect(reply.asksForText)
    }

    @Test func decodingAppliesValidation() throws {
        let choice = try PushedChoice(title: "Yes", action: .answer, asksForText: true)
        #expect(try JSONDecoder().decode(PushedChoice.self, from: JSONEncoder().encode(choice)) == choice)
        #expect(try JSONDecoder().decode(PushedChoice.self, from: Data(#"{"title":"No","action":{"answer":{}}}"#.utf8))
            == PushedChoice(title: "No", action: .answer))
        #expect(throws: SidebarRequestError.emptyChoiceTitle) {
            try JSONDecoder().decode(PushedChoice.self, from: Data(#"{"title":"","action":{"answer":{}}}"#.utf8))
        }
    }

    /// A reply is bounded like the other fields: in characters, and in bytes per character of the limit.
    @Test func boundsReplies() {
        #expect(PushedChoice.fits(reply: String(repeating: "x", count: PushedChoice.maxReplyLength)))
        #expect(!PushedChoice.fits(reply: String(repeating: "x", count: PushedChoice.maxReplyLength + 1)))
        #expect(!PushedChoice.fits(reply: "e" + String(repeating: "\u{301}", count: 4 * PushedChoice.maxReplyLength)))
    }

    /// A process cannot be started with a NUL in its arguments or environment (`Process` raises an exception that
    /// aborts the app), so values that reach one refuse it: a choice's title (its command's environment), commands,
    /// working directories and replies. Text that is only shown may hold one.
    @Test func refusesNULInValuesThatReachAProcess() throws {
        #expect(throws: SidebarRequestError.nulCharacter(field: "choice title")) {
            try PushedChoice(title: "a\u{0}b", action: .answer)
        }
        #expect(throws: SidebarRequestError.nulCharacter(field: "choice command")) {
            try PushedChoice(title: "Run", action: .run(command: "true\u{0}", workingDirectory: "/"))
        }
        #expect(throws: SidebarRequestError.nulCharacter(field: "choice workingDirectory")) {
            try PushedChoice(title: "Run", action: .run(command: "true", workingDirectory: "/\u{0}tmp"))
        }
        #expect(throws: SidebarRequestError.nulCharacter(field: "command")) {
            try NotificationPayload(title: "t", action: .run(command: "true\u{0}", workingDirectory: "/"))
        }
        #expect(throws: SidebarRequestError.nulCharacter(field: "workingDirectory")) {
            try NotificationPayload(title: "t", action: .run(command: "true", workingDirectory: "/\u{0}"))
        }
        #expect(throws: SidebarRequestError.nulCharacter(field: "choice title")) {
            try JSONDecoder().decode(ControlRequest.self, from: Data(#"""
                {"pushNotification":{"_0":{"title":"t","choices":[{"title":"a\u0000b","action":{"run":{"command":"true","workingDirectory":"/tmp"}}}]}}}
                """#.utf8))
        }
        #expect(!PushedChoice.fits(reply: "a\u{0}b"))
        #expect(try NotificationPayload(title: "a\u{0}b", body: "c\u{0}d").title == "a\u{0}b")
    }

    @Test func payloadsBoundTheirChoices() throws {
        let yes = try PushedChoice(title: "Yes", action: .answer)
        #expect(throws: SidebarRequestError.duplicateChoice("Yes")) {
            try NotificationPayload(title: "t", choices: [yes, PushedChoice(title: "Yes", action: .open(Self.docs))])
        }
        let many = try (0...NotificationPayload.maxChoices).map { try PushedChoice(title: "\($0)", action: .answer) }
        #expect(throws: SidebarRequestError.tooManyChoices(limit: NotificationPayload.maxChoices)) {
            try NotificationPayload(title: "t", choices: many)
        }
        let payload = try NotificationPayload(title: "t", choices: Array(many.dropLast()))
        #expect(payload.asks)
        #expect(try JSONDecoder().decode(NotificationPayload.self, from: JSONEncoder().encode(payload)) == payload)
        #expect(try !NotificationPayload(title: "t", choices: [PushedChoice(title: "Docs", action: .open(Self.docs))]).asks)
    }

    /// Only an ask's choices answer it, and every one of an ask's choices does.
    @Test func requestsCheckWhatTheirChoicesAnswer() throws {
        let yes = try PushedChoice(title: "Yes", action: .answer)
        let docs = try PushedChoice(title: "Docs", action: .open(Self.docs))

        #expect(throws: Never.self) { try ControlRequest.pushNotification(NotificationPayload(title: "t", choices: [docs])).validate() }
        #expect(throws: Never.self) { try ControlRequest.askNotification(NotificationPayload(title: "t", choices: [yes])).validate() }
        #expect(throws: SidebarRequestError.answerOutsideAsk) {
            try ControlRequest.pushNotification(NotificationPayload(title: "t", choices: [yes])).validate()
        }
        #expect(throws: SidebarRequestError.askNeedsAnswers) {
            try ControlRequest.askNotification(NotificationPayload(title: "t", choices: [yes, docs])).validate()
        }
        #expect(throws: SidebarRequestError.askNeedsAnswers) {
            try ControlRequest.askNotification(NotificationPayload(title: "t")).validate()
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

    /// `markdown=1` or `true` turns markdown on, `0` or `false` leaves it off, and the URL form writes `1` only when
    /// it is on.
    @Test(arguments: [("1", true), ("true", true), ("TRUE", true), ("0", false), ("false", false)])
    func urlsCarryTheMarkdownFlag(value: String, markdown: Bool) throws {
        let url = try #require(URL(string: "aerospace-sidebar://notification/push?body=**x**&markdown=\(value)"))
        let payload = try NotificationPayload(body: "**x**", markdown: markdown)

        #expect(try SidebarRequest(url: url) == .pushNotification(payload))
        let written = try SidebarRequest.pushNotification(payload).url()
        #expect(written.query?.contains("markdown=1") == markdown)
        #expect(try SidebarRequest(url: written) == .pushNotification(payload))
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
        ("aerospace-sidebar://notification/push?title=t&markdown=yes", .invalidMarkdownFlag("yes")),
        ("aerospace-sidebar://notification/push?title=t&open=file:///Applications/Calculator.app", .invalidOpenURL("file:///Applications/Calculator.app")),
    ])
    func rejectsInvalidURLs(url: String, error: SidebarRequestError) {
        #expect(throws: error) { try SidebarRequest(url: URL(string: url)!) }
    }

    /// URLs come from any process or web page, so their fields are bounded in bytes too.
    @Test func rejectsURLFieldsStackingCombiningMarks() throws {
        var components = URLComponents(string: "aerospace-sidebar://notification/push")!
        components.queryItems = [URLQueryItem(name: "body", value: "e" + String(repeating: "\u{301}", count: 20_000))]

        #expect(throws: SidebarRequestError.fieldTooLong(field: "body", limit: NotificationPayload.maxBodyLength)) {
            try SidebarRequest(url: components.url!)
        }
    }

    /// Each `choice` item is one link button: its title, then the URL after the first `=`.
    @Test func urlsCarryLinkChoices() throws {
        let payload = try NotificationPayload(title: "t", choices: [
            PushedChoice(title: "Docs", action: .open(URL(string: "https://example.com/a?x=1&y=2")!)),
            PushedChoice(title: "Home", action: .open(URL(string: "http://example.com")!)),
        ])

        let url = try SidebarRequest.pushNotification(payload).url()

        #expect(try SidebarRequest(url: url) == .pushNotification(payload))
        let equals = try NotificationPayload(title: "t", choices: [PushedChoice(title: "a=b", action: .open(URL(string: "http://example.com")!))])
        #expect(throws: SidebarRequestError.equalsInURLChoiceTitle("a=b")) { try SidebarRequest.pushNotification(equals).url() }
        let handWritten = URL(string: "aerospace-sidebar://notification/push?title=t&choice=Docs=https://example.com/docs")!
        #expect(try SidebarRequest(url: handWritten) == .pushNotification(NotificationPayload(
            title: "t", choices: [PushedChoice(title: "Docs", action: .open(URL(string: "https://example.com/docs")!))]
        )))
    }

    @Test(arguments: [
        ("choice=Docs", SidebarRequestError.invalidChoiceItem("Docs")),
        ("choice==https://example.com", .emptyChoiceTitle),
        ("choice=Run=file:///Applications/Calculator.app", .invalidOpenURL("file:///Applications/Calculator.app")),
        ("choice=A=https://a.example&choice=A=https://b.example", .duplicateChoice("A")),
    ])
    func rejectsInvalidURLChoices(query: String, error: SidebarRequestError) {
        #expect(throws: error) { try SidebarRequest(url: URL(string: "aerospace-sidebar://notification/push?title=t&\(query)")!) }
    }

    /// Any process or web page can open a URL, so it carries no choice that runs a command, asks for text or
    /// answers an ask.
    @Test func urlsNeverCarryChoicesBeyondLinks() throws {
        for choice in [
            try PushedChoice(title: "Run", action: .run(command: "ls", workingDirectory: "/")),
            try PushedChoice(title: "Yes", action: .answer),
        ] {
            #expect(throws: SidebarRequestError.actionNotAllowedInURL) {
                try SidebarRequest.pushNotification(NotificationPayload(title: "t", choices: [choice])).url()
            }
        }
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
        (.fieldTooLong(field: "body", limit: 9), "body is longer than 9 characters (or 36 bytes in UTF-8)"),
        (.invalidOpenURL("ftp://x"), "'ftp://x'"),
        (.invalidMarkdownFlag("yes"), "'yes' is not a markdown flag"),
        (.actionNotAllowedInURL, "aerospace-sidebar CLI"),
        (.emptyChoiceTitle, "a choice needs a title"),
        (.duplicateChoice("Yes"), "two choices are titled 'Yes'"),
        (.tooManyChoices(limit: 8), "at most 8 choices"),
        (.missingChoiceCommand("Deploy"), "'Deploy' needs a command"),
        (.linkChoiceAsksForText("Docs"), "'Docs' opens a link"),
        (.invalidChoiceItem("Docs"), "expected TITLE=URL"),
        (.equalsInURLChoiceTitle("a=b"), "'a=b' holds '='"),
        (.askNeedsAnswers, "an ask needs at least one choice"),
        (.answerOutsideAsk, "only an ask's choices"),
        (.nulCharacter(field: "command"), "command holds a NUL character"),
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
