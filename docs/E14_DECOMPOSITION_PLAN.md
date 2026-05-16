# E14 — MainViewController decomposition (deferred)

`Sources/StowCore/MainViewController.swift` is at **1375 LOC** — was 1471
before B6's URL-utilities extraction. The class crosses many concerns and
deserves a split, but the swipe + page-transition code's coupling to view
layers, sub-controllers, and AppKit animation primitives means a refactor
needs interactive verification: clicking through every transition under
every state combination (settings ↔ workspace, workspace ↔ workspace,
last workspace → add-new bounce, cancelled gestures, hidden-window) to
catch any regression.

That verification loop isn't established in this session. **Deferring E14
until iOS sim infra (E15) lands and an equivalent Mac UI test path
exists.**

## Recommended split when picked back up

Five cohesive seams identified by the simplify-review Refactorer agent.
Tackle in this order — each unblocks the next:

1. **`PageTransitionController` (~340 LOC)** — `MainViewController.swift`
   lines 521-552 (page navigation utilities), 1155-1230 (swipe transition
   helpers), 1234-end (`ScrollWheelPageDelegate` conformance). The single
   largest cohesive chunk. Owns swipe state (`swipeStartPageIndex`,
   `swipeDirection`, `outgoingSnapshotView`, `preloadedPageIndex`).
   Talks back to `MainViewController` via a focused delegate protocol
   (view to host overlays, `nodeListViewController` reference, model
   accessor, `selectPage(index:)`, `showSettingsContent()`,
   `showWorkspaceContent()`).

2. **`WorkspaceCommands` (~280 LOC)** — `MainViewController.swift` lines
   574-854 (workspace context menu, custom-color flow, share/export/import
   alerts, share panel, move/delete). Pure command surface; talks to
   `model` and presents `NSPanel`/`NSAlert`. The Refactorer flagged
   that `showWorkspaceContextMenu` exists in three places near-identical
   — extracting also lets `SettingsContentViewController` consume the
   same `WorkspaceContextMenuBuilder`.

3. **`BrowserOpenCoordinator`** — `MainViewController.swift` lines
   968-998 (`openLink`, `openLinksInFolder`, `collectLinks`). Small but
   clean. Pure functions over the model + AppleScript service; no
   AppKit modal state.

4. **`ModalPresenter`** — consolidates the three `NSPanel` callers
   (snippet editor at ~1158, date picker at ~1082, share panel at
   ~712). All three share the floating-panel + retain-callback pattern,
   and the date-picker case uses `objc_setAssociatedObject` for state
   threading (the worst smell flagged in /simplify). One reference type
   that owns the panel as a stored property + closure-based completion
   replaces the associated-object glue at lines 1133-1137 and 772-773.

5. **Rename residual class to `WindowRootController`**. After (1)-(4)
   the remaining file is child-VC wiring, page-index → state mapping,
   search routing, and `bindModel` — no longer "main."

## Acceptance criteria

- All 138+ tests pass
- Mac app builds with `./scripts/build.sh`
- Manual swipe verification across every transition type
- AppleScript-driven UI test (E15 follow-up) covers the regression
  surface

## What this looks like in commits

5 commits, one per seam. Each ~200-400 LOC delta. Keep the original file
edited minimally per commit (remove method, leave call site touching
the new controller). Reviewers can read one seam at a time.
