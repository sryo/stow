# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Stow is a macOS bookmark management application built with Swift and AppKit. It provides a workspace-based organization system for links and folders with features like drag-and-drop, inline editing, and automatic favicon/title fetching. (Forked from Arcmark.)

## Development Commands

### Building and Testing
```bash
# Development builds (ad-hoc signing)
./scripts/build.sh                  # Build app only
./scripts/build.sh --dmg            # Build app and create DMG

# Production builds (Developer ID + notarization)
./scripts/build.sh --production     # Build with Developer ID signing
./scripts/build.sh --production --dmg  # Build and create notarized DMG

# Other commands
./scripts/create-dmg.sh             # Create DMG from existing build
./scripts/run.sh                    # Build and run the app

# Testing
swift test                          # Run all tests
swift test --filter ModelTests.testJSONRoundTrip  # Run single test

# Library build (Swift PM only)
swift build -c release
```

**Build System:** The app uses Swift Bundler to create macOS app bundles. The build script automatically:
- Reads version from `VERSION` file and syncs to Bundler.toml
- Builds the app with Swift Bundler
- Patches Info.plist to ensure CFBundleIdentifier is present
- Code signs the app (ad-hoc for development, Developer ID for production)
- Verifies the build
- Optionally creates a DMG installer with `--dmg` flag
- Optionally notarizes the DMG with `--production --dmg`

**Production Signing**: For distribution outside the Mac App Store, use `--production` flag with proper code signing credentials configured in `.notarization-config`. See [docs/PRODUCTION_SIGNING.md](docs/PRODUCTION_SIGNING.md) for setup.

See [docs/BUILD_AND_CODESIGN.md](docs/BUILD_AND_CODESIGN.md) for detailed information about the build process, code signing, and verification.

### Version Management

The app version is managed through a centralized `VERSION` file in the project root. To update the version:

```bash
echo "0.2.0" > VERSION
```

The build script automatically reads this file and updates `Bundler.toml` and Info.plist accordingly. The version follows [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`.

For complete distribution workflow including DMG creation and beta testing, see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Architecture

### Data Flow Architecture

The application follows a unidirectional data flow pattern:

1. **AppModel** - Central state manager that owns `AppState` and coordinates all mutations
   - Single source of truth for application state
   - Exposes an `onChange` callback for UI updates
   - All state mutations go through AppModel methods (no direct state manipulation)
   - Automatically persists to disk via `DataStore` after every mutation

2. **DataStore** - Handles persistence layer
   - Saves/loads JSON to `~/Library/Application Support/Stow/data.json`
   - Manages favicon storage in `Icons/` subdirectory
   - Provides default state initialization

3. **MainViewController** - Primary UI controller
   - Observes AppModel via `onChange` callback
   - Manages NSCollectionView for hierarchical node display
   - Handles drag-and-drop, inline editing, and context menus
   - Never directly mutates state - always calls AppModel methods

### Core Data Model

The data model is defined in `Models.swift`:

- **AppState** - Root container holding workspaces, selected workspace ID, schema version, and settings selection state
- **Workspace** - Named container with color and hierarchical items
- **Node** - Enum representing a `Folder`, `Link`, `TaskItem`, or `Snippet`
  - `Folder` - Contains nested children and isExpanded state
  - `Link` - URL (String), title, and optional favicon path
  - `TaskItem` - Title, completion state, optional due date and notes
  - `Snippet` - Title, content, optional language, creation date

All models are Codable and use UUID-based identification. The Node enum uses custom encoding to serialize the tagged union structure.

### Key Components

**Services** (all MainActor singletons):
- **FaviconService** - Async favicon fetching with disk caching and failure cooldown
- **LinkTitleService** - HTML title extraction from URLs
- **BrowserManager** - Manages browser selection and URL opening
- **ShareService** - Workspace sharing via compressed URLs
- **WorkspaceExporter** - Exports workspaces with embedded favicons to JSON
- **WorkspaceImporter** - Imports workspace files and restores favicons

**UI Components**:
- **MainViewController** - The main window: elastic modes, the page chrome, data reload and the commands AppDelegate calls (~1400 lines). Its concerns live in:
  - **RailCoordinator** - Rail wiring, reload and visibility (the rail has no Settings page: its gear opens the app sheet)
  - **LinkActions** - Opening links and folders, stowing the front tab or a URL, title fetches
  - **KeyboardRouter** - Key and modifier monitors, ⌘-hold jump letters, ⌘J jump mode, "/" and Esc
  - **PageSwipeCoordinator** - Swipes between pages: snapshots, preloading, the `ScrollWheelPageDelegate`, reloads deferred to the snap
- **NodeListViewController** - Manages collection view, drag-drop, context menus (~1150 lines, extracted from MainViewController)
- **SearchCoordinator** - Handles search/filtering logic (extracted from MainViewController)
- **SettingsContentViewController** - The Settings page at list and sidebar widths: app settings only (the app sheet in page style and its footer). Workspaces are edited where they show, by right-click
- **NodeCollectionViewItem** - Reusable cell with icon, title, hover states, delete button
- **SnippetEditorView** - Editor UI for code snippets with language selection
- **SearchBarView** - Search field that filters nodes
- **FooterButton** - The bottom bar's "+ Stow this tab" and Paste; drops its keycap, then its title, as the list narrows
- **ListFlowLayout** - Custom NSCollectionViewLayout for vertical list
- **ScrollWheelPageController** - Scroll-wheel page navigation for workspace switching
- **RailView** - The 52pt rail: the gear (app sheet), the workspace chip (the Tabline's element: a click opens the shared workspace list, right-click or ⌃Return edits), item cells and their flyouts
- **WorkspaceListFlyout** - The list both workspace chips open (rail and Tabline): workspaces with ✓ and ⌘1–9, then Edit Workspace… and New workspace…
- **AppSheetFlyout** - The app sheet in a flyout hung off a gear: the rail's (beside the window) and the Tabline's (away from the strip's edge)
- **TablineController** / **TablineStripView** - The active workspace as a strip of tabs riding the front browser window; **TablineLayout** places its parts (gear, chip, tabs, waterfilled titles) as a pure function
- **OpenTabsMonitor** - One shared poll of the browsers' open tabs, for the open dots in the rail, list and Tabline

**Flyouts, menus and shared pieces** (left-click pop-ups are flyouts; right-click menus stay native):
- **FlyoutPanel** - Borderless child panel with a 12pt card and an arrow, beside a column or below an anchor; flips sides when the screen runs out
- **FlyoutController** - A stack of FlyoutPanels (a root plus pushed children) with one outside-click monitor and Esc routing
- **FlyoutListView** - The list inside a flyout (folder contents, tasks, snippets, workspaces), keyboard navigable
- **TextFieldFlyout** - One-field flyout for rename, Edit URL and new folder/task names (shown through `ItemFlyouts`)
- **WorkspaceEditorController** - The one workspace editor (name, colour, icon, Opens in, Open/Share/Export/Delete), owned by MainViewController. Share… pushes a **ShareCardView** beside it on the same flyout stack. A right-click on any workspace opens it beside what was clicked: a rail dot, a Color Strip tab, a "More workspaces" row, the Tabline chip or a row in its list. "New workspace…" (⌘N, the title "+", the rail's "+" dot, a swipe past the last page) opens it on a workspace that's created only on commit (Esc creates nothing)
- **NodeMenu** - The native right-click menu for an item, in the list, the mosaic and the rail
- **NewItemMenu** - The + / Add menu (folder, task, snippet, workspace, paste, import)
- **Toast** - Bottom-of-window message with an optional action (copy, archive undo, stow failures)
- **SiteGlyph** (StowShared) - The same letters and colour for a site everywhere a favicon is missing
- **WorkspaceMonogram** (StowShared) - One- or two-letter workspace monograms, shared with iPhone
- **WorkspaceDot** - The one workspace colour dot renderer

### UI Component Architecture (Post-Refactoring)

**Base Classes** (located in `Components/Base/`):
- **BaseControl** - Base class for all interactive controls with hover and pressed state management
  - Eliminates ~40 lines of tracking area and mouse event code per subclass
  - Provides `handleHoverStateChanged()` and `handlePressedStateChanged()` override points
  - Used by: `FooterButton`, `FocusableControl` (Tab-focusable controls in Settings and the flyouts)
- **BaseView** - Base class for custom views with hover state management (no pressed state)
  - Simpler than BaseControl, designed for non-interactive views like rows
  - Used by: `NodeRowView`, `RailCell`
- **InlineEditableTextField** - Reusable component for inline text editing
  - Encapsulates commit/cancel logic, focus management, and callbacks
  - Eliminates ~80 lines of duplicate editing code per component
  - Used by: `NodeRowView`, `WorkspaceStripView`

**Design System** (located in `Utilities/Theme/`):
- **ThemeConstants** - Centralized design system constants
  - Colors: Brand colors and semantic values (darkGray, white, settingsBackground)
  - Opacity: Standard opacity levels (full, high, medium, low, subtle, extraSubtle, minimal)
  - Fonts: Typography styles (bodyRegular, bodySemibold, bodyMedium, bodyBold)
  - Spacing: Layout spacing values (tiny=4, small=6, medium=8, regular=10, large=14, extraLarge=16, huge=20)
  - CornerRadius: Rounding values (small=6, medium=8, large=12)
  - Sizing: Standard sizes (iconSmall=14, iconMedium=18, iconLarge=22, buttonHeight=32, rowHeight=44)
  - Animation: Timing values (durationFast=0.15s, durationNormal=0.2s, durationSlow=0.3s)
  - Replaces 50+ hardcoded "magic numbers" throughout the codebase

**Component Patterns**:
All interactive controls extend BaseControl or BaseView and use ThemeConstants for consistency:

```swift
// Example: Custom button extending BaseControl
final class MyButton: BaseControl {
    override func handleHoverStateChanged() {
        layer?.backgroundColor = isHovered
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
            : NSColor.clear.cgColor
    }

    override func handlePressedStateChanged() {
        layer?.backgroundColor = isPressed
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.subtle).cgColor
            : NSColor.clear.cgColor
    }
}
```

### State Mutation Pattern

All mutations follow this pattern:
```swift
// 1. Validate preconditions
// 2. Call updateWorkspace or updateNode with closure
// 3. Closure modifies inout parameter
// 4. AppModel automatically persists and notifies observers
```

Examples:
- `addFolder(name:parentId:)` - Inserts new folder node
- `moveNode(id:toParentId:index:)` - Moves node in hierarchy, handles reordering logic
- `renameNode(id:newName:)` - Updates node display name
- `deleteNode(id:)` - Recursively removes node from tree

### Node Hierarchy Operations

The AppModel uses recursive tree traversal for node operations:
- `insertNode(_:parentId:index:nodes:)` - Recursive insertion into parent
- `updateNode(id:nodes:_:)` - Recursive update with mutation closure
- `removeNode(id:nodes:)` - Recursive removal returning deleted node
- `findNodeLocation(id:nodes:parentId:)` - Returns NodeLocation with parent ID and index

When moving nodes, the system:
1. Validates the move isn't to a descendant (prevents cycles)
2. Removes node from old location
3. Adjusts target index if needed (accounts for removal in same parent)
4. Inserts at new location

### UI Update Strategy

**Collection View Animations**:
- Calculates diff between old and new visible rows
- Uses `performBatchUpdates` for insertions/deletions
- Animates inserted rows with fade + slide from offset
- Creates bitmap snapshots for deletion animation
- Skips animations when query is active or window not visible

**Inline Rename**:
- Triggered via context menu or for new folders
- `scheduleInlineRename(for:)` sets `pendingInlineRenameId`
- After data reload, `handlePendingInlineRename()` activates edit mode
- Edit mode managed by NodeCollectionViewItem with commit/cancel callbacks

### Workspace Colors

WorkspaceColorId enum defines 8 color themes (Blush, Apricot, Butter, Leaf, Mint, Sky, Periwinkle, Lavender). Each color affects:
- Window background color (color at 0.92 alpha)
- View layer background color

### iOS App Architecture

The iOS app lives in `StowIOS/` and uses SwiftUI with the shared `StowShared` library.

**Key Components:**
- **StowApp** - App entry point with `NavigationSplitView`
- **AppViewModel** - `@Observable` wrapper around `AppModel` for SwiftUI reactivity
- **ContentView** - Root view with sidebar/detail split
- **NodeRowView** - Renders folder/link/task/snippet rows with inline rename
- **WorkspacePageView** - Swipeable workspace pages
- **PinnedLinksView** - Pinned links display

**Extensions:**
- **StowShareExtension** - iOS Share Sheet extension for saving URLs to the first workspace via App Group shared storage
- **StowWidget** - Home screen widget showing pinned links from the selected workspace

**Shared Data:**
- App Group `group.com.stow.app` enables data sharing between the main app, share extension, and widget
- Both extensions use `DataStore` with the App Group container directory
- CloudKit sync via `iCloud.com.stow.app` container

**Building iOS:**
```bash
# Build all iOS targets for simulator
xcodebuild -scheme StowIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Important Patterns

### AppKit-Specific Patterns
- Uses `@MainActor` extensively for UI thread safety
- Custom NSCollectionViewLayout for list metrics
- Context menus via NSMenuDelegate with dynamic population
- Drag-and-drop via NSPasteboardWriting/NSPasteboardReading

### State Management
- Never expose mutable state directly - only through methods
- Use `inout` parameters in private update methods for efficient mutations
- All persistence is automatic - callers never call save()
- Use `notify: false` parameter to suppress onChange callback if needed

### Search/Filter
- NodeFiltering recursively filters tree, expanding folders with matches
- MainViewController forces folder expansion when query is active
- Filtering preserves hierarchy (keeps parent folders if children match)
- The drag and drop is disabled when searching/filtering

### Testing
- Tests use temporary directory for DataStore to avoid polluting real data
- Model operations tested via AppModel integration (not isolated units)
- Tests verify both state mutation and JSON round-trip encoding
- Base class tests exist but are currently skipped due to Swift 6 concurrency requirements with XCTest
- ThemeConstants has comprehensive unit tests validating all design values

## Refactoring History

The codebase (originally Arcmark) underwent a comprehensive refactoring (2026-02-10) to eliminate code duplication and improve maintainability:

**Phase 1 - Foundation**:
- Created base classes: `BaseControl`, `BaseView`, `InlineEditableTextField`
- Created `ThemeConstants` for centralized design system
- Added comprehensive unit tests for all base classes

**Phase 2 - Component Migration**:
- Migrated 5 components to extend base classes
- Replaced hardcoded values with ThemeConstants references
- Eliminated ~520 lines of duplicate code

**Phase 3 - ViewController Decomposition**:
- Extracted `NodeListViewController` from `MainViewController` (~1150 lines)
- Extracted `SearchCoordinator` from `MainViewController` (~60 lines)
- Created `WorkspaceManagementView` for settings (~460 lines)

**Phase 4 - Remaining Components**:
- Migrated `SearchBarView` and `WorkspaceSwitcherView` to use ThemeConstants
- Migrated nested button classes in `WorkspaceSwitcherView` to extend BaseControl
- Eliminated ~205 additional lines of duplicate code

**Later cleanup (2026-10 review)**: removed the dead `IconTitleButton`, `CustomToggle`, `CustomTextButton`, `SidebarPositionSelector`/`SettingsSegmentedControl`, the `SettingsControls` family, `WorkspaceBarView`, `ContextMenuBuilder` and `StowTheme.Density`. Left-click pop-ups moved onto the Flyout components above.

**Phase 5 - Polish & Documentation**:
- Added comprehensive inline documentation to all base classes
- Enhanced ThemeConstants with detailed usage examples
- Updated CLAUDE.md with new architecture details
- Created component usage examples

**Total Impact**:
- **Code reduction**: ~1,145 lines eliminated (14.1% of original codebase)
- **Zero functional regressions**: All features work as before
- **Improved consistency**: All components use centralized design constants
- **Better maintainability**: Base classes eliminate duplicate patterns
- **Enhanced testability**: Clear separation of concerns with coordinator pattern
