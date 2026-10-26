app := ".build/AerospaceSidebar.app"
cli := "bin/aerospace-sidebar"
bundle_id := "com.alexgorbatchev.aerospace-sidebar"
# NotifyMeHow (this user's fork and upstream) also hides native banners; the sidebar replaces it
notifymehow_bundle_ids := "com.alexgorbatchev.notifymehow com.motleywoods.NotifyMeHow"
# A stable signing identity keeps the Accessibility permission across rebuilds; ad-hoc builds lose it
signing_identity := env("AEROSPACE_SIDEBAR_SIGNING_IDENTITY", "Developer ID Application: Alex Gorb (4XCZD8P4CJ)")
coverage_min := "90"

default:
    @just --list

# Build the app bundle into .build/AerospaceSidebar.app and the CLI into bin/; version sets CFBundleShortVersionString
bundle version="":
    swift build -c release --product AerospaceSidebar
    swift build -c release --product aerospace-sidebar
    rm -rf {{ app }}
    mkdir -p {{ app }}/Contents/MacOS bin
    cp "$(swift build -c release --show-bin-path)/AerospaceSidebar" {{ app }}/Contents/MacOS/
    cp Resources/Info.plist {{ app }}/Contents/Info.plist
    {{ if version != "" { "plutil -replace CFBundleShortVersionString -string " + quote(version) + " " + app + "/Contents/Info.plist" } else { "true" } }}
    codesign --force --sign "{{ signing_identity }}" {{ app }}
    cp "$(swift build -c release --show-bin-path)/aerospace-sidebar" {{ cli }}

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

# Run the CLI
cli *args:
    {{ cli }} {{ args }}

# Run the CLI in agent mode
cli-ai *args:
    AGENT=1 {{ cli }} {{ args }}

# Clear the sidebar's Accessibility permission so the next launch asks again
reset-permissions:
    tccutil reset Accessibility {{ bundle_id }}

# Push test notifications through the CLI, the URL scheme and macOS itself
test-notifications:
    {{ cli }} notification push --severity low --title "Low severity" --body "Dimmed and listed below everything else."
    {{ cli }} notification push --title "CLI notification" --body "Pushed with aerospace-sidebar notification push."
    {{ cli }} notification push --title "Click to run a command" --body "Runs 'say clicked' in this directory." --run "say clicked"
    {{ cli }} notification push --title "Click to open a link" --subtitle "Opens the AeroSpace guide" --open "https://nikitabobko.github.io/AeroSpace/guide"
    open -g "$({{ cli }} notification url --title 'URL notification' --body 'Delivered through the aerospace-sidebar:// URL scheme.')"
    {{ cli }} notification push --severity high --title "High severity" --body "Orange, listed above normal notifications."
    open -g "$({{ cli }} notification url --severity critical --title 'Critical severity' --body 'Red, always on top. Sent through a URL.')"
    osascript -e 'display notification "A native macOS notification, intercepted and moved into the sidebar." with title "macOS notification" subtitle "Posted by osascript"'

# Tests run with a one-thread cooperative pool, so blocking calls on Swift's thread pool deadlock
# here instead of only on few-core CI runners.
test:
    LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test

# Run tests with coverage and enforce line and function minimums over Sources/
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --enable-code-coverage
    bin="$(swift build --show-bin-path)/aerospace-sidebarPackageTests.xctest/Contents/MacOS/aerospace-sidebarPackageTests"
    profdata="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
    ignore='(\.build|Tests)/'
    xcrun llvm-cov report "$bin" -instr-profile "$profdata" -ignore-filename-regex "$ignore"
    summary="$(xcrun llvm-cov export "$bin" -instr-profile "$profdata" -ignore-filename-regex "$ignore" -summary-only)"
    status=0
    while IFS= read -r source; do
        if ! jq -e --arg f "$PWD/$source" '.data[0].files | any(.filename == $f)' <<<"$summary" >/dev/null; then
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
