# iOS Simulator Scenarios

Two end-to-end UI scenarios for the `ios-simulator-skill` plugin.
Each scenario specifies setup, steps, and a pass condition.

## Setup (every scenario)

```bash
# Build and locate the .app
APP=$(./scripts/build-ios.sh "iPhone 16")

# Boot the simulator
xcrun simctl boot "iPhone 16" 2>/dev/null || true
open -a Simulator

# Install
xcrun simctl install booted "$APP"
```

Set `STOW_SEED_FIXTURE` in the StowIOS scheme's environment to point at
the fixture file before launching the app — the app picks it up in
`AppViewModel.init` (DEBUG only) and overwrites the App Group
container's `data.json` so the run starts from a known state.

---

## Scenario 1 — Create workspace, add 5 links, drag-reorder, persist across relaunch

**Fixture:** `Tests/Fixtures/iOSSeed/empty-workspace.json` — a single
empty "Bookmarks" workspace.

**Steps:**

1. Launch the app with the empty-workspace fixture.
2. Tap the `+` in the top-right toolbar 5 times. Each time, fill the
   AddItemView's URL field with `https://test.example/N` (N = 1..5),
   leave title empty, tap Add.
3. Verify 5 rows appear in the list, ordered 1..5.
4. Long-press row 3 and drag it to position 1.
5. Verify the new order: 3, 1, 2, 4, 5.
6. Terminate the app (`xcrun simctl terminate booted com.stow.app`).
7. Relaunch.
8. **Pass condition:** the list still shows 3, 1, 2, 4, 5 in that order.

Tests: `AddItemView` wire-up (commit `2e60b5a`), drag reorder,
`AppModel.moveNode` persistence, `DataStore.save` on every mutation.

---

## Scenario 2 — Swipe-pager snap math

**Fixture:** `Tests/Fixtures/iOSSeed/five-link-workspace.json` — three
workspaces named Reading, Work, Tools.

**Steps:**

1. Launch with the three-workspace fixture; "Reading" is the initially
   selected workspace.
2. Read the current accessibility label of the page indicator
   (or workspace title at top) to confirm "Reading".
3. Swipe left with a short, fast velocity (just past
   `pageChangeThreshold` 0.15).
4. **Pass condition:** title becomes "Work". The pager committed to
   the next page.
5. Now swipe left with a slow velocity but only partial distance
   (under `pageChangeThreshold`).
6. **Pass condition:** title stays "Work" — pager snapped back.
7. Now swipe right past threshold.
8. **Pass condition:** title becomes "Reading" again.

Tests: `WorkspacePagerViewController.scrollViewWillEndDragging` snap
math, `ThemeConstants.Paging.pageChangeThreshold`, page-color
interpolation during gesture (visible).
