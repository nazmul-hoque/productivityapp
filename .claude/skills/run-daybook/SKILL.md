---
name: run-daybook
description: Build, run, launch, drive, tap through, screenshot or smoke-test the Daybook SwiftUI iOS app in the iOS Simulator (XcodeGen + xcodebuild + simctl + AXe). Use when asked to run the app, check a UI change in the simulator, or take screenshots.
---

# Run Daybook (iOS Simulator)

SwiftUI iOS 17+ app (`App/`) on top of the `Packages/TaskCore` logic package. On macOS it is driven
by `.claude/skills/run-daybook/driver.sh`: it wraps `xcodegen`, `xcodebuild`, `xcrun simctl`
and [AXe](https://github.com/cameroncooke/AXe), a CLI that taps, types and reads the accessibility
tree of a booted simulator. All paths are relative to the repo root. macOS + Xcode only (verified on
Xcode 26.3, iOS 26.3 simulator, iPhone 17 Pro).

## Prerequisites

```bash
.claude/skills/run-daybook/driver.sh setup   # brew installs xcodegen, axe (cameroncooke/axe tap), jq if missing
```

## Build

```bash
.claude/skills/run-daybook/driver.sh build   # xcodegen + xcodebuild into .build/DerivedData
```

Prints `** BUILD SUCCEEDED **` or the `error:` lines. Re-run after any source change. `xcodegen`
runs every time, so added and removed files are picked up.

## Run (agent path)

```bash
D=.claude/skills/run-daybook/driver.sh
$D smoke                      # whole flow: fresh install -> quick-add "Call Sam tomorrow..." -> check Upcoming -> "SMOKE OK"

$D launch --fresh             # boot sim, uninstall (wipes data -> sample data re-seeded), install, launch
$D launch --fresh --onboarding  # same, but show the first-launch pages (skipped by default via -hasSeenOnboarding YES)
$D allow                      # tap Allow on the notification prompt (appears once, after the first reminder is added)
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

## Recipes: widgets, notifications, share sheet, gestures

Everything outside the app's own screens. Coordinates are for iPhone 17 Pro.

```bash
$D home                                   # go to the Home Screen
$D pid                                    # app's process id: same after a resume, new after a relaunch
$D db "select title, status, start_date from todo where status = 'open';"   # the app's SQLite (App Group)
$D widget-add medium                      # add the Today widget (small | medium | large) to the Home Screen
$D notify "Plan the week" Tomorrow        # test reminder for that to-do, then tap its action
                                          #   (Snooze 1 Hour | Tomorrow | Complete; omit to just show it)
$D share-url https://www.swift.org        # share a page from Safari to Daybook; the form stays open:
$D tap 95 437; $D tap 354 110             #   pick Today, then Add  (Inbox is 95,385; Cancel 65,110)
$D drag-path 3 354,788 250,450 250,830    # drag + up the list, back to the bottom edge, hold 3 s, drop
```

- **Check results in the database, not only on screen.** `db` shows what a widget button, a
  notification action or the share extension actually wrote.
- **Resume vs. relaunch:** to test that the app picks up changes made elsewhere (widget, share
  sheet), note `pid`, make the change, bring the app back by tapping its icon (`home`, then its
  position on the Home Screen, or the "◀ Daybook" link in the status bar), and check `pid` again.
  `launch` always relaunches.
- **To look at the screen mid-gesture,** run `drag-path` in the background (`&`), `sleep`, then
  `ss`. Each step of `drag-path` takes a few hundred milliseconds, so allow for it.
- **Lock Screen widgets** aren't scripted (AXe's taps in the editor are unreliable). By hand:
  `axe button lock` twice (lock, wake), long-press (200,400) for 1.5 s, tap *Customize*, then
  *Add Widget* (the slot below the clock), scroll the list to *Daybook*, tap the circular and
  rectangular previews, close, *Done*. The inline widget (above the clock) is offered there but
  never got applied by automation; check it by hand.

## Run (human path)

`xcodegen && open Daybook.xcodeproj`, pick an iPhone simulator, then press ⌘R.

## Test

```bash
swift test --package-path Packages/TaskCore   # all logic tests; CI runs them too
scripts/test-supabase.sh                      # sync SQL against Postgres (needs Docker)
scripts/test-sync-e2e.sh                      # devices -> PostgREST -> Postgres (needs Docker)
```

Most logic changes (parsing, repeat rules, smart lists) land in TaskCore. Run the tests for those
and use the simulator only for UI changes.

## Gotchas

- **The notification prompt is outside the app's accessibility tree.** It is a SpringBoard alert, so
  `axe tap --label Allow` reports "No accessibility element matched". `allow` taps the button by
  point (275,517). Those coordinates are for iPhone 17 Pro; on another device read them off a
  screenshot (pixels ÷ 3 = points).
- **The prompt appears when the first to-do with a reminder is saved, not at launch.** On a fresh
  install, quick-adding text with a time ("at 10am") brings it up about 300ms after Add. If no prompt
  is showing, `allow` taps the app instead (the Logbook row on the Lists screen).
- **`ui` lists covered views too.** While a sheet is open, `describe-ui` still returns the Lists
  rows underneath it, so a label can match two elements. Add the element type
  (`tap Add Button`) to disambiguate.
- **`axe type` sends hardware-keyboard events.** The text goes in correctly, but the on-screen
  keyboard disappears in screenshots. That is expected.
- **`notify` needs notification permission.** After `launch --fresh` the app hasn't asked yet, and
  iOS silently drops the test reminder. Add a to-do with a time and run `allow` first (`smoke` does).
- **The notification banner disappears after a few seconds.** `notify` long-presses it 0.8 s after
  sending; a slower long-press lands on the Home Screen and starts icon editing (tap `Done`).
- **AXe can't see inside the share extension** (its own process): tap its form by position.
- **`ui` lists rows that have scrolled off screen.** To check scrolling, look at a screenshot.
- **Auto-scroll while dragging + starts only after the finger has left both edge zones once**, so
  a straight drag from the button to the bottom edge never scrolls. Go up first (see `drag-path`).
- **The `.xcodeproj` is generated and git-ignored.** Don't edit it; change `project.yml`.
- **Build output goes to `.build/`,** which is git-ignored, so it never collides with Xcode's own
  DerivedData.

## Troubleshooting

- `Entitlements file "Daybook.entitlements" was modified during the build` (file unchanged in
  git) → Xcode's cached build plan is stale, typically after a branch switch or merge rewrote the file.
  It only shows up under some shells (the driver's bash, not zsh). Fix:
  `rm -rf .build/DerivedData/Build/Intermediates.noindex/XCBuildData`, then build again.
- `xcodegen: command not found` → `driver.sh setup` (or `brew install xcodegen`).
- `No available simulator named 'iPhone 17 Pro'` → `xcrun simctl list devices available`, then set
  `DEVICE_NAME`.
- `Error: No accessibility element matched --label ...` → run `$D ui` to see what is on screen. A
  sheet or alert is probably covering the element.
