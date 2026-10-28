`aerospace-sidebar` is a permanent notification sidebar for macOS users of the [AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling window manager. It takes over the right or left edge of the main display, replaces macOS notification banners with a list that stays until you deal with it, and lets scripts, agents and web pages push their own notifications with click actions.

# What It Does

- **Reserved screen strip**: a panel on the right or left edge of the main display that tiled windows never cover, on every Space and over full-screen apps.
- **macOS notifications, kept**: native banners are hidden and listed in the sidebar instead, so nothing disappears after five seconds.
- **Alert buttons in the sidebar**: a persistent alert with one or two buttons is hidden and listed with them on its card, such as Allow… on macOS's "Privacy & Security" alert, Don’t Allow and Allow, or Reply. Pressing one acts on the alert, and Reply brings the alert back on screen with its text field. Clicking the card does what clicking the alert does, and dismissing the card closes the alert.
- **Other interactive notifications left alone**: banners with buttons, alerts with three or more choices, and notifications showing a text field or another control, stay on screen as macOS shows them, and are also listed. With the sidebar on the right, macOS's notifications move left of it so it does not cover them. Turn this off in Settings to list them without their buttons instead. Alerts without buttons are listed like any other notification.
- **Push from anywhere**: the `aerospace-sidebar` command and `aerospace-sidebar://` links add notifications.
- **Click actions**: a notification can run a shell command or open a link when clicked.
- **Severity**: `low`, `normal`, `high` and `critical` notifications sort and look different, with critical ones always on top.
- **Rules**: regular expressions on a notification's sender, title, subtitle or body raise or lower its severity, or hide it, such as every Slack message as `high`. Saving rules also applies them to the notifications already listed, which move, stack or go accordingly; removing a rule gives them back the severity they arrived with. Settings › Rules shows which recent notifications each rule matches, including ones you dismissed and ones a rule hid.
- **App icons**: a pushed notification can name an app icon from [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font), such as `slack` or `google_chrome`, shown before its sender.
- **Repeats stacked**: a notification identical to one already listed joins it as a single card with a count, instead of filling the list with copies.
- **History**: the list survives quitting and relaunching; notifications are kept for 24 hours by default.
- **Missed notifications**: with Full Disk Access, notifications that never showed a banner are listed too: those during Focus or Do Not Disturb, those macOS drops when several arrive at once, and those delivered while the sidebar was not running.
- **Guided setup**: Settings opens the Accessibility and Full Disk Access settings next to a panel from which you drag the app into the list, adds the app to Login Items and adds the sidebar's settings to your AeroSpace config, one button each.

# How It Works

- AeroSpace leaves an empty strip on one edge of the main display, and the sidebar fills it.
- When an app posts a macOS notification, its banner vanishes and the notification appears at the top of its severity group in the sidebar.
- `aerospace-sidebar notification push` sends a notification from the terminal, starting the sidebar first when it is not running.
- A notification with the same sender, text, severity, icon and click action as a listed one is stacked onto it: the card moves up as the newest, shows `×2`, `×3`, … next to its time, and gets layered edges below it. Clicking or dismissing a stack removes all of its copies.
- Clicking a notification runs its action, or switches to the app that posted it, and removes it. Option-click, or the × button that appears on hover, removes it without acting.
- Hovering a notification shows what a click will do, including the full command.

# How it Really Works

- The sidebar's side and width come from its own settings (`[sidebar]` in `config.toml`). AeroSpace has to leave the same strip free: the `monitor.main` entry of `gaps.outer.<side>` minus that side's fallback value is the reserved width. With `outer.right = [{ monitor.main = 305 }, 5]`, a 300-point sidebar on the right keeps AeroSpace's 5-point gap to your windows. The sidebar keeps AeroSpace's config in step: at launch, whenever the AeroSpace config file changes, and whenever you change the side or width (in Settings or in `config.toml`), it rewrites its block in that file when the strip is missing or wrong, then reloads AeroSpace. The block sits in the `[gaps]` table between `# >>> aerospace-sidebar` and `# <<< aerospace-sidebar <<<` and owns `outer.left` and `outer.right`; the sidebar keeps the other monitors' entries and fallback values in it. A config written by a generator is repaired after each regeneration; to avoid the round trip, keep the block in the generator's source and carry it over from the previous output.
- Notifications are read through the macOS Accessibility API from the Notification Center process, which is why the app needs the Accessibility permission. Several alerts from one app that macOS collapses into a stack are expanded and listed one by one. While Notification Center's own panel is open, the sidebar leaves it alone. A notification is listed once even when it stays on screen across a restart of the sidebar, so a dismissed card does not come back.
- Banners are hidden by moving Notification Center's banner window off-screen and closing the banner. When that window also holds a notification left to macOS, it stays on screen, moved left by the sidebar's width when the sidebar is on the right, and a banner arriving meanwhile shows there for about a second until it closes. Quitting the sidebar moves the window back.
- An alert listed with its buttons stays open off-screen until you act on its card, so its buttons still work later. Quitting the sidebar brings it back on screen, and the card restored at the next launch takes it over again.
- Focus and Do Not Disturb suppress banners entirely. With Full Disk Access, the sidebar also reads the database in which macOS records every delivered notification (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, read-only) and lists the ones no banner showed. That database is private to macOS and may change with a macOS update; the sidebar then logs the error and keeps intercepting banners.
- `aerospace-sidebar notification push` talks to the app over a socket in your private temporary directory (`$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`) that only your user account can open. This is the only way to attach a `--run` command.
- `aerospace-sidebar://` links can be opened by any app, and by web pages after your browser asks for permission. They therefore never carry commands, and their `open` links must be `http` or `https`. A notification from a link is labeled with the app that opened it when macOS reports one, otherwise `URL`.
- App icons come from sketchybar-app-font (CC0), which ships inside the app, so nothing needs installing. An icon id is written `slack` or `:slack:`; one the font does not have leaves the notification without an icon and adds a small `Invalid icon: <id>` note under its text. Several apps can share one icon, such as `mail` for Mail, Spark and HEY. [`icon_map.json`](Resources/sketchybar-app-font/icon_map.json) lists every id with the apps it stands for.
- `--run` commands run with your login shell (`$SHELL -lc`) in the directory where you ran `aerospace-sidebar`. Their output is discarded.
- The list is saved to `~/Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json` on every change and holds at most 200 notifications by default; a stack counts as one. Every notification received is also kept in `received.json` beside it, under the same limits, after you dismiss it or a rule hides it, so Settings › Rules can test rules against it.
- The list draws its own thin scroll indicator in the margin on the sidebar's screen edge instead of the system scroll bar, so the cards keep their width when a mouse is attached. It appears while scrolling or when the pointer is over that margin, and can be dragged.
- Settings live in `${XDG_CONFIG_HOME:-~/.config}/aerospace-sidebar/config.toml`. Edits to that file apply immediately; saving from the Settings window rewrites it and drops comments.
- Each edit keeps the rest of your AeroSpace config and its comments, saves the previous version next to it as `aerospace.toml.bak`, checks the result with `aerospace reload-config --dry-run`, and puts the previous version back if AeroSpace rejects it. While AeroSpace is not running the edit is kept unchecked, and AeroSpace reads it when it starts. Settings › Sidebar shows the AeroSpace config file and the result, **Update Config** runs the same edit on demand, and **Write Again** rewrites the block and reloads AeroSpace even when the config already matches.
- Success messages go to stdout and errors to stderr. Exit codes: `0` success, `1` notification rejected or undeliverable, `64` invalid arguments, `74` output could not be written. With `AGENT=1`, output is compact: `OK: pushed`, or `ERR: <code>: <detail>`.

# Installation

Download the app and the command for macOS (Apple Silicon) from the [latest release](https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest), replacing `X.X.X` with the version shown on that page.

```bash
mkdir -p ~/Applications ~/.local/bin
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/AerospaceSidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/Applications
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/aerospace-sidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/.local/bin
```

# Setup

Open `~/Applications/AerospaceSidebar.app`, click the gear button at the top of the sidebar, choose the sidebar's side and width under **Sidebar** if the default (300 points on the right) does not suit you, check that **Sidebar** shows the AeroSpace config as updated, and work through **Permissions**. **Permissions** explains what each permission is for and has a **Remove** button that takes AerospaceSidebar off that list in System Settings. Each step can also be done by hand:

- [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide) - Reserves the strip. The sidebar adds its gap block and a floating rule to an existing AeroSpace config at launch; it never creates the file. **Copy Settings** copies them for adding by hand, after which you run `aerospace reload-config`:
  ```toml
  [gaps]
  # >>> aerospace-sidebar: managed block, rewritten when the sidebar's side or width changes >>>
  outer.left = 5
  outer.right = [{ monitor.main = 305 }, 5]   # sidebar width + the fallback gap
  # <<< aerospace-sidebar <<<

  [[on-window-detected]]
  if = 'test %{app-bundle-id} = com.alexgorbatchev.aerospace-sidebar'
  run = 'layout floating'
  ```
  Bind fullscreen as `fullscreen`, not `fullscreen --no-outer-gaps`, or fullscreen windows cover the sidebar.
- [Accessibility permission](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac) - Needed to read and hide macOS notifications. **Open Accessibility** opens System Settings › Privacy & Security › Accessibility with a panel below it; drag AerospaceSidebar from the panel into the list, or enable it if it is already there. Release builds are not signed with a developer certificate, so after each update click **Remove** (or remove AerospaceSidebar from that list) and grant it again.
- Full Disk Access (optional) - Needed to list notifications that showed no banner. **Open Full Disk Access** opens System Settings › Privacy & Security › Full Disk Access the same way; drag AerospaceSidebar into the list, or enable it if macOS already lists it. Like Accessibility, release builds need it granted again after each update.
- Login item - **Add to Login Items** opens the sidebar when you log in. It needs the app in `~/Applications` or `/Applications`.
- Quit other apps that restyle or hide notification banners, such as NotifyMeHow, so only one app handles them.

# Quick Start

```bash
# Show a notification with the Ghostty icon
aerospace-sidebar notification push --icon ghostty --title "Tests passed" --body "142 passed in 31s"

# A critical notification that reopens the CI run when clicked
aerospace-sidebar notification push --severity critical --title "Deploy failed" --run "open https://ci.example.com/runs/42"

# A link that shows a notification when opened, for web pages, Shortcuts or Raycast
aerospace-sidebar notification url --title "Backup finished" --severity low

# Install the agent skill
aerospace-sidebar skill
```

Sample Output:
```
[OK] Notification sent to the sidebar.
[OK] Notification sent to the sidebar.
aerospace-sidebar://notification/push?title=Backup%20finished&severity=low
Install the aerospace-sidebar skill using the Skills CLI:

  npx skills add alexgorbatchev/aerospace-sidebar --skill aerospace-sidebar

Skill:

  https://github.com/alexgorbatchev/aerospace-sidebar/tree/main/skills/aerospace-sidebar
```

# Options & Flags

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--help` | `-h` | `false` | Print help for the command |

`aerospace-sidebar notification push`

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--title <title>` | | empty | Bold first line, up to 256 characters |
| `--subtitle <subtitle>` | | empty | Line under the title, up to 256 characters |
| `--body <body>` | | empty | Main text, up to 4096 characters |
| `--severity <severity>` | | `normal` | `low`, `normal`, `high` or `critical`; more severe notifications are listed first |
| `--icon <id>` | | none | sketchybar-app-font icon id such as `slack` or `:slack:`, up to 64 characters |
| `--open <url>` | | none | URL to open when the notification is clicked |
| `--run <command>` | | none | Shell command to run in the current directory when the notification is clicked |

A notification needs `--title` or `--body`. `--open` and `--run` cannot be combined.

`aerospace-sidebar notification url`

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--title <title>` | | empty | Bold first line, up to 256 characters |
| `--subtitle <subtitle>` | | empty | Line under the title, up to 256 characters |
| `--body <body>` | | empty | Main text, up to 4096 characters |
| `--severity <severity>` | | `normal` | `low`, `normal`, `high` or `critical` |
| `--icon <id>` | | none | sketchybar-app-font icon id such as `slack` or `:slack:` |
| `--open <url>` | | none | `http` or `https` URL to open when the notification is clicked |

# Configuration

`~/.config/aerospace-sidebar/config.toml` (or under `$XDG_CONFIG_HOME`), also editable in Settings under Sidebar, Notifications, History and Font:

```toml
[sidebar]
side = "right"                           # "right" or "left" edge of the main display
width = 300                              # 150 to 1000 points; changing side or width updates and reloads the AeroSpace config

[notifications]
replace_system = true                    # hide macOS banners and list them in the sidebar
actionable_left_to_macos = true          # leave notifications with buttons the sidebar cannot offer (banners with buttons, text fields) to macOS
apps_left_to_macos = ["zoom.us"]         # app names whose notifications stay on screen

[history]
retention_hours = 24                     # 1 to 720
max_count = 200                          # 10 to 2000

[font]
name = ""                                # font family (Settings › Appearance › Choose… picks one); empty uses the system font
size = 13                                # 8 to 32; every text size in the sidebar and Settings scales with it

[[rules]]                                # any number; the first rule that matches a notification applies, also to listed ones
source = "^Slack$"                       # source, title, subtitle, body: case-insensitive regular expressions
                                         # found anywhere in that text; omitted ones match anything, one is required
action = "high"                          # "hide" drops the notification; "low", "normal", "high" or "critical" sets its severity
```

A missing file or key uses the defaults shown. An invalid file keeps the previous settings, and Settings shows the error. A font that is not installed falls back to the system font.

# URL Scheme

Opening `aerospace-sidebar://notification/push` with any of the query parameters `title`, `subtitle`, `body`, `severity`, `icon` and `open` shows a notification, for example from a web page link, the Shortcuts Open URL action, or `open -g "<url>"` in a script. Values are percent-encoded; `aerospace-sidebar notification url` builds the link for you.

```html
<a href="aerospace-sidebar://notification/push?title=Build%20done&severity=high&open=https%3A%2F%2Fci.example.com">Notify me</a>
```

# License

[MIT License](LICENSE) (c) 2026 Alex Gorbatchev
