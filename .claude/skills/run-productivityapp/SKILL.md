---
name: run-productivityapp
description: Build, run, launch, drive, tap through, screenshot or smoke-test the ProductivityApp SwiftUI iOS app in the iOS Simulator (XcodeGen + xcodebuild + simctl + AXe). Use when asked to run the app, check a UI change in the simulator, or take screenshots.
---

# Run ProductivityApp (iOS Simulator)

SwiftUI iOS 17+ app (`App/`) on top of the `Packages/TaskCore` logic package. On macOS it is driven
by `.claude/skills/run-productivityapp/driver.sh`: it wraps `xcodegen`, `xcodebuild`, `xcrun simctl`
and [AXe](https://github.com/cameroncooke/AXe), a CLI that taps, types and reads the accessibility
tree of a booted simulator. All paths are relative to the repo root. macOS + Xcode only (verified on
Xcode 26.3, iOS 26.3 simulator, iPhone 17 Pro).

## Prerequisites

```bash
.claude/skills/run-productivityapp/driver.sh setup   # brew installs xcodegen, axe (cameroncooke/axe tap), jq if missing
```

## Build

```bash
.claude/skills/run-productivityapp/driver.sh build   # xcodegen + xcodebuild into .build/DerivedData
```

Prints `** BUILD SUCCEEDED **` or the `error:` lines. Re-run after any source change. `xcodegen`
runs every time, so added and removed files are picked up.

## Run (agent path)

```bash
D=.claude/skills/run-productivityapp/driver.sh
$D smoke                      # whole flow: fresh install -> quick-add "Call Sam tomorrow..." -> check Upcoming -> "SMOKE OK"

$D launch --fresh             # boot sim, uninstall (wipes data -> sample data re-seeded), install, launch
$D allow                      # dismiss the first-launch notification prompt (needed after --fresh)
$D ui                         # labelled elements: type<TAB>label<TAB>id<TAB>x,y   (points)
$D tap "New To-Do"            # tap by accessibility label
$D tap Add Button             # label + element type when the label is ambiguous
$D tap 201 333                # tap by point coordinates
$D back                       # navigation back button
$D type 'Buy milk #errand'    # type into the focused field
$D ss upcoming                # screenshot -> .build/screenshots/upcoming.png (then Read it)
$D stop
```

`launch` without `--fresh` keeps existing data and only reinstalls the new build. Use a different
simulator with `DEVICE_NAME="iPhone 17" $D ...`.

Useful labels on the Lists screen: `Inbox`, `Today`, `Upcoming`, `Anytime`, `Someday`, `Logbook`,
`Trash`, `Get to know the app`, `Personal`, `Work`, `New To-Do` (blue +), `New List`, `Quick Find`.
In the quick-add sheet: `Cancel`, `Add`.

## Run (human path)

`xcodegen && open ProductivityApp.xcodeproj`, pick an iPhone simulator, then press ⌘R.

## Test

```bash
swift test --package-path Packages/TaskCore   # 54 tests; this is also what CI runs (Linux, swift:6.0)
```

Most logic changes (parsing, repeat rules, smart lists) land in TaskCore. Run the tests for those
and use the simulator only for UI changes.

## Gotchas

- **The notification prompt is outside the app's accessibility tree.** It is a SpringBoard alert, so
  `axe tap --label Allow` reports "No accessibility element matched". `allow` taps the button by
  point (275,517). Those coordinates are for iPhone 17 Pro; on another device read them off a
  screenshot (pixels ÷ 3 = points).
- **If no prompt is showing, `allow` taps the app instead.** That point is the Logbook row on the
  Lists screen, so a stray `allow` navigates to Logbook. Only call it right after `launch --fresh`.
- **`ui` lists covered views too.** While a sheet is open, `describe-ui` still returns the Lists
  rows underneath it, so a label can match two elements. Add the element type
  (`tap Add Button`) to disambiguate.
- **`axe type` sends hardware-keyboard events.** The text goes in correctly, but the on-screen
  keyboard disappears in screenshots. That is expected.
- **The `.xcodeproj` is generated and git-ignored.** Don't edit it; change `project.yml`.
- **Build output goes to `.build/`,** which is git-ignored, so it never collides with Xcode's own
  DerivedData.

## Troubleshooting

- `Entitlements file "ProductivityApp.entitlements" was modified during the build` (file unchanged in
  git) → Xcode's cached build plan is stale, typically after a branch switch or merge rewrote the file.
  It only shows up under some shells (the driver's bash, not zsh). Fix:
  `rm -rf .build/DerivedData/Build/Intermediates.noindex/XCBuildData`, then build again.
- `xcodegen: command not found` → `driver.sh setup` (or `brew install xcodegen`).
- `No available simulator named 'iPhone 17 Pro'` → `xcrun simctl list devices available`, then set
  `DEVICE_NAME`.
- `Error: No accessibility element matched --label ...` → run `$D ui` to see what is on screen. A
  sheet or alert is probably covering the element.
