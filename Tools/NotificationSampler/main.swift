// Notification Sampler: posts notifications with actions through UNUserNotificationCenter, as apps that declare
// notification categories do, and pushes every response to the sidebar through the aerospace-sidebar CLI.
// alerter posts through NSUserNotification and declares no categories, so `just test-notifications` launches
// this app for these variants:
//
//     open -g -n .build/NotificationSampler.app --args <aerospace-sidebar CLI> <timeout seconds> <kind>…
//
// It lives outside Package.swift because the coverage gate requires every file under Sources/ in its report.

import AppKit
import UserNotifications

/// A notification the sampler posts, named on the command line; each registers a category of the same name.
enum Kind: String, CaseIterable {
    /// Approve, Reject and Later.
    case choices
    /// A Reply action that opens a text field.
    case reply

    /// Its category. A custom dismiss action reports closing the notification too, as alerter does, which shows
    /// when the sidebar closes one.
    var category: UNNotificationCategory {
        let actions = switch self {
        case .choices:
            [
                UNNotificationAction(identifier: "approve", title: "Approve"),
                UNNotificationAction(identifier: "reject", title: "Reject", options: .destructive),
                UNNotificationAction(identifier: "later", title: "Later"),
            ]
        case .reply:
            [
                UNTextInputNotificationAction(
                    identifier: "reply", title: "Reply", textInputButtonTitle: "Send",
                    textInputPlaceholder: "Say something"
                ),
            ]
        }
        return UNNotificationCategory(
            identifier: rawValue, actions: actions, intentIdentifiers: [], options: .customDismissAction
        )
    }

    var content: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.subtitle = "Posted by Notification Sampler"
        content.categoryIdentifier = rawValue
        switch self {
        case .choices:
            content.title = "Banner with choices"
            content.body = "Approve, Reject and Later; Reject is marked destructive."
        case .reply:
            content.title = "Banner with a reply"
            content.body = "A Reply action that opens a text field with a Send button."
        }
        return content
    }

    /// The title of the action a response names, nil for one no category declares.
    static func title(ofAction identifier: String) -> String? {
        allCases.lazy.flatMap(\.category.actions).first { $0.identifier == identifier }?.title
    }
}

/// Posts the notifications and reports their responses until all are answered or the timeout passes.
@MainActor
final class Sampler: NSObject, UNUserNotificationCenterDelegate {
    private let cli: URL
    private let timeout: Duration
    private let kinds: [Kind]
    /// Until authorization is answered and the notifications are posted, nothing ends the app but the timeout.
    private var isStarting = true
    private var hasTimedOut = false
    /// Identifiers of posted notifications without a response.
    private var unanswered: Set<String> = []
    /// CLI pushes still running; the app quits only after they have finished.
    private var runningPushes = 0

    init(cli: URL, timeout: Duration, kinds: [Kind]) {
        self.cli = cli
        self.timeout = timeout
        self.kinds = kinds
    }

    /// Runs before `NSApplication.run()`: UserNotifications wants its delegate set before the app finishes
    /// launching.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(Kind.allCases.map(\.category)))
        Task {
            try? await Task.sleep(for: timeout)
            await timeOut()
        }
        Task {
            await post()
        }
    }

    private func post() async {
        do {
            // macOS asks on the first run and answers from System Settings › Notifications afterwards.
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                return notAuthorized(reason: nil)
            }
        } catch {
            return notAuthorized(reason: error.localizedDescription)
        }
        for kind in kinds where !hasTimedOut {
            let identifier = UUID().uuidString
            unanswered.insert(identifier)
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: identifier, content: kind.content, trigger: nil)
                )
            } catch {
                unanswered.remove(identifier)
                report("Notification Sampler could not post \(kind.rawValue)", body: error.localizedDescription)
            }
        }
        isStarting = false
        quitWhenDone()
    }

    private func notAuthorized(reason: String?) {
        let hint = """
            Allow "Notification Sampler" to post notifications: answer macOS's request on the first run, \
            otherwise switch it on in System Settings › Notifications.
            """
        let body = [reason, hint].compactMap(\.self).joined(separator: " ")
        // The sampler's own page in System Settings › Notifications, where its switch is.
        let page = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        report("Notification Sampler may not post notifications", body: body, choices: ["Open Settings=open '\(page)'"])
        isStarting = false
        quitWhenDone()
    }

    /// Removes the notifications nobody answered, as alerter's timeout closes its alert, and quits once macOS no
    /// longer lists them.
    private func timeOut() async {
        hasTimedOut = true
        // The removal runs on a background thread and reports nothing, so quitting right away can drop it. A
        // notification left behind would relaunch the sampler without arguments when answered, losing the
        // response. The removed notifications therefore stay unanswered, which keeps the app running, until
        // they leave the delivered list or two seconds pass.
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: Array(unanswered))
        for _ in 0 ..< 20 where !unanswered.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            if unanswered.isDisjoint(with: delivered) { break }
        }
        unanswered.removeAll()
        isStarting = false
        quitWhenDone()
    }

    // UserNotifications does not say on which thread it calls its delegate, so the response is copied out and
    // handled on the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        completionHandler()
        Task { @MainActor in
            received(action: action, text: text, notification: identifier)
        }
    }

    private func received(action: String, text: String, notification identifier: String) {
        let title = switch action {
        case UNNotificationDefaultActionIdentifier: "Open"
        case UNNotificationDismissActionIdentifier: "Dismiss"
        default: Kind.title(ofAction: action) ?? action
        }
        unanswered.remove(identifier)
        report("Notification Sampler got \(title)", body: text)
        quitWhenDone()
    }

    /// Pushes a sidebar notification through the CLI.
    /// Pushes a notification through the CLI, with a button per `title=command` choice.
    private func report(_ title: String, body: String, choices: [String] = []) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["notification", "push", "--title", title, "--body", body] + choices.flatMap { ["--choice", $0] }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                self.pushFinished(status: status)
            }
        }
        do {
            try process.run()
            runningPushes += 1
        } catch {
            printError("could not run \(cli.path): \(error.localizedDescription)")
        }
    }

    private func pushFinished(status: Int32) {
        if status != 0 {
            printError("\(cli.path) notification push exited with status \(status)")
        }
        runningPushes -= 1
        quitWhenDone()
    }

    private func quitWhenDone() {
        guard !isStarting, unanswered.isEmpty, runningPushes == 0 else { return }
        NSApplication.shared.terminate(nil)
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("NotificationSampler: \(message)\n".utf8))
}

let usage = """
    usage: NotificationSampler <aerospace-sidebar CLI path> <timeout seconds> <kind>…
    kinds: \(Kind.allCases.map(\.rawValue).joined(separator: ", "))
    """
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
    printError("missing arguments\n\(usage)")
    exit(EX_USAGE)
}
guard FileManager.default.isExecutableFile(atPath: arguments[0]), arguments[0].hasPrefix("/") else {
    printError("\(arguments[0]) is not an absolute path to an executable\n\(usage)")
    exit(EX_USAGE)
}
guard let seconds = Double(arguments[1]), seconds.isFinite, seconds > 0 else {
    printError("\(arguments[1]) is not a positive number of seconds\n\(usage)")
    exit(EX_USAGE)
}
var kinds: [Kind] = []
for name in arguments.dropFirst(2) {
    guard let kind = Kind(rawValue: name) else {
        printError("unknown kind \(name)\n\(usage)")
        exit(EX_USAGE)
    }
    kinds.append(kind)
}

let sampler = Sampler(cli: URL(filePath: arguments[0]), timeout: .seconds(seconds), kinds: kinds)
sampler.start()
NSApplication.shared.run()
