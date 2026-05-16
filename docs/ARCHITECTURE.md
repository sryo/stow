# Stow Architecture

**Last updated:** 2026-05-16

## Overview

Stow is a workspace-based bookmark manager that runs on macOS (AppKit) and iOS
(SwiftUI), forked from `Geek-1001/arcmark`. Bookmarks are organized into
**workspaces** holding **nodes** — links, folders (nested), tasks, and code
snippets. State syncs across devices via CloudKit; the macOS app additionally
focuses already-open tabs in Safari / the Chromium family / Arc via
AppleScript.

## Module layout

Three Swift Package targets plus a sibling Xcode project for iOS-specific
surfaces.

```
Sources/StowShared/    Foundation-only domain layer. AppModel, models, persistence,
                      CloudKit sync, cross-platform services. Imports neither
                      AppKit nor UIKit. Used by every other target.

Sources/StowCore/     macOS AppKit UI on top of StowShared. View controllers,
                      browser/window integration, page transitions, settings.

Sources/StowApp/      Minimal macOS executable entry point. Wires AppDelegate +
                      MainViewController, hands the model to CloudSyncManager.

StowIOS/StowIOS/      SwiftUI iOS app (Xcode project). Depends only on
                      StowShared. Hosts WorkspacePagerViewController + SwiftUI
                      sheets. Three additional Xcode targets ship alongside:
                      StowShareExtension (URL share sheet → workspace) and
                      StowWidget (home-screen pinned-link widget).
```

`PlatformColor` / `PlatformFont` typealiases in `StowShared/PlatformTypes.swift`
let shared code traffic in colors and fonts without importing the wrong UI
framework. AppKit-only constants (pasteboard types, `LayoutConstants`,
`ListMetrics`) live in `Sources/StowCore/AppKitConstants.swift`.

## Data model

```swift
AppState                      // root container, persisted to data.json
├── schemaVersion: Int
├── workspaces: [Workspace]
├── selectedWorkspaceId: UUID?
└── isSettingsSelected: Bool

Workspace
├── id: UUID
├── name: String
├── colorId: WorkspaceColorId      // 8 named tints + .settingsBackground + .custom(hex)
├── items: [Node]
├── browserProfiles: [String: String]  // bundleId → profileDir; macOS only
└── isArchiveExpanded: Bool

Node
├── .folder(Folder)                   // id, name, children: [Node], isExpanded, isArchived
├── .link(Link)                       // id, title, url, faviconPath?, isArchived
├── .task(TaskItem)                   // id, title, isCompleted, dueDate?, notes?, createdAt, isArchived
└── .snippet(Snippet)                 // id, title, content, language?, createdAt, isArchived
```

## State management

```
User action  →  AppModel mutation  →  persist()
                                       ├── DataStore.save  →  data.json
                                       ├── onChange?()      ←  legacy single-subscriber
                                       └── changes.send()   ←  multicast publisher (Combine)
                                                                ├── iOS AppViewModel.objectWillChange
                                                                └── (future subscribers)
```

`AppModel.persist` asserts `dispatchPrecondition(.onQueue(.main))` — every
mutation must originate from the main thread. CloudKit deletion scheduling is
factored out via `AppModel.deletionScheduler: ((Set<UUID>) -> Void)?`, which Mac
`AppDelegate` and iOS `AppViewModel` wire to `CloudSyncManager.shared.scheduleDeletion`
after configuration. Tests intercept it to verify deletion sets without
touching real CloudKit.

`DataStore.load` preserves corrupt or future-schema files as
`data.json.corrupt-<timestamp>-<reason>` instead of overwriting them — the
previous silent-fallback behavior could destroy a user's data on the next save.

## CloudKit sync

`Sources/StowShared/Sync/` houses three files:

- `CloudKitRecordMapping.swift` — record-type / field-key constants
- `RecordConverter.swift` — `Node`/`Workspace` ↔ `CKRecord` conversion
- `CloudSyncManager.swift` — `CKSyncEngine` host; receives remote changes,
  buffers parent-arrives-late children, applies merges via the
  `AppModel.*FromSync` family

`AppModel` exposes a sync-side API distinct from local mutations:
`upsertNodeFromSync`, `mergeWorkspaceMetadataFromSync`,
`reorderNodesFromSync`, `reorderWorkspacesFromSync`,
`deleteNodeFromAnyWorkspace`, `deleteWorkspaceFromSync`. The upsert path
guards against self-parenting and folder cycles before insertion.

iOS uses an App Group container (`group.com.stow.app`) so the share extension
and widget see the same `data.json`.

## macOS UI

`MainViewController` is still the central coordinator — owns child VCs
(`NodeListViewController`, `SettingsContentViewController`), the workspace
switcher, the search bar, and the scroll-wheel page controller. A
decomposition plan exists in [`E14_DECOMPOSITION_PLAN.md`](E14_DECOMPOSITION_PLAN.md);
the split is gated on having an interactive UI-test loop to verify the swipe
transitions don't regress.

Key collaborators in `Sources/StowCore/`:

| File | Responsibility |
|---|---|
| `BrowserManager.swift` | Resolve default browser, open URLs with profile arg |
| `BrowserTabService.swift` | AppleScript-driven enumeration + focus of already-open tabs across Safari/Chromium/Arc; `focusIfOpen(url:)` runs queries concurrently per browser |
| `WindowAttachmentService.swift` | Attach Stow as a sibling sidebar to the active browser window via Accessibility API |
| `GlobalHotkeyService.swift` | Carbon hotkey registration for show/hide toggle |
| `ScrollWheelPageController.swift` | Trackpad two-finger swipe between workspace pages |
| `FaviconService.swift` | Async favicon fetch + on-disk cache |
| `LinkTitleService.swift` | HTML `<title>` extraction for new links |
| `ArcImportService.swift` | Parse Arc's `StorableSidebar.json` (see `ARC_IMPORT_ARCHITECTURE.md`) |
| `ShareService.swift` | Compress + base64url-encode a workspace into a `stow://` link |
| `WorkspaceExporter` / `WorkspaceImporter` | `.stow` file round-trip with embedded favicons |

The component base classes (`BaseControl`, `BaseView`,
`InlineEditableTextField`) and the design system (`ThemeConstants`) are
documented separately in [`COMPONENT_USAGE_GUIDE.md`](COMPONENT_USAGE_GUIDE.md).

## iOS UI

SwiftUI throughout, with one UIKit bridge for the inter-workspace pager:

```
StowApp.swift
└── ContentView                      // device size routing (iPad split / iPhone stack)
    └── WorkspacePageView            // toolbar + + button + bulk-select edit mode
        ├── WorkspacePagerRepresentable
        │   └── WorkspacePagerViewController  (UIPageViewController)
        │       └── NodeListView     // per workspace
        │           └── NodeRowView  // link / folder / task / snippet
        ├── AddItemView              // sheet — manual add (link/folder/task/snippet)
        ├── BulkActionBar            // bottom overlay during selection
        ├── WorkspaceOverviewSheet   // workspace grid + context menu
        │   └── AboutSheet           // gear icon → version + GitHub link
        └── ContextMenu              // archive / unarchive / permanent delete
```

`AppViewModel` is the SwiftUI bridge into `AppModel`. It subscribes to
`model.changes` and forwards via `objectWillChange.send()` — the older
`refreshTrigger.toggle()` pattern that required every view to read a sentinel
`@Published` is gone. Bulk-select state (`isSelecting`, `selectedNodeIds`)
lives on `AppViewModel` because SwiftUI's `EditMode` environment doesn't
propagate through the UIPageViewController bridge.

`adaptiveBackgroundColor` on `WorkspaceColorId` returns dynamic light/dark
colors on both platforms — macOS adopted this in 2026-05 so workspace tints
no longer wash out in dark mode.

## Shared services

`Sources/StowShared/`:

| File | Used by |
|---|---|
| `AppModel.swift`, `DataStore.swift`, `Models.swift` | Everything |
| `NodeFiltering.swift` | Mac search bar + iOS `.searchable` |
| `NodeTraversal.swift` | `Node.flattenLinks()`, `Node.flattenIds()`, `Link.displayDomain`, `Array<Workspace>.first(id:)`/`firstIndex(id:)` |
| `ClipboardImportParser.swift` | Mac `MainViewController.importClipboardContent` + iOS `WorkspacePageView.importClipboardContent` |
| `WorkspaceColor.swift` | Both platforms |
| `Utilities/Theme/ThemeConstants.swift` | Both platforms |
| `Sync/*` | Both platforms |
| `ShareService.swift`, `WorkspaceExporter.swift`, `WorkspaceImporter.swift` | Mac (full); iOS uses `ShareService` via `ShareLink` |
| `FaviconService.swift`, `LinkTitleService.swift`, `ArcImportService.swift` | Mac (iOS bundles them but doesn't currently surface) |
| `SnippetTitleDerivation.swift` | Both platforms |

## Testing

`swift test --parallel` runs **138** cases across `StowSharedTests` and
`StowTests`. CI on `main` and PRs via `.github/workflows/test.yml`. Test
fixtures live in `Tests/Fixtures/` (organized by suite). iOS-side scenarios
for the `ios-simulator-skill` plugin are specified in
[`ios_scenarios.md`](ios_scenarios.md).

`scripts/test.sh` wraps the layers: `unit`, `integration` (CloudKit dev
container — gated by `STOW_CLOUDKIT_INTEGRATION=1`), `ios` (builds the
app via `scripts/build-ios.sh`), `mac-ui` (stub).

## Build

```bash
./scripts/build.sh        # macOS .app bundle via swift-bundler
./scripts/run.sh          # build + launch
./scripts/build-ios.sh    # iOS simulator build via xcodebuild
swift test --parallel     # unit suite
```

See [`BUILD_AND_CODESIGN.md`](BUILD_AND_CODESIGN.md) for the bundler config,
signing identities, and the Info.plist patch sequence
(swift-bundler v2.0.7 doesn't merge `[apps.*.plist]` reliably; `build.sh`
patches `CFBundleIdentifier`, `CFBundleURLTypes`, and
`NSAppleEventsUsageDescription` post-bundle).

## Dependencies

- Swift 6.2 with strict concurrency
- AppKit (macOS) / SwiftUI + UIKit (iOS)
- Combine (publisher in `AppModel`)
- Swift Bundler 2.x (macOS only, via mint)
- No external Swift packages beyond the build tooling

## Resources

- [`CLAUDE.md`](../CLAUDE.md) — assistant-facing development notes
- [`COMPONENT_USAGE_GUIDE.md`](COMPONENT_USAGE_GUIDE.md) — `BaseControl`/`BaseView`/`ThemeConstants` patterns
- [`BUILD_AND_CODESIGN.md`](BUILD_AND_CODESIGN.md) — build + signing details
- [`E14_DECOMPOSITION_PLAN.md`](E14_DECOMPOSITION_PLAN.md) — pending `MainViewController` split
- [`ios_scenarios.md`](ios_scenarios.md) — iOS sim end-to-end scenarios
- [`ARC_IMPORT_ARCHITECTURE.md`](ARC_IMPORT_ARCHITECTURE.md) — Arc browser import internals
