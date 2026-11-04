`aerospace-sidebar` is a permanent notification sidebar for macOS users of the [AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling window manager. It takes over the right or left edge of the main display, replaces macOS notification banners with a list that stays until you deal with it, and lets scripts, agents and web pages push their own notifications with click actions and buttons, or ask you a question and wait for the answer.

# What It Does

- **Reserved screen strip**: a panel on the right or left edge of the main display that tiled windows never cover, on every Space and over full-screen apps.
- **macOS notifications, kept**: native banners are hidden and listed in the sidebar instead, so nothing disappears after five seconds.
- **Notification buttons on cards**: a notification with buttons, such as Reply, Approve or Delete, is hidden and listed with those buttons on its card, any number of them and banners included, when its app declared them to macOS (this needs Full Disk Access). Buttons the app marks destructive, such as Delete, look destructive. Reply opens a field on the card that sends your text as if you had typed it into the notification. The buttons keep working after a banner has timed out into Notification Center: the sidebar acts on it there, off-screen. Notifications listed from macOS's database because they showed no banner (during Focus or Do Not Disturb, or from apps whose banner style is None) get their buttons too. So does an alert with an actions menu, once macOS records it a few seconds after it appears: the alert then leaves the screen, and its card offers the menu's items. Without Full Disk Access, only alerts with one or two buttons get theirs, such as Allow… on macOS's "Privacy & Security" alert. Clicking the card does what clicking the notification does, and dismissing the card closes it.
- **Other interactive notifications left alone**: notifications whose buttons a card cannot offer stay on screen as macOS shows them, and are also listed. These are banners with buttons their app did not declare to macOS (every banner with buttons while the sidebar lacks Full Disk Access), alerts with three or more such buttons, alerts with an actions menu until macOS records them a few seconds later (with Full Disk Access, see above), and notifications showing a text field or another control. With the sidebar on the right, macOS's notifications move left of it so it does not cover them. Turn this off in Settings to list them without their buttons instead. Notifications without buttons are listed like any other notification.
- **Push from anywhere**: the `aerospace-sidebar` command and `aerospace-sidebar://` links add notifications.
- **Buttons and questions**: a pushed notification can carry up to eight buttons beside its click action: one that runs a shell command, one that opens a field on the card and hands the text you send to a command, or one that opens a web link. `aerospace-sidebar notification ask` shows a notification with buttons and waits until you pick one, then prints your choice or the text you typed, so a script or an agent can ask you something and act on the answer.
- **Click actions**: a notification can run a shell command or open a link when clicked. Web links in a notification's text are clickable on their own, underlined faintly, and in white under the pointer.
- **Severity**: `low`, `normal`, `high` and `critical` notifications sort and look different, with critical ones always on top.
- **Rules**: regular expressions on a notification's sender, title, subtitle or body raise or lower its severity, or hide it, such as every Slack message as `high`. Saving rules also applies them to the notifications already listed, which move, stack or go accordingly; removing a rule gives them back the severity they arrived with. Settings › Rules shows which recent notifications each rule matches, including ones you dismissed and ones a rule hid.
- **App icons**: a notification from an app shows that app's icon before its sender, as macOS does. A pushed notification can name an app icon from [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font) instead, such as `slack` or `google_chrome`; without one, a notification pushed from the terminal shows that terminal's icon.
- **Repeats stacked**: a notification identical to one already listed joins it as a single card with a count, instead of filling the list with copies.
- **Background**: an optional color behind the sidebar's strip, from the top of the screen to the bottom, with its opacity, set in Settings › Appearance.
- **History**: the list survives quitting and relaunching; notifications are kept for 24 hours by default.
- **Missed notifications**: with Full Disk Access, notifications that never showed a banner are listed too: those during Focus or Do Not Disturb, those macOS drops when several arrive at once, and those delivered while the sidebar was not running, within the history's retention.
- **Apps with notifications off**: Settings › Notifications lists the apps that sent notifications while their notifications are switched off in System Settings, whose cards cannot open what they show, and **Allow** switches each one back on.
- **Guided setup**: Settings opens the Accessibility and Full Disk Access settings next to a panel from which you drag the app into the list, adds the app to Login Items and adds the sidebar's settings to your AeroSpace config, one button each. While a permission is missing, the sidebar says so above the list with a **Set Up…** button that starts the same step.

# How It Works

- AeroSpace leaves an empty strip on one edge of the main display, and the sidebar fills it.
- When an app posts a macOS notification, its banner vanishes and the notification appears at the top of its severity group in the sidebar.
- `aerospace-sidebar notification push` sends a notification from the terminal, starting the sidebar first when it is not running.
- `aerospace-sidebar notification ask` does the same and then waits: picking a button on the card prints it, and dismissing the card ends the command with exit code `2`.
- A notification with the same sender, text, severity, icon, click action and buttons as a listed one is stacked onto it (questions from `notification ask` never are): the card moves up as the newest, shows `×2`, `×3`, … next to its time, and gets layered edges below it. Clicking or dismissing a stack removes all of its copies.
- Clicking a notification runs its action, or opens it in the app that posted it as clicking it in macOS would (a browser shows the page that sent it), and removes it. Option-click, or the × button that appears on hover, removes it without acting.
- Clicking one of a card's buttons does what the button says and removes the card. A button that asks for text opens a field on the card; Return or its Send button sends the text.
- Hovering a notification shows what a click will do, including the full command, and what each button runs or opens.

# How it Really Works

- The sidebar's side and width come from its own settings (`[sidebar]` in `config.toml`). AeroSpace has to leave the same strip free: the `monitor.main` entry of `gaps.outer.<side>` minus that side's fallback value is the reserved width. With `outer.right = [{ monitor.main = 305 }, 5]`, a 300-point sidebar on the right keeps AeroSpace's 5-point gap to your windows. The sidebar keeps AeroSpace's config in step: at launch, whenever an AeroSpace config appears, changes or moves in either place AeroSpace looks for it (or at a symlinked config's target), and whenever you change the side or width (in Settings or in `config.toml`), it rewrites its block in that file when the strip is missing or wrong (the `monitor.main` entry has to come first, since AeroSpace uses the first entry whose pattern matches a monitor), then reloads AeroSpace. The block sits in the `[gaps]` table between `# >>> aerospace-sidebar` and `# <<< aerospace-sidebar <<<` and owns `outer.left` and `outer.right`; the sidebar keeps the other monitors' entries and fallback values in it. A config written by a generator is repaired after each regeneration; to avoid the round trip, keep the block in the generator's source and carry it over from the previous output.
- Notifications are read through the macOS Accessibility API from the Notification Center process, which is why the app needs the Accessibility permission. Several alerts from one app that macOS collapses into a stack are expanded and listed one by one. While Notification Center's own panel is open, the sidebar leaves it alone. A notification is listed once even when it stays on screen across a restart of the sidebar, so a dismissed card does not come back.
- Banners are hidden by moving Notification Center's banner window off-screen. The banner itself stays open until its card is removed, so clicking the card can open it; one that times out meanwhile moves to Notification Center's history as usual, and stays there after you dismiss its card. When that window also holds a notification left to macOS, it stays on screen, moved left by the sidebar's width when the sidebar is on the right, and a banner arriving meanwhile shows there until it times out. Quitting the sidebar moves the window back.
- Clicking a card whose notification is only in Notification Center's history opens the history panel off-screen, clicks the notification there and closes the panel again. As the panel closes, Notification Center moves its window back on screen for 2–4 frames before the sidebar can move it away again, so the notifications kept hidden for cards can flash briefly. When the history no longer holds it, because the app removed it or you cleared it, the click switches to the app instead, launching it when it is not running. Cards clicked one after another open their notifications in turn. The panel cannot open while the screen is locked.
- An app whose notifications are switched off in System Settings › Notifications still has them recorded in macOS's notification database, but Notification Center never shows them, as a banner or in its history. The sidebar does not list them unless Settings › Notifications › Switched off (`list_switched_off_apps`) is on; turning it off drops the cards of apps that are switched off. Their cards only switch to the app, and say so under the pointer. Settings › Notifications names these apps; **Allow** opens the app's page in System Settings and switches on Allow Notifications for you, but only once that page is showing and titled with the app's name, otherwise it leaves the page for you to switch. Notification Center then lists the notifications it kept, so their cards open them again.
- macOS's question whether an app may send notifications stays on screen and is never listed or closed by the sidebar: closing it would answer Don't Allow and switch the app's notifications off.
- A notification's buttons come from what its app declared to macOS, which the sidebar reads from the same notification database (see below), so it needs Full Disk Access to offer them for banners and for more than two buttons; that is also how it knows which button asks for text and which one is destructive. Without Full Disk Access, an alert with one or two buttons is offered with them by name.
- A notification listed with its buttons stays open off-screen until you act on its card, so its buttons still work later. A banner that times out meanwhile moves to Notification Center's history, where the sidebar presses its buttons off-screen. Quitting the sidebar brings a hidden notification back on screen, and the card restored at the next launch takes it over again. Cards keep their buttons across a relaunch. A card stops showing them once its notification turns out to be gone: an alert that left the screen without the sidebar, or a notification a button can no longer find in Notification Center. Clicking the card still opens the notification wherever it is.
- Focus and Do Not Disturb suppress banners entirely. With Full Disk Access, the sidebar also reads the database in which macOS records every delivered notification (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, read-only) and lists the ones no banner showed. Their cards offer the notification's buttons, which the sidebar presses in Notification Center's history. That database is private to macOS and may change with a macOS update; the sidebar then logs the error and keeps intercepting banners.
- `aerospace-sidebar notification push` talks to the app over a socket in your private temporary directory (`$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`) that only your user account can open. This is the only way to attach a `--run` command or buttons that run commands or take text. `notification ask` keeps its connection open until the answer arrives; when the command stops waiting (Ctrl-C or its `--timeout`), the sidebar notices the closed connection and removes the card. A question's card does not survive quitting the sidebar with its buttons: after a relaunch it is listed without them, and the waiting command ends with `no_answer`. Buttons that run commands or open links keep working after a relaunch.
- `aerospace-sidebar://` links can be opened by any app, and by web pages after your browser asks for permission. They therefore never carry commands, text fields or questions; their `open` links and link buttons must be `http` or `https`. A notification from a link is labeled with the app that opened it when macOS reports one, otherwise `URL`.
- App icons come from sketchybar-app-font (CC0), which ships inside the app, so nothing needs installing. An icon id is written `slack` or `:slack:`; one the font does not have leaves the notification without an icon and adds a small `Invalid icon: <id>` note under its text. Several apps can share one icon, such as `mail` for Mail, Spark and HEY. [`icon_map.json`](Resources/sketchybar-app-font/icon_map.json) lists every id with the apps it stands for.
- `--run` commands and the commands of `--choice` and `--reply` buttons run with your login shell (the one set for your account, with `-lc`) in the directory where you ran `aerospace-sidebar`. Their output is discarded. A button's command finds the button's title in `AEROSPACE_SIDEBAR_CHOICE` and, for a `--reply` button, the text you sent in `AEROSPACE_SIDEBAR_REPLY`; the text never becomes part of the command itself, so quote the variable (`"$AEROSPACE_SIDEBAR_REPLY"`) like any other.
- The list is saved to `~/Library/Application Support/com.alexgorbatchev.aerospace-sidebar/notifications.json` on every change and holds at most 200 notifications by default; a stack counts as one. Every notification received is also kept in `received.json` beside it, under the same limits, after you dismiss it or a rule hides it, so Settings › Rules can test rules against it.
- The list draws its own thin scroll indicator in the margin on the sidebar's screen edge instead of the system scroll bar, so the cards keep their width when a mouse is attached. It appears while scrolling or when the pointer is over that margin, and can be dragged. A new notification scrolls its card into view, unless the pointer is over the sidebar, a reply is being typed on a card, or you are scrolling the list.
- Settings live in `${XDG_CONFIG_HOME:-~/.config}/aerospace-sidebar/config.toml`. Edits to that file apply immediately; saving from the Settings window rewrites it and drops comments. A `config.toml` that is a symlink, such as one kept in a dotfiles repository, stays one: saving writes the file it points to, and edits there apply too. Edits made to the file while Settings is open are kept when you save, unless you also changed the same group in Settings. In that case, and when the file no longer loads, Save warns first and a second Save replaces the file's version.
- Each edit keeps the rest of your AeroSpace config and its comments, saves the previous version next to it as `aerospace.toml.bak`, checks the config with `aerospace reload-config --dry-run` before and after the edit, and puts the previous version back if the edit adds a problem AeroSpace reports. Problems the config already had, such as a key your AeroSpace version does not know or an invalid monitor pattern, are shown but do not undo the edit. A rejected edit is not retried automatically until the config or the sidebar changes. While AeroSpace is not running the edit is kept unchecked, and AeroSpace reads it when it starts. Settings › Sidebar shows the AeroSpace config file and the result, **Update Config** runs the same edit on demand, also after a rejection, and **Write Again** rewrites the block and reloads AeroSpace even when the config already matches.
- Success messages and the answer to `notification ask` go to stdout, errors to stderr. Exit codes: `0` success, `1` notification invalid, undeliverable or not confirmed, or the app stopped waiting for an answer (`no_answer`, such as when it quit), `2` a question got no answer (its card was dismissed, cleared, expired, dropped or hidden by a rule, or `--timeout` passed), `64` invalid arguments, `74` output could not be written (also when the reader of a pipe has exited). With `AGENT=1`, output is compact: `OK: pushed`, `OK: ` and the answer to a question as JSON, or one `ERR: <code>: <detail>` line. `no_reply` means the notification was sent but not confirmed in time; a pushed notification may still appear, so do not send it again, while an unconfirmed question leaves no card and can be asked again.

# Installation

Download the app and the command for macOS (Apple Silicon) from the [latest release](https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest), replacing `X.X.X` with the version shown on that page.

```bash
mkdir -p ~/Applications ~/.local/bin
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/AerospaceSidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/Applications
curl -sSL https://github.com/alexgorbatchev/aerospace-sidebar/releases/latest/download/aerospace-sidebar_X.X.X_darwin_arm64.tar.gz | tar -xz -C ~/.local/bin
```

The app also carries the command at `AerospaceSidebar.app/Contents/Helpers/aerospace-sidebar`, so linking that onto your `PATH` works instead of the second download.

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
- [Accessibility permission](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac) - Needed to read and hide macOS notifications. Without it, the sidebar shows "Grant Accessibility access to show macOS notifications here." with a **Set Up…** button. That button, like **Open Accessibility** in **Permissions**, opens System Settings › Privacy & Security › Accessibility with a panel below it; drag AerospaceSidebar from the panel into the list, or enable it if it is already there. The sidebar starts intercepting within two seconds of the permission being granted, and hands banners back to macOS within two seconds of it being taken away, or at once when you click **Remove** in **Permissions**. Release builds are not signed with a developer certificate, so after each update click **Remove** (or remove AerospaceSidebar from that list) and grant it again.
- Full Disk Access (optional) - Needed to list notifications that showed no banner, to offer the buttons apps declare for their notifications on cards, and to tell which apps have their notifications switched off. Without it, the sidebar shows a note with **Set Up…** and **Dismiss**; dismissed, it stays hidden, and **Permissions** still offers the step. **Set Up…** and **Open Full Disk Access** open System Settings › Privacy & Security › Full Disk Access the same way; drag AerospaceSidebar into the list, or enable it if macOS already lists it. Like Accessibility, release builds need it granted again after each update.
- While System Settings is the frontmost app, the sidebar and the Settings window step behind it, so they cover neither the permission lists nor the drag panel.
- Login item - **Add to Login Items** opens the sidebar when you log in. It needs the app in `~/Applications` or `/Applications`.
- Quit other apps that restyle or hide notification banners, such as NotifyMeHow, so only one app handles them.

# Quick Start

```bash
# Show a notification with the Ghostty icon
aerospace-sidebar notification push --icon ghostty --title "Tests passed" --body "142 passed in 31s"

# A critical notification that reopens the CI run when clicked
aerospace-sidebar notification push --severity critical --title "Deploy failed" --run "open https://ci.example.com/runs/42"

# Buttons that run a command, or send what you type to one
aerospace-sidebar notification push --title "Release ready" --choice "Tag it=git tag v1.2.0" --reply 'Note=echo "$AEROSPACE_SIDEBAR_REPLY" >> notes.txt'

# Ask a question and print the button you pick
aerospace-sidebar notification ask --title "Deploy to production?" --choice Deploy --choice Wait

# A link that shows a notification when opened, for web pages, Shortcuts or Raycast
aerospace-sidebar notification url --title "Backup finished" --severity low

# Install the agent skill
aerospace-sidebar skill
```

Sample Output:
```
[OK] Notification sent to the sidebar.
[OK] Notification sent to the sidebar.
[OK] Notification sent to the sidebar.
Deploy
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
| `--icon <id>` | | terminal's icon | sketchybar-app-font icon id such as `slack` or `:slack:`, up to 64 characters |
| `--open <url>` | | none | URL to open when the notification is clicked, up to 8192 characters |
| `--run <command>` | | none | Shell command to run in the current directory when the notification is clicked, up to 4096 characters |
| `--choice <title=command>` | | none | A button that runs a shell command in the current directory; repeatable |
| `--reply <title=command>` | | none | A button that opens a text field; sending the text runs a shell command in the current directory; repeatable |
| `--choice-link <title=url>` | | none | A button that opens an `http` or `https` link; repeatable |

A notification needs `--title` or `--body`. Button values split at the first `=` into a title of up to 64 characters and a command (up to 4096 characters) or URL (up to 8192 characters). A notification takes at most 8 buttons with different titles, shown in the order `--choice`, `--reply`, `--choice-link`. A `--reply` field shows the button's title as its placeholder and a **Send** button, and sends at most 4096 characters. Each value may also take at most four bytes of UTF-8 per character of its limit, which only text stacking many combining marks or emoji sequences reaches. `--open` and `--run` cannot be combined. Without `--icon`, the notification shows the icon of the app the command runs in: `__CFBundleIdentifier`, set by macOS for processes an app starts, else the terminal named by `TERM_PROGRAM` (Terminal, Ghostty, iTerm2, VS Code, Warp, WezTerm). Outside any of them it shows a terminal icon.

`aerospace-sidebar notification url`

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--title <title>` | | empty | Bold first line, up to 256 characters |
| `--subtitle <subtitle>` | | empty | Line under the title, up to 256 characters |
| `--body <body>` | | empty | Main text, up to 4096 characters |
| `--severity <severity>` | | `normal` | `low`, `normal`, `high` or `critical` |
| `--icon <id>` | | none | sketchybar-app-font icon id such as `slack` or `:slack:` |
| `--open <url>` | | none | `http` or `https` URL to open when the notification is clicked, up to 8192 characters |
| `--choice-link <title=url>` | | none | A button that opens an `http` or `https` link; repeatable |

`aerospace-sidebar notification ask`

| Flag | Short | Default | Description |
| :--- | :--- | :--- | :--- |
| `--title <title>` | | empty | Bold first line, up to 256 characters |
| `--subtitle <subtitle>` | | empty | Line under the title, up to 256 characters |
| `--body <body>` | | empty | Main text, up to 4096 characters |
| `--severity <severity>` | | `normal` | `low`, `normal`, `high` or `critical` |
| `--icon <id>` | | terminal's icon | sketchybar-app-font icon id such as `slack` or `:slack:`, up to 64 characters |
| `--choice <title>` | | none | A button; picking it prints its title (with `AGENT=1`, `OK: ` and the answer as JSON); repeatable |
| `--reply <title>` | | none | A button that opens a text field; sending it prints the text; repeatable |
| `--timeout <seconds>` | | none | Give up and remove the card after this many seconds; without it the command waits until you answer |
| `--json` | | `false` | Print `{"choice":"<title>","reply":"<text>"}`, with `null` for `reply` when the button asks for no text |

A question needs `--title` or `--body` and at least one `--choice` or `--reply`, at most 8 in all, with different, non-empty titles of up to 64 characters. Clicking the card itself, rather than a button, dismisses it without an answer.

# Configuration

`~/.config/aerospace-sidebar/config.toml` (or under `$XDG_CONFIG_HOME`), also editable in Settings under Appearance, Sidebar, Notifications, Rules and History:

```toml
[sidebar]
side = "right"                           # "right" or "left" edge of the main display
width = 300                              # 150 to 1000 points; changing side or width updates and reloads the AeroSpace config

[notifications]
replace_system = true                    # hide macOS banners and list them in the sidebar
actionable_left_to_macos = true          # leave notifications with buttons cards cannot offer (undeclared buttons, text fields) to macOS
apps_left_to_macos = ["zoom.us"]         # app names whose notifications stay on screen
list_switched_off_apps = false           # list notifications from apps whose notifications are off in System Settings

[history]
retention_hours = 24                     # 1 to 720
max_count = 200                          # 10 to 2000

[font]
name = ""                                # font family (Settings › Appearance › Choose… picks one); empty uses the system font
size = 13                                # 8 to 32; every text size in the sidebar and Settings scales with it

[background]
color = "#000000"                        # the sidebar strip's background, from the top of the screen to the bottom: above other windows, under the menu bar and the Dock
opacity = 0                              # 0 (none) to 1

[[rules]]                                # any number; the first rule that matches a notification applies, also to listed ones
source = "^Slack$"                       # source, title, subtitle, body: case-insensitive regular expressions
                                         # found anywhere in that text; omitted ones match anything, one is required
action = "high"                          # "hide" drops the notification; "low", "normal", "high" or "critical" sets its severity
```

A missing file or key uses the defaults shown. A key or table not shown here, such as a misspelled one, makes the file invalid, and the error names it (`notifications: unknown key replace_sytem; expected replace_system, actionable_left_to_macos, apps_left_to_macos, or list_switched_off_apps`). An invalid file keeps the previous settings, and Settings shows the error. When the sidebar starts with an invalid file there are no previous settings: it uses the defaults shown and updates the AeroSpace config to reserve the default strip until the file loads again. While the file does not load, a note in the sidebar says why and opens Settings. A font that is not installed falls back to the system font.

# URL Scheme

Opening `aerospace-sidebar://notification/push` with any of the query parameters `title`, `subtitle`, `body`, `severity`, `icon`, `open` and `choice` shows a notification, for example from a web page link, the Shortcuts Open URL action, or `open -g "<url>"` in a script. Values are percent-encoded; `aerospace-sidebar notification url` builds the link for you. Opening a link without `-g` brings the sidebar app forward for a moment; it hands activation straight back to the app you were working in (launchers such as Spotlight, Raycast and Alfred are passed over).

Each `choice` adds a link button: its value is the button's title, `=`, and the `http` or `https` URL it opens, such as `choice=Logs%3Dhttps%3A%2F%2Fci.example.com%2Flogs`. Links cannot add buttons that run commands, take text or answer a question.

```html
<a href="aerospace-sidebar://notification/push?title=Build%20done&severity=high&open=https%3A%2F%2Fci.example.com">Notify me</a>
```

# License

[MIT License](LICENSE) (c) 2026 Alex Gorbatchev
