import AppKit

/// Swipes between pages (Settings, each workspace, "+") for MainViewController: the
/// outgoing page slides away as a snapshot, the incoming one is preloaded and slides in,
/// the background blends between page colours, and the rail slides only its items. A
/// reload asked for mid-swipe waits for the snap.
@MainActor
final class PageSwipeCoordinator: ScrollWheelPageDelegate {
    private unowned let main: MainViewController

    private(set) var isSwiping = false
    /// A reload asked for mid-swipe, run once the swipe ends.
    var needsReloadAfterSwipe = false
    private var lastAddNewHapticTime: TimeInterval = 0
    private var outgoingSnapshotView: NSImageView?
    private var swipeStartPageIndex: Int = 0
    private var preloadedPageIndex: Int?
    private var swipeDirection: Int = 0 // -1 backward, 0 none, +1 forward
    /// The rail's items as they were when a rail swipe began, sliding out with the finger.
    private var railOutgoingSnapshot: NSImageView?
    private var isRailSwipe: Bool { main.elasticMode == .rail && !main.railView.isHidden }

    init(main: MainViewController) {
        self.main = main
    }

    private func captureContentSnapshot() -> NSImageView? {
        let sourceView: NSView
        if main.model.state.isSettingsSelected {
            sourceView = main.settingsViewController.view
        } else {
            sourceView = main.nodeListViewController.view
        }
        guard !sourceView.isHidden else { return nil }

        let bounds = sourceView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        guard let bitmapRep = sourceView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        sourceView.cacheDisplay(in: bounds, to: bitmapRep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true

        let frameInView = sourceView.convert(bounds, to: main.view)
        imageView.frame = frameInView

        return imageView
    }

    private func preloadIncomingPage(_ targetPageIndex: Int) {
        guard targetPageIndex != preloadedPageIndex else { return }
        preloadedPageIndex = targetPageIndex

        let workspaceCount = main.model.workspaces.count

        if isRailSwipe {
            // The rail keeps its dots; only the items under them change to the incoming page's.
            let index = RailSwipe.workspaceIndex(forPage: targetPageIndex, workspaceCount: main.model.workspaces.count)
            main.railView.previewItems(index.map { main.model.workspaces[$0].items } ?? [])
            return
        }
        if targetPageIndex == 0 {
            main.showSettingsContent()
        } else if targetPageIndex >= 1 && targetPageIndex <= workspaceCount {
            main.showWorkspaceContent()
            let workspaceIdx = targetPageIndex - 1
            let workspace = main.model.workspaces[workspaceIdx]
            let filteredNodes = main.searchCoordinator.filter(nodes: workspace.items)
            main.nodeListViewController.isSearchActive = main.searchCoordinator.isSearchActive
            main.nodeListViewController.reloadData(with: filteredNodes, forceExpand: false, animated: false)
        }
        // Add-new page: no content to show
    }

    private func beginSwipeTransition() {
        main.nodeListViewController.emptyStateOverlay.settle()
        main.updateSettingsConstraints()
        swipeStartPageIndex = main.currentPageIndex()
        preloadedPageIndex = nil
        swipeDirection = 0

        if isRailSwipe {
            railOutgoingSnapshot = main.railView.snapshotItems()
            main.railView.setItemsOffset(main.view.bounds.width)
        } else if let snapshot = captureContentSnapshot() {
            outgoingSnapshotView = snapshot
            main.view.addSubview(snapshot)
        }
    }

    private func cleanupSwipeTransition() {
        outgoingSnapshotView?.removeFromSuperview()
        outgoingSnapshotView = nil
        railOutgoingSnapshot?.removeFromSuperview()
        railOutgoingSnapshot = nil
        main.railView.setItemsOffset(0)
        preloadedPageIndex = nil
        swipeDirection = 0
        main.nodeListViewController.view.layer?.transform = CATransform3DIdentity
        main.nodeListViewController.view.alphaValue = 1.0
    }

    /// Whether the current swipe is between two workspace pages (not settings or add-new).
    private var isWorkspaceToWorkspaceSwipe: Bool {
        let target = swipeStartPageIndex + swipeDirection
        let workspaceCount = main.model.workspaces.count
        return swipeStartPageIndex >= 1 && swipeStartPageIndex <= workspaceCount
            && target >= 1 && target <= workspaceCount
    }

    // MARK: - ScrollWheelPageDelegate

    func pagerDidUpdateOffset(_ offset: CGFloat) {
        // Swipe detection
        if !isSwiping {
            let isFractional = abs(offset - offset.rounded()) > 0.001
            if isFractional {
                isSwiping = true
                beginSwipeTransition()
            } else {
                main.applyBackgroundColor(for: main.colorForPage(Int(offset.rounded())))
                return
            }
        }

        let startPage = CGFloat(swipeStartPageIndex)
        let delta = offset - startPage
        let width = main.contentAreaWidth

        // Direction tracking — detect changes and preload incoming
        let newDirection: Int = delta > 0.001 ? 1 : (delta < -0.001 ? -1 : 0)
        if newDirection != 0 && newDirection != swipeDirection {
            swipeDirection = newDirection
            let targetPage = swipeStartPageIndex + newDirection
            preloadIncomingPage(targetPage)
        }

        if isRailSwipe {
            let t = RailSwipe.translations(delta: delta, direction: swipeDirection == 0 ? 1 : swipeDirection, width: main.view.bounds.width)
            railOutgoingSnapshot?.layer?.transform = CATransform3DMakeTranslation(t.outgoing, 0, 0)
            main.railView.setItemsOffset(t.incoming)
        }

        // Position outgoing snapshot (slides away from center)
        let txOut = -delta * width
        outgoingSnapshotView?.layer?.transform = CATransform3DMakeTranslation(txOut, 0, 0)
        outgoingSnapshotView?.alphaValue = 1.0

        // Position incoming content
        let targetPage = swipeStartPageIndex + swipeDirection
        let isAddNewPage = targetPage >= main.totalPageCount() - 1

        if targetPage < 0 {
            // Edge bounce past first page: hide source view so it doesn't
            // show through behind the translating snapshot.
            main.settingsViewController.view.isHidden = true
        } else {
            let swipeFromWorkspace = swipeStartPageIndex >= 1
                && swipeStartPageIndex <= main.model.workspaces.count

            if isAddNewPage {
                // Add-new page: hide incoming content, just show background
                if swipeFromWorkspace {
                    main.nodeListViewController.view.alphaValue = 0
                } else {
                    main.contentStack.alphaValue = 0
                }
                main.settingsViewController.view.alphaValue = 0
            } else if swipeDirection != 0 {
                let incomingView: NSView
                if targetPage == 0 {
                    incomingView = main.settingsViewController.view
                } else if isWorkspaceToWorkspaceSwipe {
                    incomingView = main.nodeListViewController.view
                } else {
                    incomingView = main.contentStack
                }
                let txIn: CGFloat
                if delta > 0 {
                    txIn = (1.0 - delta) * width
                } else {
                    txIn = (-1.0 - delta) * width
                }
                incomingView.layer?.transform = CATransform3DMakeTranslation(txIn, 0, 0)
                incomingView.alphaValue = 1.0
            }
        }

        // Interpolate background color
        let fromPage = max(0, Int(floor(offset)))
        let toPage = min(main.totalPageCount() - 1, fromPage + 1)
        let fraction = offset - CGFloat(fromPage)

        let fromColor = resolvedColor(main.colorForPage(fromPage).adaptiveBackgroundColor)
        let toColor = resolvedColor(main.colorForPage(toPage).adaptiveBackgroundColor)

        if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
            main.view.layer?.backgroundColor = blended.cgColor
            main.view.window?.backgroundColor = blended
        }
        let fromColors = StowTheme.colors(for: main.colorForPage(fromPage), tint: StowTheme.displayTint)
        let toColors = StowTheme.colors(for: main.colorForPage(toPage), tint: StowTheme.displayTint)
        main.applyChromeColors(fromColors.blended(with: toColors, fraction: Double(fraction)))

        // Update workspace switcher sliding highlight
        main.workspaceSwitcher.visualPageOffset = offset

        // Continuous haptic while dragging into the add-new zone
        let lastWorkspacePage = CGFloat(main.totalPageCount() - 2)
        if offset > lastWorkspacePage + 0.01 {
            let now = CACurrentMediaTime()
            if now - lastAddNewHapticTime >= 0.05 {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                lastAddNewHapticTime = now
            }
        }
    }

    /// Flattens a dynamic color to a concrete sRGB color in the current appearance.
    private func resolvedColor(_ color: NSColor) -> NSColor {
        var result = color
        main.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    func pagerDidSnapToPage(_ pageIndex: Int) {
        main.workspaceSwitcher.visualPageOffset = nil

        cleanupSwipeTransition()

        // Reset transforms and alpha on all content views
        main.contentStack.layer?.transform = CATransform3DIdentity
        main.settingsViewController.view.layer?.transform = CATransform3DIdentity
        main.nodeListViewController.view.layer?.transform = CATransform3DIdentity
        main.contentStack.alphaValue = 1.0
        main.settingsViewController.view.alphaValue = 1.0
        main.nodeListViewController.view.alphaValue = 1.0

        let pageCount = main.totalPageCount()

        if pageIndex == 0 {
            main.model.selectSettings()
        } else if pageIndex >= pageCount - 1 {
            isSwiping = false
            if needsReloadAfterSwipe { main.reloadData(animated: false) }
            main.promptCreateWorkspace()
            return
        } else {
            let workspaceIdx = pageIndex - 1
            if workspaceIdx < main.model.workspaces.count {
                main.model.selectWorkspace(id: main.model.workspaces[workspaceIdx].id)
            }
        }

        // The swipe ends before reloading, or reloadData would skip it as mid-swipe. This
        // reload also covers anything recorded in needsReloadAfterSwipe. The list holds the
        // previewed page, so there's nothing meaningful to animate from.
        isSwiping = false
        main.reloadData(animated: false)
        main.applyBackgroundColor(for: main.colorForPage(pageIndex))
    }

    func pagerPageCount() -> Int {
        main.totalPageCount()
    }

    func pagerCurrentPage() -> Int {
        main.currentPageIndex()
    }
}
