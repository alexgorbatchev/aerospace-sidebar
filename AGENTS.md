---
created_on: 2026-10-26 11:54
last_modified: 2026-10-26 15:21
status: current
---

# aerospace-sidebar

A permanent, always-visible sidebar on the macOS main display that tiled windows never cover. AeroSpace reserves the screen strip; this project supplies the window that occupies it. The sidebar replaces macOS notification banners and NotifyMeHow: it intercepts native notifications and lists them, together with notifications pushed by the `aerospace-sidebar` CLI and `aerospace-sidebar://` URLs.

## Commands

Swift package (`Package.swift`) driven by `justfile`:

- Build and relaunch the app bundle: `just run`. It quits NotifyMeHow first (`just quit-notifymehow`) so only one app hides banners. `just stop` quits the sidebar gracefully; `just bundle` only builds `.build/AerospaceSidebar.app` and `bin/aerospace-sidebar`.
- CLI: `just cli <args>`, agent mode `just cli-ai <args>` (the CLI's `run`/`run-ai` equivalents; `run` launches the app)
- Push sample notifications through every path (CLI, URL scheme, native `osascript`), one per severity: `just test-notifications`
- Tests: `just test`
- Coverage gate: `just coverage`
- Re-prompt for Accessibility: `just reset-permissions`
- Release archives into `dist/` (what the release workflow runs): `just release-archives <version>`. Set `AEROSPACE_SIDEBAR_SIGNING_IDENTITY=-` for an ad-hoc build like CI; note that it replaces `.build/AerospaceSidebar.app`, so run `just run` afterwards to restore the Developer ID build.

CI (`.github/workflows/ci.yml`) runs `just coverage` on `macos-26` for pushes to `main` and pull requests. `.github/workflows/release.yml` runs on `v*` tags: coverage gate, `just release-archives`, then `gh release create` with `AerospaceSidebar_<version>_darwin_arm64.tar.gz`, `aerospace-sidebar_<version>_darwin_arm64.tar.gz` and `checksums.txt`. CI has no Developer ID, so release builds are ad-hoc signed and users re-grant Accessibility after each update. The README's installation section depends on these asset names.

`just coverage` runs `swift test --enable-code-coverage`, prints `llvm-cov report` for the test binary, and fails when line or function coverage over `Sources/` drops below 90% or when any `Sources/**/*.swift` file is missing from the report. It excludes `.build/` and `Tests/`. Test targets depend on both executables so each `main.swift` is compiled into the report; they stay unexecuted, so keep them minimal.

Always launch the bundle, not `swift run`. The bundle supplies the bundle id, `LSUIElement` (which AeroSpace relies on, see Architecture) and the `aerospace-sidebar` URL scheme. `just bundle` signs it with the Developer ID identity in `AEROSPACE_SIDEBAR_SIGNING_IDENTITY` (default `Developer ID Application: Alex Gorb (4XCZD8P4CJ)`); a stable identity keeps the Accessibility permission across rebuilds, while ad-hoc signing loses it every build.

Useful AeroSpace commands while developing:

- List monitors and their names (used in gap patterns): `aerospace list-monitors`
- Apply config changes: `aerospace reload-config`
- Regenerate the live AeroSpace config from dotfiles: `bash ~/.dotfiles/mac-apps/aerospace/select-config.sh <home|mobile|work>` (shell alias `aerospace-select`; restarts AeroSpace)

## Environment

- macOS 26.6.2, Xcode 26.6, Swift 6.3.3
- AeroSpace 0.21.3-Beta (CLI and server)
- Hammerspoon and SketchyBar are not installed.
- Monitors on the `work` profile, from `aerospace list-monitors`: `LG UltraFine`, `EM160TP-A`, `Built-in Retina Display`.

## Layout

- `Sources/SidebarProtocol/`: shared by app and CLI. `SidebarRequest` (URL routes), `NotificationPayload`, `NotificationSeverity`, `NotificationAction`, `ControlRequest`/`ControlResponse` and `UnixSocket` (control socket I/O).
- `Sources/SidebarKit/`: all app logic.
  - Window: `AeroSpaceConfig` (reads the reserved width from AeroSpace's TOML), `SidebarLayout`, `SidebarPanelController`, `SidebarView` (notification list), `SidebarAppDelegate` (wiring, URL handling).
  - Notifications: `SidebarModel` (ordered list, click actions), `WorkspaceActionPerformer`, `ControlServer` (socket server).
  - Settings: `SidebarSettings` (`config.toml` schema), `SettingsFile`, `SettingsStore` (live reload), `SettingsEditor` (Save/Cancel draft), `OnboardingModel` (Setup tab), `AeroSpaceConfigEditor`/`AeroSpaceSetup` (in-place AeroSpace config edits), `LoginItem` (`SMAppService.mainApp`), `SettingsWindowController` with `SettingsPanes`/`SettingsGrid`.
  - Interception: `NotificationBanners` (reads and closes banners through `AccessibilityElement`), `SystemNotificationInterceptor` (hide, dedupe, report), `NotificationCenterMonitor` (permission polling, AX observer, relaunch handling; `SystemAccessibility`/`AXElement` are the real AX adapters).
- `Sources/SidebarCLI/`: CLI commands (`Commands.swift`), tree help (`CommandTree`), `CLIContext` (output mode, `~` path folding, injected I/O), `SocketNotificationSender`.
- `Sources/AerospaceSidebar/main.swift`, `Sources/AerospaceSidebarCLI/main.swift`: entry points only; keep logic out of them.
- `Resources/Info.plist`: bundle id `com.alexgorbatchev.aerospace-sidebar`, `LSUIElement = true`, `CFBundleURLTypes` for `aerospace-sidebar`.
- `skills/aerospace-sidebar/SKILL.md`: agent skill for the CLI, printed by `aerospace-sidebar skill` as `alexgorbatchev/aerospace-sidebar` on branch `main`.
- `Tests/<Target>Tests/`: Swift Testing suites; `FakeElement`/`FakePlatform` in `SidebarKitTests/TestSupport.swift` stand in for the Accessibility API.

## Dependencies

- `TOMLDecoder` (dduan/TOMLDecoder): implements TOML 1.1, the version AeroSpace parses. Its `singleValueContainer()` decodes scalars only; decode arrays with `unkeyedContainer()` and tables with a keyed container or a nested `Decodable`.
- `swift-argument-parser`: CLI parsing. It lists only direct subcommands, so groups hide children (`shouldDisplay: false`) and render the full tree as their `discussion` (`CommandTree`). Its help wrapper breaks a line that fills the whole width, so tree lines are trimmed to width − 1, and help is rendered with `fullMessage(for:columns:)` at the same width. Help requests surface as its internal `CommandError`, not `CleanExit`; `ArgumentParserToolInfo` is not an exported product, so tests decode `--experimental-dump-help` JSON with local types.
- `swift-toml` (mattt/swift-toml, `import TOML`): reads and writes the app's own `config.toml` (TOML 1.0, Codable both ways). TOMLDecoder stays for AeroSpace's TOML 1.1 config. Both libraries export a type named `TOMLDecoder`; import only one per file.
- `ViewInspector` (tests only): drives SwiftUI controls in tests. SwiftUI's `NSHostingView` exposes no accessibility children in a test process, so `accessibilityPerformPress()` cannot reach SwiftUI buttons.

## Architecture

macOS has no public API for reserving screen space (no AppBar or strut equivalent). Only the menu bar and Dock shrink `NSScreen.visibleFrame`, which native zoom and Sequoia-style tiling use. The design therefore splits responsibilities:

1. **Space reservation: AeroSpace per-monitor outer gap.** Tiled windows on the target monitor stop short of the strip:
   ```toml
   [gaps]
   outer.right = [{ monitor."<pattern>" = <sidebar-width + 5> }, 5]   # 5 = existing default on other monitors
   ```
   Monitor patterns use the same syntax as `workspace-to-monitor-force-assignment`: `main`, `secondary`, a 1-based left-to-right index, or a case-insensitive regex substring of the monitor name. The last array element is the fallback.

   The sidebar targets `monitor.main` (System Settings → Displays → "Use as: Main display") on the right edge. `base.toml` sets `outer.right = [{ monitor.main = 305 }, 5]`. That gap is the single source of the width: `AeroSpaceConfig` loads the config AeroSpace loads (`~/.aerospace.toml` or `${XDG_CONFIG_HOME:-~/.config}/aerospace/aerospace.toml`, error if both exist) and sizes the sidebar to the `main` entry minus the trailing fallback (305 − 5 = 300), so the regular 5pt gap stays between the sidebar and tiled windows. Never hardcode the width elsewhere. When the config cannot be read, the app logs an error (`log show --predicate 'subsystem == "com.alexgorbatchev.aerospace-sidebar"'`) and uses `SidebarLayout.fallbackWidth`. The width is re-read on every pin (launch and screen changes), not on AeroSpace config reloads; restart the sidebar (`just run`) after changing the gap.
2. **Sidebar window: self-positioning, always-on-top panel.** AeroSpace cannot position floating windows from config, so the sidebar sets its own frame to the reserved strip on `NSScreen.screens.first` (the menu-bar screen, which is AeroSpace's `main`). It uses `visibleFrame`, the same rect AeroSpace pads with outer gaps. Window behavior:
   - Borderless `NSPanel` subclass (`SidebarPanel`) with `.nonactivatingPanel`, `level = .statusBar`
   - `SidebarPanel` overrides `canBecomeKey` to `true`. Borderless windows refuse key status by default, so without the override clicks never focus the sidebar and keyboard input (text fields, shortcuts) never reaches it. `.nonactivatingPanel` lets it become key without activating the app. Keep both.
   - "Quit Sidebar" button (⌘Q while the panel is key) calls `NSApplication.terminate`; `LSUIElement` apps have no menu bar, so this is the only in-app quit.
   - `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`
   - `hidesOnDeactivate = false`
   - `NSVisualEffectView` background with `state = .active`, because the app never activates
   - Re-pin the frame on screen-configuration changes (`NSApplication.didChangeScreenParametersNotification`); hide the panel when no screen exists.
3. **Keep AeroSpace from managing the sidebar.** AeroSpace 0.21 (`isWindowHeuristic` in `AxUiElementWindowType.swift`) classifies a window of an `.accessory` app with no close button as a popup. Popups are never tiled, never assigned to a workspace, never hidden on workspace switches, and never trigger `on-window-detected`. Keep the panel borderless and `LSUIElement = true`. A floated window would belong to one workspace and be moved offscreen when that workspace is hidden. `base.toml` still floats the bundle id as a fallback:
   ```toml
   [[on-window-detected]]
   if = 'test %{app-bundle-id} = com.alexgorbatchev.aerospace-sidebar'
   run = 'layout floating'
   ```

4. **Notification interception: Accessibility API on NotificationCenter.** `NotificationCenterMonitor` observes `com.apple.notificationcenterui` (`kAXWindowCreated`, `kAXValueChanged`, `kAXLayoutChanged`) and re-attaches when it relaunches. Observed macOS 26 behavior the code relies on:
   - Banners have subrole `AXNotificationCenterBanner`, `…BannerWindow`, `…Alert` or `…Notification`; the banner's `AXDescription` starts with the app name; text elements carry `AXIdentifier` `title`, `subtitle` or `body`.
   - A plain banner exposes exactly the actions `AXPress`, `Show Details`, `Show` and `Close`. `NotificationBanners.needsInteraction` treats `AXNotificationCenterAlert` subroles, any other action, and controls other than a close button (text fields, buttons, pop-ups) as interactive. Interactive notifications stay native (their window is never hidden, and is moved back if an earlier hide left it off-screen) and are listed with `shownByMacOS`. When unsure, leave a notification native: losing its buttons is worse than seeing a banner.
   - Position changes on the banner element are ignored and its close action only works after the ~1.3 s slide-in, so the hosting window is moved to (-5000, -5000) and the banner is closed. Windows left off-screen are moved back to the origin on attach and on quit, so always quit with `just stop` (Apple Event quit) rather than `kill`, which skips `applicationWillTerminate`.
   - NotificationCenter reports a banner several times; banners are deduplicated by `AXIdentifier` and by identical content within 10 s.
   - Focus/Do Not Disturb suppresses banners before the sidebar can see them.
   NotifyMeHow (GPL-3.0) established these facts; do not copy its source into this MIT project.
5. **Pushed notifications: two entry points with different trust.**
   - `aerospace-sidebar://notification/push?title=&subtitle=&body=&severity=&open=` (handled in `SidebarAppDelegate.application(_:open:)`). Any process, and any web page after the browser's confirmation prompt, can open it. Never let URLs carry commands; `open` accepts only `http`/`https`. The sender app (Apple Event `keySenderPIDAttr`) labels the notification, else `URL`.
   - Control socket `$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`: mode 0600 in the per-user temp directory, peer uid checked with `getpeereid`, one JSON `ControlRequest` per connection. Only this path may carry `run` actions. Set `SO_NOSIGPIPE` on every socket (`UnixSocket.disableSIGPIPE`); a client that disconnects early otherwise kills the app.
   - Click actions: `open` (LaunchServices), `run` (`$SHELL -lc` in the CLI's working directory, output discarded), `activateApp` for intercepted notifications. Hovering a card shows `clickDescription`, including the full command.
   - Severity `low` < `normal` < `high` < `critical`: the list sorts by severity, then newest first, and drops the least severe, oldest entries beyond 200. `low` is dimmed, `high` orange, `critical` red.
   - Stacking: `SidebarModel.add` folds a notification into a listed one with the same content (`hasSameContent`: source, title, subtitle, body, severity, action, `shownByMacOS`). The entry keeps its id, takes the newer `receivedAt`, adds `occurrences`, and is re-inserted as the newest. `SidebarView` keys cards by id and `occurrences`, so a restack fades the old card out and inserts a new one instead of sliding it across the translucent cards between. This is separate from the interceptor's 10 s dedupe, which drops NotificationCenter's repeated reports of one banner; stacking counts real repeats.
   - Scrolling: the list hides the system scroller (`.scrollIndicators(.never)`; `.hidden` still shows legacy scrollers when a mouse is attached) and draws `ScrollIndicator` in the trailing margin from `onScrollGeometryChange`, dragging through `ScrollPosition`. Legacy scrollers draw a track and take their width from the cards.
   - History: `SidebarModel` saves the list through `NotificationStore` on every change (`FileNotificationStore`: `~/Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json`) and drops notifications older than 24 hours on load and every minute, so a relaunch restores the list. Tests pass an in-memory store; `SidebarModel` has no default store so tests cannot write the real file.

6. **Settings.** `${XDG_CONFIG_HOME:-~/.config}/aerospace-sidebar/config.toml` holds `[notifications] replace_system, apps_left_to_macos` and `[history] retention_hours (1…720), max_count (10…2000)`. `SettingsStore` watches the directory (atomic replacements included) and applies valid edits live; an invalid file keeps the last valid settings and surfaces `loadError`. Launch at login is never stored there: macOS owns that state, and a stored copy would re-enable a login item the user turned off in System Settings.
   - The Settings window copies the layout of simple-ptt's settings window (`src/settings_window` in github.com/alexgorbatchev/simple-ptt): Preference-style toolbar tabs (Setup, General) from `NSTabViewController`, a grid with right-aligned `Label:` cells, bold 13pt section headers with 12pt top padding, 11pt secondary hints under controls, 8pt spacing, 20pt margins, checkboxes rather than switches, 80pt number fields, and a separator + status line + Cancel/Save bar. Setup steps start with a status circle (green `checkmark.circle.fill` when done, empty `circle` otherwise) followed by the step's button, or by text naming the finished state once done. Edits stay in `SettingsEditor.draft` until Save; Cancel and closing the window discard them.
   - Unlike simple-ptt, which switches to the `.regular` activation policy while Settings is open, Settings is a non-activating `NSPanel` ordered in front with `orderFrontRegardless()`. Switching the policy would make AeroSpace re-classify the sidebar panel as a window (see item 3), and `NSApp.activate()` from a background app is only a request since macOS 14. Pop-up buttons do not open in a key window of an inactive app, so prefer controls other than `NSPopUpButton`/`Picker(.menu)` in Settings.
   - Panes have a fixed width (`SettingsMetrics.paneWidth`) so hints wrap instead of widening the window; their hosting controllers use `sizingOptions = [.intrinsicContentSize]` (`[]` and `.minSize` report a zero fitting size), and every pane gets the largest pane's size so switching tabs never resizes the window.
   - Update AeroSpace Config: refuses generated files (a `# … generated`/`do not edit` comment in the first five lines) and layouts it cannot edit safely, offering Copy Settings instead. It never creates a missing AeroSpace config, because a config file without `[mode.main.binding]` drops AeroSpace's default key bindings.

### Coverage limits

- AeroSpace `fullscreen` respects outer gaps unless invoked with `--no-outer-gaps`.
- Floating windows are outside the tiling tree; gaps do not apply. Native green-button zoom sizes them to `visibleFrame` and they extend under the sidebar.
- macOS native fullscreen (`macos-native-fullscreen` or the green button) opens a separate Space and ignores gaps. `.fullScreenAuxiliary` lets the sidebar draw over it; it overlaps rather than displaces the app.

## Open design questions

- Sidebar content beyond notifications.


## Gotchas

- `~/.config/aerospace/aerospace.toml` is generated. Never edit it directly; edit `~/.dotfiles/mac-apps/aerospace/base.toml` or `~/.dotfiles/mac-apps/aerospace/configs/<profile>.toml`, then regenerate.
- The generator appends profile TOML sections after `base.toml`, and `[gaps]` already lives in `base.toml`. A `[gaps]` table in a profile file produces a duplicate-table TOML error. Put the per-monitor gap in `base.toml` (the pattern fallback keeps other monitors unchanged) or change the generator.
- `base.toml` binds `alt-f = 'fullscreen'` (all profiles). Do not add `--no-outer-gaps`; it makes fullscreen windows cover the sidebar. In the generated file this binding appears below the `# --- Profile: <name> ---` marker because profile bindings are injected directly after `[mode.main.binding]`; it is not profile-specific.
- Monitor names differ between profiles. Patterns referenced in `configs/*.toml`: `^MAG321.*`, `DELL U3417W`, `DELL U3415W`, `^LG.*`, `EM160TP.*`, `Z1-7`, `built-in`, `secondary`. The gap uses `main` so it follows whichever display is main in every profile; name-based patterns would not.
- Tests create real `NSPanel`s and need a window-server session. Tests that use the real primary screen are disabled when `NSScreen.screens` is empty.
- Tests must never call `NotificationCenterMonitor.start()` with `SystemAccessibility` or bind `SidebarApp.controlSocketPath`: the first prompts for Accessibility and moves real NotificationCenter windows, the second collides with the running app. Inject `FakePlatform` and a `/tmp` socket path (short: `sockaddr_un` paths are limited to 104 bytes).
- Never block Swift's cooperative thread pool (socket `read`/`accept`/`write`, `Process.waitUntilExit`, `Task.detached` around blocking work). The pool is about as wide as the CPU count; on GitHub's 3-core runner, socket tests blocked every thread and the servers they waited on never ran, so CI hung with no output. Run blocking work through `onBlockingQueue` (`SidebarProtocol/BlockingQueue.swift`). `just test` and `just coverage` set `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (one pool thread) so such deadlocks reproduce locally; CI runs tests under `script` with step timeouts so a hang shows the last test that started.
- Killing `swift test` (Ctrl-C, `timeout`) leaves its `swiftpm-testing-helper` child running, and that process keeps the tests' real sidebar panels on screen. After interrupting a run, `pkill -f swiftpm-testing-helper`.
- Notification cards sit on `.regularMaterial` under their severity tint. The tints are translucent, so without the material a card sliding up over a removed one shows the removed card's text through it even though `zIndex` (from `drawingOrder`) draws it on top.
- ViewInspector evaluates a view's body when searched, not when `inspect()` is called, so assert pre-action text before tapping buttons that change it.
- `swiftc` 6.3 crashes on an immediately called `#require` result (`try #require(closure)(argument)`); bind the result first.

## Boundaries

- Always: automatically record explicit standing user instructions in this file without requiring a separate request to save them; update the relevant rule in place when it changes.
- Always: check AeroSpace and AppKit behavior against current official docs instead of relying on memory.
- Always: update `skills/aerospace-sidebar/SKILL.md` (and its `last_modified`) in the same change as any CLI command, argument, option, default, environment variable, output or side-effect change. `skillDocumentsEveryCommandAndOption` fails when a command or long option is undocumented.
- Always (code-based work): for code changes that alter executable behavior, add or update meaningful behavioral tests. Require at least 90% line coverage and 90% function coverage across the non-test source of each affected first-party package; include unexecuted source files and exclude `scripts/` directories. Document and configure the coverage command, source scope, metrics, and exclusions. Reproduce a blocking baseline failure on the untouched base and handle the smallest necessary prerequisite repair under the existing policy. Do not weaken coverage gates or make token test edits to satisfy this rule.
- Ask first: edits to files outside this repository, including `~/.dotfiles/mac-apps/aerospace/`; running `aerospace-select` (it restarts AeroSpace).
- Never: edit the generated `~/.config/aerospace/aerospace.toml`.
- Never: record task history, progress, handoffs, or dated user amendments in this file.
- Never: publish releases, tags, packages, or production deployments automatically without explicit user authorization. Pushing a `v*` tag publishes a GitHub release.

## References

- AeroSpace guide (gaps, monitor patterns, floating, callbacks): https://nikitabobko.github.io/AeroSpace/guide
- AeroSpace commands (`fullscreen`, `macos-native-fullscreen`, `layout`): https://nikitabobko.github.io/AeroSpace/commands
- AeroSpace config generator: `~/.dotfiles/mac-apps/aerospace/select-config.sh`
