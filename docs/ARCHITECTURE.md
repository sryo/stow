# Stow Architecture

**Last Updated:** 2026-02-10
**Status:** Post-Refactoring (All 5 Phases Complete)

## Overview

Stow is a macOS bookmark management application built with Swift and AppKit. It uses a workspace-based organization system with hierarchical folders and links, featuring drag-and-drop, inline editing, and automatic favicon/title fetching.

## Architecture Patterns

### 1. Unidirectional Data Flow

```
User Action → MainViewController → AppModel → AppState → DataStore → Disk
                     ↑                                        ↓
                     └──────── onChange callback ─────────────┘
```

- **AppModel**: Single source of truth, owns AppState
- **AppState**: Immutable data model (Codable)
- **DataStore**: Persistence layer (JSON + favicon storage)
- **MainViewController**: UI coordinator, observes AppModel via onChange callback

### 2. Component Architecture (Post-Refactoring)

**Base Classes** eliminate code duplication:
- `BaseControl`: Interactive controls with hover + pressed states (~40 lines saved per subclass)
- `BaseView`: Non-interactive views with hover state only (~40 lines saved per subclass)
- `InlineEditableTextField`: Reusable inline editing component (~80 lines saved per usage)

**Design System** ensures consistency:
- `ThemeConstants`: Centralized colors, fonts, spacing, opacity, animations
- Replaces 50+ hardcoded "magic numbers" throughout codebase

## Project Structure

```
Sources/StowCore/
├── Components/
│   ├── Base/
│   │   ├── BaseControl.swift              # Base for interactive controls
│   │   ├── BaseView.swift                 # Base for custom views
│   │   └── InlineEditableTextField.swift  # Reusable inline editing
│   └── Settings/
│       └── WorkspaceManagementView.swift  # Workspace list in settings (~460 lines)
├── ViewControllers/
│   ├── NodeListViewController.swift       # Collection view, drag-drop, context menus (~1150 lines)
│   └── SearchCoordinator.swift            # Search/filtering logic (~60 lines)
├── Utilities/
│   └── Theme/
│       └── ThemeConstants.swift           # Design system constants
│
│  (remaining files are at the root level)
│
├── AppDelegate.swift                      # App lifecycle
├── MainViewController.swift               # Main coordinator (~1240 lines)
├── Models.swift                           # AppState, Workspace, Node (Link/Folder/Task/Snippet)
├── AppModel.swift                         # Central state manager
├── DataStore.swift                        # Persistence layer (JSON + favicon storage)
├── Constants.swift                        # UserDefaults keys, pasteboard types, notifications
├── WorkspaceColor.swift                   # Workspace color definitions
├── SidebarPosition.swift                  # Sidebar position enum
├── NodeFiltering.swift                    # Recursive tree filtering
│
├── FaviconService.swift                   # Async favicon fetching with disk caching
├── LinkTitleService.swift                 # HTML title extraction from URLs
├── BrowserManager.swift                   # Browser selection & URL opening
├── WindowAttachmentService.swift          # Browser window attachment via Accessibility API
├── ArcImportService.swift                 # Import bookmarks from Arc browser
├── ShareService.swift                     # Workspace sharing via compressed URLs
├── WorkspaceExporter.swift                # Export workspaces with embedded favicons
├── WorkspaceImporter.swift                # Import workspace files
│
├── NodeCollectionViewItem.swift           # Collection view item for nodes
├── NodeRowView.swift                      # Node row view (extends BaseView)
├── WorkspaceCollectionViewItem.swift      # Collection view item for workspaces
├── WorkspaceRowView.swift                 # Workspace row view (extends BaseView)
├── WorkspaceSwitcherView.swift            # Workspace navigation switcher
├── SearchBarView.swift                    # Search field
├── SidebarPositionSelector.swift          # Sidebar position picker
├── ListFlowLayout.swift                   # Custom NSCollectionViewLayout
├── SnippetEditorView.swift                # Editor UI for code snippets
├── ScrollWheelPageController.swift        # Scroll-wheel page navigation
├── IconTitleButton.swift                  # Custom button (extends BaseControl)
├── CustomTextButton.swift                 # Text button (extends BaseControl)
├── CustomToggle.swift                     # Toggle switch (extends BaseControl)
│
└── SettingsContentViewController.swift    # Settings content (@MainActor)

StowIOS/StowIOS/
├── StowApp.swift                          # iOS app entry point
├── ViewModels/
│   └── AppViewModel.swift                 # Observable view model wrapping AppModel
├── Views/
│   ├── ContentView.swift                  # Root navigation view
│   ├── WorkspaceSidebarView.swift         # Sidebar workspace list
│   ├── WorkspacePicker.swift              # Workspace selection UI
│   ├── WorkspaceRow.swift                 # Workspace list row
│   ├── NodeListView.swift                 # Node list container
│   ├── NodeRowView.swift                  # Individual node row (folder/link/task/snippet)
│   ├── AddItemView.swift                  # Add new item sheet
│   ├── WorkspacePageView.swift            # Swipeable workspace pages
│   ├── FaviconView.swift                  # Favicon display
│   ├── SettingsView.swift                 # iOS settings screen
│   ├── WorkspaceSettingsView.swift        # Workspace management settings
│   └── PinnedLinksView.swift              # Pinned links display

StowIOS/StowShareExtension/
└── ShareViewController.swift              # Share sheet extension for saving URLs

StowIOS/StowWidget/
└── StowWidget.swift                       # Home screen widget showing pinned links
```

## Core Data Model

```swift
AppState                      // Root container
├── schemaVersion: Int
├── workspaces: [Workspace]
├── selectedWorkspaceId: UUID?
└── isSettingsSelected: Bool

Workspace                     // Named container
├── id: UUID
├── name: String
├── colorId: WorkspaceColorId
└── items: [Node]             // Root-level items

Node                          // Recursive tree structure
├── .folder(Folder)
│   ├── id: UUID
│   ├── name: String
│   ├── isExpanded: Bool
│   └── children: [Node]      // Nested items
├── .link(Link)
│   ├── id: UUID
│   ├── title: String
│   ├── url: String
│   └── faviconPath: String?
├── .task(TaskItem)
│   ├── id: UUID
│   ├── title: String
│   ├── isCompleted: Bool
│   ├── dueDate: Date?
│   ├── notes: String?
│   └── createdAt: Date
└── .snippet(Snippet)
    ├── id: UUID
    ├── title: String
    ├── content: String
    ├── language: String?
    └── createdAt: Date
```

## Key Design Decisions

### State Management
- **All mutations through AppModel methods** - no direct state access
- **Automatic persistence** - DataStore saves after every mutation
- **Observer pattern** - onChange callback for UI updates
- **Recursive tree operations** - insertNode, updateNode, removeNode, findNodeLocation

### UI Updates
- **Collection view animations** - calculated diffs for smooth insertions/deletions
- **Inline rename pattern** - scheduled via `pendingInlineRenameId`, executed after data reload
- **Hover state management** - centralized in base classes, no duplicate tracking area code
- **Design consistency** - all components use ThemeConstants for colors/fonts/spacing

### ViewController Decomposition
- **MainViewController** (~1240 lines) - Coordinator between search, list, and settings
- **NodeListViewController** (~1150 lines) - Collection view, drag-drop, context menus
- **SearchCoordinator** (~60 lines) - Search/filtering logic
- **WorkspaceManagementView** (~460 lines) - Settings workspace management

## Component Patterns

### Creating Interactive Controls

```swift
final class MyButton: BaseControl {
    override func handleHoverStateChanged() {
        layer?.backgroundColor = isHovered
            ? ThemeConstants.Colors.darkGray
                .withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
            : NSColor.clear.cgColor
    }

    override func handlePressedStateChanged() {
        // Update appearance based on isPressed
    }
}
```

### Creating Custom Views

```swift
final class MyRowView: BaseView {
    override func handleHoverStateChanged() {
        // Update appearance based on isHovered
    }
}
```

### Using ThemeConstants

```swift
// Colors
layer?.backgroundColor = ThemeConstants.Colors.darkGray.cgColor

// With opacity
let hoverColor = ThemeConstants.Colors.darkGray
    .withAlphaComponent(ThemeConstants.Opacity.minimal)

// Fonts
label.font = ThemeConstants.Fonts.bodyRegular

// Spacing
stackView.spacing = ThemeConstants.Spacing.regular

// Animation
CATransaction.setAnimationDuration(ThemeConstants.Animation.durationFast)
```

## Testing Strategy

- **Model tests** - JSON round-trip, move operations, filtering
- **ThemeConstants tests** - Validates all design values (16 tests)
- **Base class tests** - Currently skipped (Swift 6 concurrency + XCTest issues)
- **Total: 32 tests** - All passing, zero failures

## Refactoring Impact (2026-02-10)

**Code Reduction:**
- Eliminated duplicate code patterns via base classes and ThemeConstants
- Extracted NodeListViewController, SearchCoordinator, WorkspaceManagementView from MainViewController

**Improvements:**
- Zero functional regressions
- Centralized design system (ThemeConstants)
- Eliminated 6+ instances of duplicate hover state logic
- Eliminated 3+ instances of duplicate inline editing logic
- Consistent component patterns across all UI

**Documentation:**
- 900+ lines of comprehensive inline documentation
- Component usage guide (400+ lines)
- Architecture and refactoring history documented

## Dependencies

- **Swift 6** with strict concurrency
- **AppKit** for macOS UI
- **Swift Bundler** for app bundle creation
- No external dependencies for core functionality

## Build System

```bash
# Build app bundle
./scripts/build.sh

# Build and run
./scripts/run.sh

# Run tests
swift test
```

See [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) for details on build process and code signing.

## Future Considerations

**Optional Enhancements:**
- Folder structure reorganization (move files into categorized subdirectories)
- Visual regression testing suite
- Async XCTest infrastructure for base class tests
- Performance benchmarking and profiling
- Memory leak testing with Instruments

**Architecture is Stable:**
- All 5 refactoring phases complete
- Production-ready with comprehensive documentation
- Ready for new feature development

## Resources

- [CLAUDE.md](../CLAUDE.md) - Detailed development guide
- [REFACTORING_PLAN.md](REFACTORING_PLAN.md) - Complete refactoring history
- [COMPONENT_USAGE_GUIDE.md](COMPONENT_USAGE_GUIDE.md) - Component usage patterns
- [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) - Build system details
