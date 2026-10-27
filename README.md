`aerospace-sidebar` is a permanent notification sidebar for macOS users of the [AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling window manager. It takes over the right edge of the main display, replaces macOS notification banners with a list that stays until you deal with it, and lets scripts, agents and web pages push their own notifications with click actions.

# What It Does

- **Reserved screen strip**: a panel on the right edge of the main display that tiled windows never cover, on every Space and over full-screen apps.
- **macOS notifications, kept**: native banners are hidden and listed in the sidebar instead, so nothing disappears after five seconds.
- **Interactive notifications left alone**: notifications with buttons or reply fields stay on screen as macOS shows them, and are also listed. Turn this off in Settings to list them without their buttons instead. Alerts without buttons are listed like any other notification.
- **Push from anywhere**: the `aerospace-sidebar` command and `aerospace-sidebar://` links add notifications.
- **Click actions**: a notification can run a shell command or open a link when clicked.
- **Severity**: `low`, `normal`, `high` and `critical` notifications sort and look different, with critical ones always on top.
- **App icons**: a pushed notification can name an app icon from [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font), such as `slack` or `google_chrome`, shown before its sender.
- **Repeats stacked**: a notification identical to one already listed joins it as a single card with a count, instead of filling the list with copies.
- **History**: the list survives quitting and relaunching; notifications are kept for 24 hours by default.
- **Guided setup**: Settings grants the Accessibility permission, adds the app to Login Items and adds the sidebar's settings to your AeroSpace config, one button each.

# How It Works

- AeroSpace leaves an empty strip on the right edge of the main display, and the sidebar fills it.
- When an app posts a macOS notification, its banner vanishes and the notification appears at the top of its severity group in the sidebar.
- `aerospace-sidebar notification push` sends a notification from the terminal, starting the sidebar first when it is not running.
- A notification with the same sender, text, severity, icon and click action as a listed one is stacked onto it: the card moves up as the newest, shows `×2`, `×3`, … next to its time, and gets layered edges below it. Clicking or dismissing a stack removes all of its copies.
- Clicking a notification runs its action, or switches to the app that posted it, and removes it. The × button that appears on hover removes it without acting.
- Hovering a notification shows what a click will do, including the full command.

# How it Really Works

- The sidebar's width is read from AeroSpace's own config: the `monitor.main` entry of `gaps.outer.right` minus its fallback value. With `[{ monitor.main = 305 }, 5]`, the sidebar is 300 points wide and keeps AeroSpace's 5-point gap to your windows. The width is read at launch and when displays change.
- Notifications are read through the macOS Accessibility API from the Notification Center process, which is why the app needs the Accessibility permission. Focus and Do Not Disturb suppress notifications before the sidebar sees them.
- Banners are hidden by moving Notification Center's banner window off-screen and closing the banner. Quitting the sidebar moves that window back.
- `aerospace-sidebar notification push` talks to the app over a socket in your private temporary directory (`$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`) that only your user account can open. This is the only way to attach a `--run` command.
- `aerospace-sidebar://` links can be opened by any app, and by web pages after your browser asks for permission. They therefore never carry commands, and their `open` links must be `http` or `https`. A notification from a link is labeled with the app that opened it when macOS reports one, otherwise `URL`.
- App icons come from sketchybar-app-font (CC0), which ships inside the app, so nothing needs installing. An icon id is written `slack` or `:slack:`; one the font does not have leaves the notification without an icon and adds a small `Invalid icon: <id>` note under its text. Several apps can share one icon, such as `mail` for Mail, Spark and HEY. [`icon_map.json`](Resources/sketchybar-app-font/icon_map.json) lists every id with the apps it stands for.
- `--run` commands run with your login shell (`$SHELL -lc`) in the directory where you ran `aerospace-sidebar`. Their output is discarded.
- The list is saved to `~/Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json` on every change and holds at most 200 notifications by default; a stack counts as one.
- The list draws its own thin scroll indicator in the right margin instead of the system scroll bar, so the cards keep their width when a mouse is attached. It appears while scrolling or when the pointer is over that margin, and can be dragged.
- Settings live in `${XDG_CONFIG_HOME:-~/.config}/aerospace-sidebar/config.toml`. Edits to that file apply immediately; saving from the Settings window rewrites it and drops comments.
- Settings › Setup › Update AeroSpace Config edits your AeroSpace config in place, keeping its comments, saves the original next to it as `aerospace.toml.bak-<timestamp>`, checks the result with `aerospace reload-config --dry-run`, and puts the original back if AeroSpace rejects it. It leaves files marked as generated alone.
- Success messages go to stdout and errors to stderr. Exit codes: `0` success, `1` notification rejected or undeliverable, `64` invalid arguments, `74` output could not be written. With `AGENT=1`, output is compact: `OK: pushed`, or `ERR: <code>: <detail>`.

# Installation

Download the app and the command for macOS (Apple Silicon) from the [latest release](https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest), replacing `X.X.X` with the version shown on that page.

```bash
mkdir -p ~/Applications ~/.local/bin
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/AerospaceSidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/Applications
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/aerospace-sidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/.local/bin
```

# Setup

Open `~/Applications/AerospaceSidebar.app`, click the gear button at the top of the sidebar, and use the **Setup** tab. Each step can also be done by hand:

- [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide) - Reserves the strip. **Update AeroSpace Config** adds the gap and a floating rule; by hand, add them to `~/.config/aerospace/aerospace.toml` and run `aerospace reload-config`:
  ```toml
  [gaps]
  outer.right = [{ monitor.main = 305 }, 5]

  [[on-window-detected]]
  if = 'test %{app-bundle-id} = com.alexgorbatchev.aerospace-sidebar'
  run = 'layout floating'
  ```
  Bind fullscreen as `fullscreen`, not `fullscreen --no-outer-gaps`, or fullscreen windows cover the sidebar.
- [Accessibility permission](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac) - Needed to read and hide macOS notifications. **Open Accessibility** opens System Settings › Privacy & Security › Accessibility, where you enable AerospaceSidebar. Release builds are not signed with a developer certificate, so after each update remove AerospaceSidebar from that list and enable it again.
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

`~/.config/aerospace-sidebar/config.toml` (or under `$XDG_CONFIG_HOME`), also editable in Settings › General:

```toml
[notifications]
replace_system = true                    # hide macOS banners and list them in the sidebar
actionable_left_to_macos = true          # leave notifications with buttons (Reply, Snooze) to macOS
apps_left_to_macos = ["zoom.us"]         # app names whose notifications stay on screen

[history]
retention_hours = 24                     # 1 to 720
max_count = 200                          # 10 to 2000

[font]
name = ""                                # font family (Settings › General › Choose… picks one); empty uses the system font
size = 13                                # 8 to 32; every text size in the sidebar and Settings scales with it
```

A missing file or key uses the defaults shown. An invalid file keeps the previous settings, and Settings shows the error. A font that is not installed falls back to the system font.

# URL Scheme

Opening `aerospace-sidebar://notification/push` with any of the query parameters `title`, `subtitle`, `body`, `severity`, `icon` and `open` shows a notification, for example from a web page link, the Shortcuts Open URL action, or `open -g "<url>"` in a script. Values are percent-encoded; `aerospace-sidebar notification url` builds the link for you.

```html
<a href="aerospace-sidebar://notification/push?title=Build%20done&severity=high&open=https%3A%2F%2Fci.example.com">Notify me</a>
```

# License

[MIT License](LICENSE) (c) 2026 Alex Gorbatchev
