---
name: aerospace-sidebar
description: Push notifications into the aerospace-sidebar macOS app with the aerospace-sidebar CLI or aerospace-sidebar:// URLs. Use when a task should alert the user on their Mac, report a finished build or agent run, or offer a click-to-run command or link.
last_modified: 2026-10-29 11:50
---

# aerospace-sidebar

`aerospace-sidebar` shows notifications in the aerospace-sidebar app, a permanent panel on one edge of the main display (the right by default; the user picks the side). A notification stays listed until the user clicks or dismisses it, until it is older than the user's retention period (24 hours by default), or until the list holds more than its maximum (200 by default), which drops the least severe and oldest first. Rules the user writes can hide a notification on arrival or change its severity, so a delivered push is not guaranteed to be listed. More severe notifications are listed above less severe ones, newest first within a severity. Pushing a notification identical to a listed one (same title, subtitle, body, severity, icon, click action and sender) stacks it onto that entry with a count instead of adding a copy.

Set `AGENT=1` for compact output: success prints `OK: …`, failures print one `ERR: <code>: <detail>` line to stderr (see [Exit codes and errors](#exit-codes-and-errors)), and help screens are untruncated.

## Commands

```
aerospace-sidebar
├─ notification
│  ├─ push     Show a notification in the sidebar, starting the app if needed
│  ╰─ url      Print an aerospace-sidebar:// link that shows a notification when opened
╰─ skill       Print how to install this skill
```

Every command accepts `-h`/`--help`. `aerospace-sidebar help <command>` prints the same help.

### notification push

Sends a notification to the running app over its control socket (`$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`). Launches the app in the background when it is not running and waits up to 5 seconds for it to listen, then up to 5 seconds for the app to confirm the notification. Only connecting is tried again: a notification that was sent is never sent twice. When the app does not confirm it in time the command fails with `no_reply`; the notification may still appear, so do not push it again.

| Option | Value | Default | Meaning |
| --- | --- | --- | --- |
| `--title <title>` | string, up to 256 characters | empty | Bold first line |
| `--subtitle <subtitle>` | string, up to 256 characters | empty | Line under the title |
| `--body <body>` | string, up to 4096 characters | empty | Main text |
| `--severity <severity>` | `low`, `normal`, `high`, `critical` | `normal` | Sort order and look: `low` is dimmed, `high` orange, `critical` red |
| `--icon <id>` | sketchybar-app-font icon id, `slack` or `:slack:`, up to 64 characters | the app the command runs in, else a terminal | App icon shown before the sender, for example `ghostty`, `slack`, `google_chrome`, `github`. Each `iconName` in https://raw.githubusercontent.com/alexgorbatchev/aerospace-sidebar/main/Resources/sketchybar-app-font/icon_map.json is an id, listed with the app names it stands for |
| `--open <url>` | absolute URL, up to 8192 characters | none | Opened with its default app when the notification is clicked |
| `--run <command>` | shell command, up to 4096 characters | none | Run with the user's login shell from the user database (`-lc`) in the current directory when the notification is clicked; output is discarded |

- A notification needs `--title` or `--body`.
- Each value may also take at most four bytes of UTF-8 per character of its limit (1024 bytes for 256 characters). Only text stacking many code points into one character, such as combining marks or emoji sequences, reaches that first.
- The whole request may take at most 65536 bytes as JSON. Values within their limits exceed it only when they are full of control characters or stacked code points; the command then fails with `too_large`.
- Without `--icon`, the notification shows the icon of the app the command runs in, read from `__CFBundleIdentifier` (set by macOS for processes an app starts and inherited by their children), else from `TERM_PROGRAM` (`Apple_Terminal`, `ghostty`, `iTerm.app`, `vscode`, `WarpTerminal`, `WezTerm`). When neither names an installed app, it shows a terminal icon.
- An `--icon` id the font does not have is not an error: the notification shows the icon of the app the command runs in, if any, and a small `Invalid icon: <id>` note under its text. The command still prints `OK: pushed`.
- `--open` and `--run` are mutually exclusive. Without either, a click only dismisses the notification.
- Hovering a notification shows what a click will do, including the full command.

Output: `[OK] Notification sent to the sidebar.` (human) or `OK: pushed` (agent).

### notification url

Prints an `aerospace-sidebar://notification/push?…` URL without sending anything. Accepts `--title`, `--subtitle`, `--body`, `--severity`, `--icon` and `--open` with the same meaning as `push`. URLs cannot carry `--run`, and their `--open` must be `http` or `https`, because any process or web page can open them.

Opening the URL (`open -g "<url>"`, a link on a web page after the browser's confirmation, Shortcuts' Open URL action) shows the notification and labels it with the app that opened the URL when known, else `URL`. Without `-g`, macOS brings the sidebar app forward to open the URL; it hands activation straight back to the app the user was working in (launchers such as Spotlight, Raycast and Alfred are passed over).

URL query parameters: `title`, `subtitle`, `body`, `severity`, `icon`, `open`. Percent-encode values; a literal `+` stays `+`.

### skill

Prints the Skills CLI install command and this skill's URL. Takes no arguments.

## Exit codes and errors

| Exit | Meaning |
| --- | --- |
| 0 | Success, or a help screen |
| 1 | The notification was invalid, could not be delivered, or was not confirmed |
| 64 | Invalid arguments, such as `--open` with `--run` or an unknown option |
| 74 | Output could not be written |

Agent-mode error codes:

| Code | Exit | Meaning |
| --- | --- | --- |
| `usage` | 64 | Invalid arguments; the detail is the parser's message, such as `Use either --open or --run, not both.` |
| `invalid` | 1 | The notification is invalid, such as `a notification needs a title or a body` or a value over its limit |
| `too_large` | 1 | The request is larger than the control socket accepts; nothing was sent |
| `app_not_installed` | 1 | No app registered for bundle id `com.alexgorbatchev.aerospace-sidebar` |
| `launch_failed` | 1 | macOS could not launch the app; the detail is its reason |
| `app_did_not_start` | 1 | The launched app did not listen within 5 seconds |
| `unreachable` | 1 | The control socket failed before the app received the notification |
| `no_reply` | 1 | The notification was sent but the app did not confirm it; it may still appear, so do not push it again |
| `rejected` | 1 | The app refused the notification |
| `failed` | 1 | Any other error |
| `output_write_failed` | 74 | Output could not be written, such as to a pipe whose reader has exited |

## Examples

```sh
AGENT=1 aerospace-sidebar notification push --icon ghostty --title "Tests passed" --body "142 passed in 31s"
AGENT=1 aerospace-sidebar notification push --severity critical --title "Deploy failed" --run "open $CI_URL"
AGENT=1 aerospace-sidebar notification push --severity low --title "Index rebuilt" --open "https://example.com/report"
open -g "$(aerospace-sidebar notification url --title 'Done' --severity high)"
```
