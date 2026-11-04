---
name: aerospace-sidebar
description: Push notifications into the aerospace-sidebar macOS app with the aerospace-sidebar CLI or aerospace-sidebar:// URLs. Use when a task should alert the user on their Mac, report a finished build or agent run, offer click-to-run commands, buttons or links, or ask the user a question and wait for the answer.
last_modified: 2026-11-04 14:58
---

# aerospace-sidebar

`aerospace-sidebar` shows notifications in the aerospace-sidebar app, a permanent panel on one edge of the main display (the right by default; the user picks the side). A notification stays listed until the user clicks or dismisses it, until it is older than the user's retention period (24 hours by default), or until the list holds more than its maximum (200 by default), which drops the least severe and oldest first. Rules the user writes can hide a notification on arrival or change its severity, so a delivered push is not guaranteed to be listed. More severe notifications are listed above less severe ones, newest first within a severity. Pushing a notification identical to a listed one (same title, subtitle, body, severity, icon, click action, choices and sender) stacks it onto that entry with a count instead of adding a copy; asked notifications (`notification ask`) never stack.

Set `AGENT=1` for compact output: success prints `OK: …` (`notification url` prints the link instead), failures print one `ERR: <code>: <detail>` line to stderr (see [Exit codes and errors](#exit-codes-and-errors)), and help screens are untruncated.

## Commands

```
aerospace-sidebar
├─ notification
│  ├─ ask      Show a notification with buttons and wait for the user's answer
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
| `--markdown` | flag | off | Show the body as markdown: `**bold**`, `*italic*`, `` `code` ``, `~~strikethrough~~` and `[text](https://…)` links. Lists, headings, tables and HTML show as written; links to anything but `http` or `https` keep only their text |
| `--severity <severity>` | `low`, `normal`, `high`, `critical` | `normal` | Sort order and look: `low` is dimmed, `high` orange, `critical` red |
| `--icon <id>` | sketchybar-app-font icon id, `slack` or `:slack:`, up to 64 characters | the app the command runs in, else a terminal | App icon shown before the sender, for example `ghostty`, `slack`, `google_chrome`, `github`. Each `iconName` in https://raw.githubusercontent.com/alexgorbatchev/aerospace-sidebar/main/Resources/sketchybar-app-font/icon_map.json is an id, listed with the app names it stands for |
| `--open <url>` | absolute URL, up to 8192 characters | none | Opened with its default app when the notification is clicked |
| `--run <command>` | shell command, up to 4096 characters | none | Run with the user's login shell from the user database (`-lc`) in the current directory when the notification is clicked; output is discarded |
| `--choice <title=command>` | repeatable; title up to 64 characters, command up to 4096 | none | A button that runs the command like `--run`, with `AEROSPACE_SIDEBAR_CHOICE` set to the title |
| `--reply <title=command>` | repeatable; title up to 64 characters, command up to 4096 | none | A button that opens a text field on the card; sending the text runs the command like `--run`, with `AEROSPACE_SIDEBAR_CHOICE` set to the title and `AEROSPACE_SIDEBAR_REPLY` to the text (up to 4096 characters) |
| `--choice-link <title=url>` | repeatable; title up to 64 characters, `http` or `https` URL up to 8192 | none | A button that opens the link with its default app |

- A notification needs `--title` or `--body`.
- `--body` limits count the markdown as written, syntax included. Without `--markdown`, `*` and backticks are ordinary characters.
- Each value may also take at most four bytes of UTF-8 per character of its limit (1024 bytes for 256 characters). Only text stacking many code points into one character, such as combining marks or emoji sequences, reaches that first.
- The whole request may take at most 65536 bytes as JSON. Values within their limits exceed it only when they are full of control characters or stacked code points; the command then fails with `too_large`.
- Without `--icon`, the notification shows the icon of the app the command runs in, read from `__CFBundleIdentifier` (set by macOS for processes an app starts and inherited by their children), else from `TERM_PROGRAM` (`Apple_Terminal`, `ghostty`, `iTerm.app`, `vscode`, `WarpTerminal`, `WezTerm`). When neither names an installed app, it shows a terminal icon.
- An `--icon` id the font does not have is not an error: the notification shows the icon of the app the command runs in, if any, and a small `Invalid icon: <id>` note under its text. The command still prints `OK: pushed`.
- `--open` and `--run` are mutually exclusive. Without either, a click only dismisses the notification.
- Choice values split at the first `=`: `--choice "Deploy=make deploy ENV=prod"` is the button `Deploy` running `make deploy ENV=prod`. A value without a title before its first `=` fails with `usage`; an empty command fails with `invalid`.
- A notification takes at most 8 choices across `--choice`, `--reply` and `--choice-link`, with different titles (`invalid` otherwise). The card shows them in that order, each option's buttons in the order given, beside the click action.
- Clicking a button performs it and removes the card. A `--reply` button opens a field whose placeholder is the title, with a **Send** button; Return or Send sends non-empty text, Escape closes the field.
- The reply text reaches the command only through `AEROSPACE_SIDEBAR_REPLY`, never as part of the command; quote it in the command (`"$AEROSPACE_SIDEBAR_REPLY"`).
- Choices are saved with the notification and keep working after the app relaunches.
- Hovering a notification shows what a click will do, including the full command, and what each button runs or opens.

Output: `[OK] Notification sent to the sidebar.` (human) or `OK: pushed` (agent).

### notification ask

Shows a notification with buttons over the control socket, like `push` (same app launch, retries and 5-second confirmation), then keeps the connection open and waits until the user answers on the card.

| Option | Value | Default | Meaning |
| --- | --- | --- | --- |
| `--title`, `--subtitle`, `--body`, `--markdown`, `--severity`, `--icon` | as for `push` | as for `push` | The notification's content; without `--icon` it shows the icon of the app the command runs in, else a terminal |
| `--choice <title>` | repeatable; up to 64 characters | none | A button; picking it answers with its title |
| `--reply <title>` | repeatable; up to 64 characters | none | A button that opens a text field; sending it answers with the text (up to 4096 characters) |
| `--timeout <seconds>` | number above 0, at most 31536000 | none: waits as long as it takes | Gives up after this long and removes the card |
| `--json` | flag | off | Prints the answer as JSON instead of plain text |

- Requires `--title` or `--body` (`invalid` otherwise) and at least one `--choice` or `--reply` (`usage` otherwise); at most 8 in all, with different, non-empty titles (`invalid` otherwise). Buttons show in the order `--choice`, then `--reply`. Titles may contain `=`.
- Output on an answer, followed by a newline. With `--json`, in both modes: `{"choice":"<title>","reply":"<text>"}`, with `"reply":null` for a `--choice` button. Otherwise in agent mode: one line, `OK: ` followed by that JSON object, which keeps a multi-line reply on one line. Otherwise in human mode: the reply text for a `--reply` button, else the button's title.
- Exit code 2 with `dismissed` when the card goes without an answer: the user dismisses it (its × button, Option-click, a click on the card itself, Clear All), it expires or is dropped by the history limits, or a rule hides it, on arrival or when the user saves rules while it waits. Exit code 2 with `timeout` when `--timeout` passes; the card is removed.
- Stopping the command (Ctrl-C, killing it) closes the connection, and the app removes the card.
- Quitting the app ends the wait with `no_answer` (exit 1). After a relaunch the card is listed without its buttons.
- When the app does not confirm the question within 5 seconds, the command fails with `no_reply` and closes the connection, which removes the card if the app shows it after all, so asking again is safe.

### notification url

Prints an `aerospace-sidebar://notification/push?…` URL without sending anything. Accepts `--title`, `--subtitle`, `--body`, `--markdown`, `--severity`, `--icon`, `--open` and `--choice-link` with the same meaning as `push`; `--markdown` becomes `markdown=1`. URLs cannot carry `--run`, `--choice`, `--reply` or questions, and their `--open` and link choices must be `http` or `https`, because any process or web page can open them.

Opening the URL (`open -g "<url>"`, a link on a web page after the browser's confirmation, Shortcuts' Open URL action) shows the notification and labels it with the app that opened the URL when known, else `URL`. Without `-g`, macOS brings the sidebar app forward to open the URL; it hands activation straight back to the app the user was working in (launchers such as Spotlight, Raycast and Alfred are passed over).

URL query parameters: `title`, `subtitle`, `body`, `severity`, `icon`, `open`, and `choice` (repeatable, `TITLE=URL`, split at the first `=`). Percent-encode values; a literal `+` stays `+`.

### skill

Prints the Skills CLI install command and this skill's URL. Takes no arguments.

## Exit codes and errors

| Exit | Meaning |
| --- | --- |
| 0 | Success, or a help screen |
| 1 | The notification was invalid, could not be delivered, or was not confirmed; or the app stopped waiting for an answer |
| 2 | `notification ask` got no answer: the card went without one, or `--timeout` passed |
| 64 | Invalid arguments, such as `--open` with `--run` or an unknown option |
| 74 | Output could not be written |

Agent-mode error codes:

| Code | Exit | Meaning |
| --- | --- | --- |
| `usage` | 64 | Invalid arguments; the detail is the parser's message, such as `Use either --open or --run, not both.` or `Give at least one --choice or --reply.` |
| `invalid` | 1 | The notification is invalid, such as `a notification needs a title or a body` or a value over its limit |
| `too_large` | 1 | The request is larger than the control socket accepts; nothing was sent |
| `app_not_installed` | 1 | No app registered for bundle id `com.alexgorbatchev.aerospace-sidebar` |
| `launch_failed` | 1 | macOS could not launch the app; the detail is its reason |
| `app_did_not_start` | 1 | The launched app did not listen within 5 seconds |
| `unreachable` | 1 | The control socket failed before the app received the notification |
| `no_reply` | 1 | The notification was sent but the app did not confirm it. For `push`, it may still appear, so do not push it again. For `ask`, no card stays, so ask again |
| `rejected` | 1 | The app refused the notification |
| `dismissed` | 2 | `notification ask`: the card went without an answer |
| `timeout` | 2 | `notification ask`: no answer within `--timeout`; the card was removed |
| `no_answer` | 1 | `notification ask`: the connection ended before an answer, such as when the app quit |
| `failed` | 1 | Any other error |
| `output_write_failed` | 74 | Output could not be written, such as to a pipe whose reader has exited |

## Examples

```sh
AGENT=1 aerospace-sidebar notification push --icon ghostty --title "Tests passed" --body "142 passed in 31s"
AGENT=1 aerospace-sidebar notification push --severity critical --title "Deploy failed" --run "open $CI_URL"
AGENT=1 aerospace-sidebar notification push --severity low --title "Index rebuilt" --open "https://example.com/report"
AGENT=1 aerospace-sidebar notification push --title "PR #42 approved" --choice "Merge=gh pr merge 42 --squash" --choice-link "Open=https://github.com/o/r/pull/42"
AGENT=1 aerospace-sidebar notification push --title "Release notes?" --reply 'Add=printf "%s\n" "$AEROSPACE_SIDEBAR_REPLY" >> NOTES.md'
answer=$(aerospace-sidebar notification ask --title "Run the migration?" --choice Run --choice Skip --timeout 600) && [ "$answer" = Run ]
AGENT=1 aerospace-sidebar notification ask --title "Which branch?" --reply Branch --json
open -g "$(aerospace-sidebar notification url --title 'Done' --severity high)"
```
