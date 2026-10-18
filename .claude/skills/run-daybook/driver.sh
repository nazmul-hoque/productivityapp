#!/usr/bin/env bash
# Build, launch and drive Daybook in the iOS Simulator.
# Run from the repo root: .claude/skills/run-daybook/driver.sh <command> [args]
set -euo pipefail

BUNDLE_ID=com.nazmulhoque.daybook
DEVICE_NAME=${DEVICE_NAME:-"iPhone 17 Pro"}
DERIVED=.build/DerivedData
APP=$DERIVED/Build/Products/Debug-iphonesimulator/Daybook.app
SHOTS=${SHOTS:-.build/screenshots}

udid() {
  xcrun simctl list devices available -j |
    jq -r --arg n "$DEVICE_NAME" '[.devices[][] | select(.name == $n)][0].udid // empty'
}

need_udid() {
  UDID=$(udid)
  [ -n "$UDID" ] || { echo "No available simulator named '$DEVICE_NAME' (set DEVICE_NAME)" >&2; exit 1; }
}

boot() {
  need_udid
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  open -a Simulator
}

cmd=${1:-help}; shift || true
case "$cmd" in
  setup)
    command -v xcodegen >/dev/null || brew install xcodegen
    command -v axe >/dev/null || brew install cameroncooke/axe/axe
    command -v jq >/dev/null || brew install jq
    ;;
  build)
    need_udid
    xcodegen --quiet
    xcodebuild -project Daybook.xcodeproj -scheme Daybook \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" build 2>&1 |
      grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    [ -d "$APP" ]
    ;;
  launch)  # launch [--fresh] [--onboarding]  (--fresh: wipe data, re-seed samples; --onboarding: show first-launch pages)
    boot
    skip=(-hasSeenOnboarding YES)
    for arg in "$@"; do
      case "$arg" in
        --fresh) xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || true ;;
        --onboarding) skip=() ;;
      esac
    done
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" "${skip[@]+"${skip[@]}"}"
    sleep 2
    ;;
  allow)  # tap Allow on the notification prompt (SpringBoard alert, not in the app's a11y tree)
    need_udid
    axe tap -x 275 -y 517 --udid "$UDID"
    ;;
  ui)  # compact list of labelled elements: type, label, id, x,y (points)
    need_udid
    axe describe-ui --udid "$UDID" | jq -r '.. | objects
      | select(.AXLabel? != null and .type != "Application")
      | "\(.type)\t\(.AXLabel)\t\(.AXUniqueId // "")\t\(.frame.x|floor),\(.frame.y|floor)"'
    ;;
  tap)  # tap <label> [ElementType]   |   tap <x> <y>
    need_udid
    if [[ "${1:-}" =~ ^[0-9.]+$ && "${2:-}" =~ ^[0-9.]+$ ]]; then
      axe tap -x "$1" -y "$2" --udid "$UDID"
    elif [ -n "${2:-}" ]; then
      axe tap --label "$1" --element-type "$2" --wait-timeout 5 --udid "$UDID"
    else
      axe tap --label "$1" --wait-timeout 5 --udid "$UDID"
    fi
    sleep 1
    ;;
  back)
    need_udid
    axe tap --id BackButton --wait-timeout 5 --udid "$UDID"; sleep 1
    ;;
  type)
    need_udid
    axe type "$1" --udid "$UDID"
    ;;
  ss)  # ss [name]  -> prints the PNG path
    need_udid
    mkdir -p "$SHOTS"
    out="$SHOTS/${1:-shot-$(date +%H%M%S)}.png"
    axe screenshot --udid "$UDID" --output "$out" >/dev/null 2>&1
    echo "$out"
    ;;
  smoke)  # end-to-end: fresh launch, quick-add a to-do, verify it lands in Upcoming
    "$0" launch --fresh
    "$0" tap "New To-Do"
    "$0" type 'Call Sam tomorrow at 10am #phone /Work'
    sleep 1; "$0" ss quickadd
    "$0" tap Add Button
    sleep 1; "$0" allow  # the first reminder triggers the notification prompt
    "$0" tap Upcoming Button
    "$0" ss upcoming
    if "$0" ui | grep -q 'Call Sam'; then echo "SMOKE OK"; else echo "SMOKE FAILED" >&2; exit 1; fi
    ;;
  stop)
    need_udid
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true
    ;;

  # --- Recipes: system UI around the app (coordinates are for iPhone 17 Pro) ---

  home)
    need_udid
    axe button home --udid "$UDID" >/dev/null; sleep 1
    ;;
  pid)  # the app's process id, empty if not running; unchanged across a resume, new after a relaunch
    need_udid
    xcrun simctl spawn "$UDID" launchctl list | awk -v id="$BUNDLE_ID" 'index($3, "UIKitApplication:" id "[") == 1 && $1 != "-" { print $1 }'
    ;;
  db)  # db "<sql>"  -> runs against the app's database in the App Group container
    need_udid
    db=""
    for dir in ~/Library/Developer/CoreSimulator/Devices/"$UDID"/data/Containers/Shared/AppGroup/*/; do
      id=$(plutil -extract MCMMetadataIdentifier raw "$dir/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)
      [ "$id" = "group.$BUNDLE_ID" ] && db="$dir/Database/tasks.sqlite"
    done
    [ -f "$db" ] || { echo "No database yet; launch the app once" >&2; exit 1; }
    sqlite3 "$db" "$1"
    ;;
  widget-add)  # widget-add [small|medium|large]  -> adds the Today widget to the current Home Screen page
    need_udid
    pages=0; case "${1:-medium}" in small) pages=0 ;; medium) pages=1 ;; large) pages=2 ;; esac
    "$0" home
    axe touch -x 200 -y 520 --down --up --delay 1.5 --udid "$UDID" >/dev/null; sleep 1  # long-press empty space
    axe tap --label Edit --element-type Button --wait-timeout 5 --udid "$UDID" >/dev/null; sleep 1
    axe tap --label "Add Widget" --wait-timeout 5 --udid "$UDID" >/dev/null; sleep 2
    axe tap -x 200 -y 172 --udid "$UDID" >/dev/null; sleep 1   # gallery search field
    axe type Daybook --udid "$UDID" >/dev/null; sleep 1.5
    axe tap -x 140 -y 253 --udid "$UDID" >/dev/null; sleep 2.5  # first search result
    for _ in $(seq 1 "$pages"); do
      axe swipe --start-x 330 --start-y 520 --end-x 70 --end-y 520 --udid "$UDID" >/dev/null; sleep 1
    done
    axe tap --label "Add Widget" --wait-timeout 5 --udid "$UDID" >/dev/null; sleep 2
    axe tap --label Done --element-type Button --wait-timeout 5 --udid "$UDID" >/dev/null; sleep 3
    ;;
  notify)  # notify "<to-do title>" [Snooze 1 Hour|Tomorrow|Complete]  -> test reminder; with an action, taps it
    need_udid
    id=$("$0" db "select id from todo where title = '${1//\'/\'\'}' and status = 'open' limit 1;")
    [ -n "$id" ] || { echo "No open to-do titled '$1'" >&2; exit 1; }
    payload=$(mktemp)
    jq -n --arg t "$1" --arg id "$id" '{aps: {alert: {title: $t}, category: "reminder", sound: "default"}, todoID: $id}' > "$payload"
    xcrun simctl push "$UDID" "$BUNDLE_ID" "$payload" >/dev/null; rm -f "$payload"
    if [ -n "${2:-}" ]; then
      # The banner lasts a few seconds: long-press it at once to show the actions.
      sleep 0.8
      axe touch -x 200 -y 75 --down --up --delay 1.0 --udid "$UDID" >/dev/null; sleep 1.2
      axe tap --label "$2" --element-type Button --wait-timeout 3 --udid "$UDID" >/dev/null
      sleep 3  # the app handles the action in the background, then saves
    fi
    ;;
  share-url)  # share-url <url>  -> opens it in Safari and shares it to Daybook; leaves the extension's form open
    need_udid
    xcrun simctl openurl "$UDID" "$1"; sleep 5
    axe tap -x 343 -y 815 --udid "$UDID" >/dev/null; sleep 1.5   # Safari's "…" button
    axe tap --label Share --element-type Button --wait-timeout 5 --udid "$UDID" >/dev/null; sleep 3
    axe tap -x 245 -y 653 --udid "$UDID" >/dev/null; sleep 3     # Daybook, third in the app row
    # The form runs in the extension's own process, so AXe can't see it; tap by position:
    # Inbox (95,385), Today (95,437), Cancel (65,110), Add (354,110).
    ;;
  drag-path)  # drag-path <hold-seconds> x,y x,y ...  -> drag through the points, hold at the last, release
    need_udid
    hold=$1; shift
    first=$1; shift
    steps=(--step "touch -x ${first%,*} -y ${first#*,} --down")
    last=$first
    for point in "$@"; do  # a touch-down while already down moves the finger
      steps+=(--step "touch -x ${point%,*} -y ${point#*,} --down"); last=$point
    done
    steps+=(--step "sleep $hold" --step "touch -x ${last%,*} -y ${last#*,} --up")
    axe batch --udid "$UDID" "${steps[@]}" >/dev/null
    ;;
  *)
    sed -n '2,3p' "$0"
    echo "commands: setup | build | launch [--fresh] [--onboarding] | allow | ui | tap <label> [Type] | tap <x> <y> | back | type <text> | ss [name] | smoke | stop"
    echo "recipes:  home | pid | db <sql> | widget-add [small|medium|large] | notify <title> [action] | share-url <url> | drag-path <hold> x,y ..."
    ;;
esac
