import AppKit
import SwiftUI

/// The apps that post notifications: which app a name NotificationCenter shows belongs to, and its icon.
///
/// NotificationCenter draws the posting app's own icon, found through its bundle identifier; a banner's
/// accessibility tree names only the app, so `bundleIdentifier(named:)` maps the name back to an app.
/// Lookups are cached for the process lifetime, misses included, so a name costs at most one scan of the
/// application directories.
@MainActor
public final class InstalledApps {
    public static let shared = InstalledApps()

    /// How deep below an application directory apps are looked for: `Utilities` and vendor folders such
    /// as `/Applications/Setapp` hold apps one level down.
    static let searchDepth = 2

    private let applicationDirectories: [URL]
    private let runningApplications: @MainActor () -> [(name: String?, bundleIdentifier: String?)]
    private let applicationURL: @MainActor (String) -> URL?
    private var bundleIdentifiers: [String: String?] = [:]
    private var icons: [String: NSImage?] = [:]

    /// - Parameters:
    ///   - applicationDirectories: Where installed apps are looked for when no running app has the name.
    ///   - runningApplications: The running apps' names and bundle identifiers.
    ///   - applicationURL: Where the app with a bundle identifier is installed.
    init(
        applicationDirectories: [URL] = FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask),
        runningApplications: @escaping @MainActor () -> [(name: String?, bundleIdentifier: String?)] = {
            NSWorkspace.shared.runningApplications.map { ($0.localizedName, $0.bundleIdentifier) }
        },
        applicationURL: @escaping @MainActor (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) {
        self.applicationDirectories = applicationDirectories
        self.runningApplications = runningApplications
        self.applicationURL = applicationURL
    }

    /// The bundle identifier of the app NotificationCenter shows as `name`: a running app first, as the
    /// app that posted is usually running, else an installed one; nil when neither has the name.
    public func bundleIdentifier(named name: String) -> String? {
        if let running = runningApplications().first(where: { $0.name == name })?.bundleIdentifier {
            return running
        }
        if let cached = bundleIdentifiers[name] { return cached }
        let found = installedBundleIdentifier(named: name)
        bundleIdentifiers[name] = found
        return found
    }

    /// The icon of the installed app with `bundleIdentifier`, as NotificationCenter draws it; nil when no
    /// app has the identifier.
    public func icon(bundleIdentifier: String) -> NSImage? {
        if let cached = icons[bundleIdentifier] { return cached }
        let icon = applicationURL(bundleIdentifier).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleIdentifier] = icon
        return icon
    }

    /// The name of the installed app with `bundleIdentifier`, as NotificationCenter shows it.
    public static func name(bundleIdentifier: String) -> String? {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName {
            return name
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).flatMap { names(ofAppAt: $0).first }
    }

    private func installedBundleIdentifier(named name: String) -> String? {
        let fileManager = FileManager.default
        for directory in applicationDirectories {
            guard let apps = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in apps {
                if apps.level >= Self.searchDepth { apps.skipDescendants() }
                guard url.pathExtension == "app", Self.names(ofAppAt: url).contains(name) else { continue }
                if let identifier = Bundle(url: url)?.bundleIdentifier { return identifier }
            }
        }
        return nil
    }

    /// The names an app goes by, localized: the ones in its Info.plist, then the one Finder shows.
    private static func names(ofAppAt url: URL) -> [String] {
        let bundle = Bundle(url: url)
        let finderName = FileManager.default.displayName(atPath: url.path)
        return [
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
            finderName.hasSuffix(".app") ? String(finderName.dropLast(4)) : finderName,
        ].compactMap { $0 }
    }
}

extension EnvironmentValues {
    /// The icon of the installed app with a bundle identifier, for cards of notifications from apps.
    @Entry var appIcon: @MainActor (String) -> NSImage? = { InstalledApps.shared.icon(bundleIdentifier: $0) }
}
