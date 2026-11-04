app := ".build/AerospaceSidebar.app"
cli := "bin/aerospace-sidebar"
# Dev app that posts notifications with actions through UNUserNotificationCenter (Tools/NotificationSampler)
sampler_app := ".build/NotificationSampler.app"
# The sampler's stderr: launched through open, it has no terminal to report failures to
sampler_log := ".build/NotificationSampler.log"
bundle_id := "com.alexgorbatchev.aerospace-sidebar"
# Vendored sketchybar-app-font release (CC0), copied into the bundle's Resources
app_font := "Resources/sketchybar-app-font"
# NotifyMeHow (this user's fork and upstream) also hides native banners; the sidebar replaces it
notifymehow_bundle_ids := "com.alexgorbatchev.notifymehow com.motleywoods.NotifyMeHow"
# A stable signing identity keeps the Accessibility permission across rebuilds; ad-hoc builds lose it
signing_identity := env("AEROSPACE_SIDEBAR_SIGNING_IDENTITY", "Developer ID Application: Alex Gorb (4XCZD8P4CJ)")
coverage_min := "90"
# Prefix for every Swift toolchain command; see _scratch-tmpdir
with_scratch_tmpdir := quote(just_executable()) + " --justfile " + quote(justfile()) + " _scratch-tmpdir"

default:
    @just --list

# Resolve Swift package dependencies and install alerter for test-notifications
setup:
    {{ with_scratch_tmpdir }} swift package resolve
    command -v alerter >/dev/null || brew install vjeantet/tap/alerter

# Build the app bundle into .build/AerospaceSidebar.app (CLI included in Contents/Helpers) and the CLI into bin/; version sets CFBundleShortVersionString
bundle version="":
    {{ with_scratch_tmpdir }} swift build -c release --product AerospaceSidebar
    {{ with_scratch_tmpdir }} swift build -c release --product aerospace-sidebar
    rm -rf {{ app }}
    mkdir -p {{ app }}/Contents/MacOS {{ app }}/Contents/Helpers {{ app }}/Contents/Resources bin
    cp "$({{ with_scratch_tmpdir }} swift build -c release --show-bin-path)/AerospaceSidebar" {{ app }}/Contents/MacOS/
    cp Resources/Info.plist {{ app }}/Contents/Info.plist
    cp -R {{ app_font }} {{ app }}/Contents/Resources/
    # PermissionFlow looks for its resource bundle in Contents/Resources; codesign rejects one at the .app root.
    cp -R "$({{ with_scratch_tmpdir }} swift build -c release --show-bin-path)/PermissionFlow_PermissionFlow.bundle" {{ app }}/Contents/Resources/
    {{ if version != "" { "plutil -replace CFBundleShortVersionString -string " + quote(version) + " " + app + "/Contents/Info.plist" } else { "true" } }}
    # Nested code is signed before the bundle that contains it.
    cp "$({{ with_scratch_tmpdir }} swift build -c release --show-bin-path)/aerospace-sidebar" {{ app }}/Contents/Helpers/
    codesign --force --sign "{{ signing_identity }}" {{ app }}/Contents/Helpers/aerospace-sidebar
    codesign --force --sign "{{ signing_identity }}" {{ app }}
    cp "$({{ with_scratch_tmpdir }} swift build -c release --show-bin-path)/aerospace-sidebar" {{ cli }}

# Build the Notification Sampler dev app into .build/NotificationSampler.app, signed like the sidebar
sampler:
    rm -rf {{ sampler_app }}
    mkdir -p {{ sampler_app }}/Contents/MacOS
    {{ with_scratch_tmpdir }} swiftc -swift-version 6 -o {{ sampler_app }}/Contents/MacOS/NotificationSampler Tools/NotificationSampler/main.swift
    cp Tools/NotificationSampler/Info.plist {{ sampler_app }}/Contents/Info.plist
    codesign --force --sign "{{ signing_identity }}" {{ sampler_app }}

# Rebuild and (re)launch the sidebar, quitting NotifyMeHow so only one app hides banners
run: stop quit-notifymehow bundle
    open {{ app }}

# Quit a running sidebar; a graceful quit moves hidden NotificationCenter windows back on-screen
stop:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -z "$(lsappinfo find bundleid={{ bundle_id }})" ]] && exit 0
    osascript -e 'tell application id "{{ bundle_id }}" to quit'
    for _ in {1..50}; do
        [[ -z "$(lsappinfo find bundleid={{ bundle_id }})" ]] && exit 0
        sleep 0.1
    done
    echo "{{ bundle_id }} did not quit within 5s" >&2
    exit 1

# Quit NotifyMeHow if it is running
quit-notifymehow:
    #!/usr/bin/env bash
    set -euo pipefail
    for id in {{ notifymehow_bundle_ids }}; do
        [[ -z "$(lsappinfo find bundleid="$id")" ]] && continue
        echo "Quitting $id"
        osascript -e "tell application id \"$id\" to quit"
    done

# Build versioned release archives and checksums into dist/ (the release workflow runs this on v* tags)
release-archives version:
    just bundle {{ quote(version) }}
    rm -rf dist
    mkdir dist
    tar -czf "dist/AerospaceSidebar_{{ version }}_darwin_arm64.tar.gz" -C .build AerospaceSidebar.app
    tar -czf "dist/aerospace-sidebar_{{ version }}_darwin_arm64.tar.gz" -C bin aerospace-sidebar
    cd dist && shasum -a 256 *.tar.gz > checksums.txt

# Replace the vendored sketchybar-app-font with a release (tag such as v3.0.13) and record its tag
update-app-font tag:
    gh release download {{ quote(tag) }} --repo kvndrsslr/sketchybar-app-font --dir {{ app_font }} --clobber \
        --pattern sketchybar-app-font.ttf --pattern icon_map.json
    gh api "repos/kvndrsslr/sketchybar-app-font/contents/LICENSE?ref={{ tag }}" -H "Accept: application/vnd.github.raw" > {{ app_font }}/LICENSE
    echo {{ quote(tag) }} > {{ app_font }}/VERSION

# Run the CLI
cli *args:
    {{ cli }} {{ args }}

# Run the CLI in agent mode
cli-ai *args:
    AGENT=1 {{ cli }} {{ args }}

# Take the sidebar off the Accessibility list, so it asks for the permission again
reset-accessibility:
    tccutil reset Accessibility {{ bundle_id }}

# Take the sidebar off the Full Disk Access list, so it asks for the permission again
reset-full-disk-access:
    tccutil reset SystemPolicyAllFiles {{ bundle_id }}

# Take the sidebar off every privacy list it asks to be on, to walk through Settings › Permissions from scratch
reset-permissions: reset-accessibility reset-full-disk-access

# The alerts come from alerter (brew install vjeantet/tap/alerter); each alerter waits in the background
# until its alert is answered or closed, or for alert_timeout seconds. They are sent as Script Editor, like
# the osascript notification, so keep Script Editor out of apps_left_to_macos. A Reply alert whose field is
# still open when alerter exits can never be closed: answer or close it before alert_timeout, or run
# killall NotificationCenter.
# The Notification Sampler (just sampler) posts through UNUserNotificationCenter with actions from the categories
# it declares (alerter posts through NSUserNotification and declares none) and pushes every response it gets
# through the CLI. It quits once its notifications are answered or closed, or after alert_timeout seconds,
# removing the rest. Its first run makes macOS ask whether "Notification Sampler" may post notifications. Its
# notifications are banners by default; set its style to Alerts in System Settings › Notifications to see the
# persistent variant. open leaves it no terminal, so its errors and the CLI's go to .build/NotificationSampler.log
# (open appends, so the recipe deletes the previous run's log first).
# Push test notifications through the CLI, the URL scheme and macOS itself, plus alerts and the sampler's actions
test-notifications alert_timeout="600": sampler
    @command -v alerter >/dev/null || { echo "alerter not found; install it with: brew install vjeantet/tap/alerter" >&2; exit 1; }
    {{ cli }} notification push --severity low --title "Low severity" --body "Dimmed and listed below everything else."
    {{ cli }} notification push --icon ghostty --title "CLI notification" --body "Pushed with aerospace-sidebar notification push, with the Ghostty icon."
    {{ cli }} notification push --icon no_such_app --title "Unknown icon" --body "Notes an icon id the font does not have under the text."
    {{ cli }} notification push --title "Click to run a command" --body "Runs 'say clicked' in this directory. The link https://github.com/alexgorbatchev/aerospace-sidebar opens on its own." --run "say clicked"
    {{ cli }} notification push --title "Click to open a link" --subtitle "Opens the AeroSpace guide" --open "https://nikitabobko.github.io/AeroSpace/guide"
    open -g "$({{ cli }} notification url --icon safari --title 'URL notification' --body 'Delivered through the aerospace-sidebar:// URL scheme, with the Safari icon.')"
    {{ cli }} notification push --severity high --title "High severity" --body "Orange, listed above normal notifications."
    open -g "$({{ cli }} notification url --severity critical --title 'Critical severity' --body 'Red, always on top. Sent through a URL.')"
    osascript -e 'display notification "A native macOS notification, intercepted and moved into the sidebar." with title "macOS notification" subtitle "Posted by osascript"'
    alerter --sender com.apple.ScriptEditor2 --title "Alert with a choice" --subtitle "Posted by alerter" --message "Allow, and Deny as its close button." --actions Allow --close-label Deny --timeout {{ alert_timeout }} >/dev/null 2>&1 &
    alerter --sender com.apple.ScriptEditor2 --title "Alert with a menu" --subtitle "Posted by alerter" --message "Three actions under a When? menu." --actions "Now,Later today,Tomorrow" --dropdown-label "When?" --timeout {{ alert_timeout }} >/dev/null 2>&1 &
    alerter --sender com.apple.ScriptEditor2 --title "Alert with a reply" --subtitle "Posted by alerter" --message "A Reply button that opens a text field." --reply "Type a reply" --timeout {{ alert_timeout }} >/dev/null 2>&1 &
    rm -f {{ sampler_log }}
    open -g -n --stderr {{ sampler_log }} {{ sampler_app }} --args {{ quote(justfile_directory() / cli) }} {{ alert_timeout }} choices reply

# Push count distinct notifications of mixed severity and length, enough to make the list scroll; none stack
fill-notifications count="20":
    #!/usr/bin/env bash
    set -euo pipefail
    severities=(low normal normal normal high critical)
    bodies=(
        "Short body."
        "A body long enough to wrap onto a second line in the sidebar."
        "A longer body that wraps across several lines, so cards of different heights show how the list scrolls and how the indicator sizes its knob."
    )
    run="$(date +%H:%M:%S)"
    for i in $(seq 1 {{ count }}); do
        {{ cli }} notification push \
            --severity "${severities[RANDOM % ${#severities[@]}]}" \
            --title "Filler $i ($run)" \
            --body "${bodies[RANDOM % ${#bodies[@]}]}" >/dev/null
    done
    echo "Pushed {{ count }} notifications"

# The Swift toolchain leaves empty TemporaryDirectory.* folders in TMPDIR, so run command with TMPDIR in a
# fresh child of .tmp/ and remove it when command exits. SwiftPM keeps the lock file that stops two builds
# from sharing .build at once in TMPDIR too, so command holds .state/swift.lock in its place.
[positional-arguments]
_scratch-tmpdir +command:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .tmp .state
    TMPDIR="$(mktemp -d "$PWD/.tmp/swift.XXXXXX")"
    trap 'rm -rf "$TMPDIR"' EXIT
    export TMPDIR
    lockf -k .state/swift.lock "$@"

# Tests run with a one-thread cooperative pool, so blocking calls on Swift's thread pool deadlock
# here instead of only on few-core CI runners.
test:
    LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 {{ with_scratch_tmpdir }} swift test

# Run tests with coverage and enforce line and function minimums over Sources/
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 {{ with_scratch_tmpdir }} swift test --enable-code-coverage
    bin="$({{ with_scratch_tmpdir }} swift build --show-bin-path)/aerospace-sidebarPackageTests.xctest/Contents/MacOS/aerospace-sidebarPackageTests"
    profdata="$(dirname "$({{ with_scratch_tmpdir }} swift test --show-codecov-path)")/default.profdata"
    ignore='(\.build|Tests)/'
    xcrun llvm-cov report "$bin" -instr-profile "$profdata" -ignore-filename-regex "$ignore"
    summary="$(xcrun llvm-cov export "$bin" -instr-profile "$profdata" -ignore-filename-regex "$ignore" -summary-only)"
    status=0
    while IFS= read -r source; do
        # llvm-cov reports resolved paths, so compare against the physical directory (/tmp is a symlink).
        if ! jq -e --arg f "$(pwd -P)/$source" '.data[0].files | any(.filename == $f)' <<<"$summary" >/dev/null; then
            echo "error: $source is not in the coverage report" >&2
            status=1
        fi
    done < <(find Sources -name '*.swift' | sort)
    for metric in lines functions; do
        percent="$(jq -r --arg m "$metric" '.data[0].totals[$m].percent' <<<"$summary")"
        if ! awk -v p="$percent" -v min="{{ coverage_min }}" 'BEGIN { exit !(p >= min) }'; then
            echo "error: $metric coverage $percent% is below {{ coverage_min }}%" >&2
            status=1
        fi
    done
    exit "$status"
