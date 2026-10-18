#!/usr/bin/env bash
# Build, launch and drive ProductivityApp in the iOS Simulator.
# Run from the repo root: .claude/skills/run-productivityapp/driver.sh <command> [args]
set -euo pipefail

BUNDLE_ID=com.nazmulhoque.productivityapp
DEVICE_NAME=${DEVICE_NAME:-"iPhone 17 Pro"}
DERIVED=.build/DerivedData
APP=$DERIVED/Build/Products/Debug-iphonesimulator/ProductivityApp.app
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
    xcodebuild -project ProductivityApp.xcodeproj -scheme ProductivityApp \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" build 2>&1 |
      grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    [ -d "$APP" ]
    ;;
  launch)  # launch [--fresh]  (--fresh uninstalls first: wipes data, re-seeds sample data)
    boot
    if [ "${1:-}" = "--fresh" ]; then xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || true; fi
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
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
  *)
    sed -n '2,3p' "$0"
    echo "commands: setup | build | launch [--fresh] | allow | ui | tap <label> [Type] | tap <x> <y> | back | type <text> | ss [name] | smoke | stop"
    ;;
esac
