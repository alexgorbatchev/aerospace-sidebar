---
name: aerospace-sidebar
description: Push notifications into the aerospace-sidebar macOS app with the aerospace-sidebar CLI or aerospace-sidebar:// URLs. Use when a task should alert the user on their Mac, report a finished build or agent run, or offer a click-to-run command or link.
last_modified: 2026-10-26 16:25
---

# aerospace-sidebar

`aerospace-sidebar` shows notifications in the aerospace-sidebar app, a permanent panel on the right edge of the main display. Notifications stay listed until the user clicks or dismisses them. More severe notifications are listed above less severe ones, newest first within a severity. Pushing a notification identical to a listed one (same title, subtitle, body, severity, click action and sender) stacks it onto that entry with a count instead of adding a copy.

Set `AGENT=1` for compact output: success prints `OK: …`, failures print `ERR: <code>: <detail>` to stderr, and help screens are untruncated.

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

Sends a notification to the running app over its control socket (`$(getconf DARWIN_USER_TEMP_DIR)com.alexgorbatchev.aerospace-sidebar.sock`). Launches the app in the background when it is not running and waits up to 5 seconds for it.

| Option | Value | Default | Meaning |
| --- | --- | --- | --- |
| `--title <title>` | string, up to 256 characters | empty | Bold first line |
| `--subtitle <subtitle>` | string, up to 256 characters | empty | Line under the title |
| `--body <body>` | string, up to 4096 characters | empty | Main text |
| `--severity <severity>` | `low`, `normal`, `high`, `critical` | `normal` | Sort order and look: `low` is dimmed, `high` orange, `critical` red |
| `--open <url>` | absolute URL | none | Opened with its default app when the notification is clicked |
| `--run <command>` | shell command | none | Run with the user's login shell (`$SHELL -lc`) in the current directory when the notification is clicked; output is discarded |

- A notification needs `--title` or `--body`.
- `--open` and `--run` are mutually exclusive. Without either, a click only dismisses the notification.
- Hovering a notification shows what a click will do, including the full command.

Output: `[OK] Notification sent to the sidebar.` (human) or `OK: pushed` (agent).

### notification url

Prints an `aerospace-sidebar://notification/push?…` URL without sending anything. Accepts `--title`, `--subtitle`, `--body`, `--severity` and `--open` with the same meaning as `push`. URLs cannot carry `--run`, and their `--open` must be `http` or `https`, because any process or web page can open them.

Opening the URL (`open -g "<url>"`, a link on a web page after the browser's confirmation, Shortcuts' Open URL action) shows the notification and labels it with the app that opened the URL when known, else `URL`.

URL query parameters: `title`, `subtitle`, `body`, `severity`, `open`. Percent-encode values; a literal `+` stays `+`.

### skill

Prints the Skills CLI install command and this skill's URL. Takes no arguments.

## Exit codes and errors

| Exit | Meaning |
| --- | --- |
| 0 | Success, or a help screen |
| 1 | The notification was invalid or could not be delivered |
| 64 | Invalid arguments, such as `--open` with `--run` or an unknown option |
| 74 | Output could not be written |

Agent-mode error codes: `app_not_installed` (no app registered for bundle id `com.alexgorbatchev.aerospace-sidebar`), `app_did_not_start`, `rejected`, `unreachable`, `output_write_failed` (exit 74). Payload errors print the reason, for example `a notification needs a title or a body`.

## Examples

```sh
AGENT=1 aerospace-sidebar notification push --title "Tests passed" --body "142 passed in 31s"
AGENT=1 aerospace-sidebar notification push --severity critical --title "Deploy failed" --run "open $CI_URL"
AGENT=1 aerospace-sidebar notification push --severity low --title "Index rebuilt" --open "https://example.com/report"
open -g "$(aerospace-sidebar notification url --title 'Done' --severity high)"
```
