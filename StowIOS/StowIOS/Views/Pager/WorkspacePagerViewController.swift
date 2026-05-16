import UIKit
import SwiftUI
import StowShared

final class WorkspacePagerViewController: UIViewController, UIScrollViewDelegate, UISearchResultsUpdating {

    // MARK: - Callbacks

    var onOffsetChanged: ((CGFloat) -> Void)?
    var onPageSnapped: ((Int) -> Void)?
    var onAddNewTriggered: (() -> Void)?
    var onSearchTextChanged: ((String) -> Void)?

    // MARK: - State

    private(set) var currentPageIndex: Int = 0
    private var pageControllers: [UIHostingController<AnyView>] = []

    // MARK: - UI

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.isPagingEnabled = false // custom snap logic
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.decelerationRate = .fast
        sv.isDirectionalLockEnabled = true
        sv.alwaysBounceHorizontal = true
        sv.alwaysBounceVertical = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.delaysContentTouches = false
        sv.canCancelContentTouches = true
        return sv
    }()

    // MARK: - Snap Animation

    private var displayLink: CADisplayLink?
    private var snapStartOffset: CGFloat = 0
    private var snapTargetOffset: CGFloat = 0
    private var snapStartTime: TimeInterval = 0
    private var snapTargetPage: Int = 0

    // MARK: - Drag Tracking

    private var dragStartPage: Int = 0
    private var isDragging = false

    // MARK: - Haptics

    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private var lastHapticTime: TimeInterval = 0

    // MARK: - Search

    /// Stored so the representable can dismiss search when the page snaps.
    private(set) var searchController: UISearchController?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(scrollView)
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        definesPresentationContext = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard searchController == nil else { return }

        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = "Search items"
        searchController = sc

        // Set on the parent's navigationItem so the SwiftUI NavigationStack picks it up.
        parent?.navigationItem.searchController = sc
        parent?.navigationItem.hidesSearchBarWhenScrolling = true
    }

    // MARK: - UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        onSearchTextChanged?(searchController.searchBar.text ?? "")
    }

    // MARK: - Content Scroll View

    /// Returns the vertical scroll view of the current page so the navigation
    /// controller can track it for hiding/showing the search bar on pull-down.
    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        guard edge == .top else { return nil }
        guard currentPageIndex < pageControllers.count else { return nil }
        let hostView = pageControllers[currentPageIndex].view
        return findVerticalScrollView(in: hostView)
    }

    private func findVerticalScrollView(in view: UIView?) -> UIScrollView? {
        guard let view else { return nil }
        if let sv = view as? UIScrollView, sv !== scrollView {
            return sv
        }
        for child in view.subviews {
            if let found = findVerticalScrollView(in: child) {
                return found
            }
        }
        return nil
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyTopSafeAreaToPages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        layoutPages()

        // Don't reset offset during drag or snap animation
        if displayLink == nil && !isDragging {
            scrollView.contentOffset.x = CGFloat(currentPageIndex) * pageWidth
        }
    }

    // MARK: - Page Management

    func updatePages(workspaces: [Workspace], addNewView: AnyView, viewModel: AppViewModel) {
        // Save offset so we can restore it after rebuild
        let savedOffset = scrollView.contentOffset

        // Build new controllers before removing old ones
        var newControllers: [UIHostingController<AnyView>] = []

        for workspace in workspaces {
            let nodeListView = AnyView(
                NodeListView(workspaceId: workspace.id, showHeader: true)
                    .environmentObject(viewModel)
            )
            let host = UIHostingController(rootView: nodeListView)
            host.view.backgroundColor = .clear
            newControllers.append(host)
        }

        let addHost = UIHostingController(rootView: addNewView)
        addHost.view.backgroundColor = .clear
        newControllers.append(addHost)

        // Add new views first (behind old ones)
        for host in newControllers {
            addChild(host)
            scrollView.insertSubview(host.view, at: 0)
            host.didMove(toParent: self)
        }

        // Remove old controllers
        for child in pageControllers {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        pageControllers = newControllers
        layoutPages()
        applyTopSafeAreaToPages()

        // Restore offset to prevent visual jump
        scrollView.contentOffset = savedOffset
    }

    private func layoutPages() {
        let pageWidth = scrollView.bounds.width
        let pageHeight = scrollView.bounds.height
        guard pageWidth > 0 else { return }

        for (index, controller) in pageControllers.enumerated() {
            controller.view.frame = CGRect(
                x: CGFloat(index) * pageWidth,
                y: 0,
                width: pageWidth,
                height: pageHeight
            )
        }
        scrollView.contentSize = CGSize(
            width: CGFloat(pageControllers.count) * pageWidth,
            height: pageHeight
        )
    }

    /// The scroll view uses contentInsetAdjustmentBehavior = .never which suppresses
    /// normal safe area propagation, so we manually forward the top inset to child pages.
    private func applyTopSafeAreaToPages() {
        let topInset = view.safeAreaInsets.top
        for controller in pageControllers {
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }

    // MARK: - Programmatic Navigation

    func scrollToPage(_ index: Int, animated: Bool) {
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        let clamped = max(0, min(index, pageControllers.count - 1))

        if animated {
            cancelDisplayLink()
            let currentOffset = scrollView.contentOffset.x / pageWidth
            beginSnapAnimation(from: currentOffset, toPage: clamped)
        } else {
            cancelDisplayLink()
            currentPageIndex = clamped
            scrollView.contentOffset.x = CGFloat(clamped) * pageWidth
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelDisplayLink()
        isDragging = true
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        dragStartPage = Int(round(scrollView.contentOffset.x / pageWidth))
        hapticGenerator.prepare()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0, pageControllers.count > 0 else { return }

        let normalizedOffset = scrollView.contentOffset.x / pageWidth
        onOffsetChanged?(normalizedOffset)

        // Continuous haptic while in the add-new zone (during drag and snap animation)
        let workspaceCount = pageControllers.count - 1 // last page is add-new
        let lastWorkspaceOffset = CGFloat(workspaceCount - 1) * pageWidth
        let inAddNewZone = scrollView.contentOffset.x > lastWorkspaceOffset + 1
        if inAddNewZone {
            if lastHapticTime == 0 {
                hapticGenerator.prepare()
            }
            let now = CACurrentMediaTime()
            if now - lastHapticTime >= 0.05 {
                hapticGenerator.impactOccurred(intensity: 0.4)
                lastHapticTime = now
            }
        } else {
            lastHapticTime = 0
        }
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        isDragging = false
        lastHapticTime = 0

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0, pageControllers.count > 0 else { return }

        // Override deceleration target — we handle snap ourselves
        targetContentOffset.pointee = scrollView.contentOffset

        let rawPage = scrollView.contentOffset.x / pageWidth
        let pageCount = pageControllers.count
        let workspaceCount = pageCount - 1 // last is add-new

        let threshold = ThemeConstants.Paging.pageChangeThreshold
        var targetPage: Int

        let fractional = rawPage - floor(rawPage)
        if fractional > (1.0 - threshold) {
            targetPage = Int(ceil(rawPage))
        } else if fractional < threshold {
            targetPage = Int(floor(rawPage))
        } else {
            // Between thresholds — use velocity or drag direction
            if velocity.x > 0 {
                targetPage = Int(ceil(rawPage))
            } else if velocity.x < 0 {
                targetPage = Int(floor(rawPage))
            } else {
                // No velocity — use drag direction from start page
                targetPage = rawPage > CGFloat(dragStartPage) ? Int(ceil(rawPage)) : Int(floor(rawPage))
            }
        }

        // Clamp to valid workspace pages (0..<workspaceCount) plus add-new page
        targetPage = max(0, min(targetPage, pageCount - 1))

        // Add-new page requires extra drag (45% threshold)
        let lastPage = pageCount - 1
        if targetPage == lastPage && dragStartPage != lastPage {
            let distanceIntoLastPage = rawPage - CGFloat(lastPage - 1)
            if distanceIntoLastPage < ThemeConstants.Paging.addNewPageThreshold {
                targetPage = lastPage - 1
            }
        }

        beginSnapAnimation(from: rawPage, toPage: targetPage)
    }

    // MARK: - Snap Animation (CADisplayLink + cubic ease-out)

    private func beginSnapAnimation(from currentOffset: CGFloat, toPage page: Int) {
        cancelDisplayLink()

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        snapStartOffset = currentOffset * pageWidth
        snapTargetOffset = CGFloat(page) * pageWidth
        snapTargetPage = page
        snapStartTime = CACurrentMediaTime()

        if abs(snapStartOffset - snapTargetOffset) < 0.5 {
            finishSnap()
            return
        }

        // Disable scroll view deceleration during our animation
        scrollView.isScrollEnabled = false

        let link = CADisplayLink(target: self, selector: #selector(tickSnap))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickSnap() {
        let elapsed = CACurrentMediaTime() - snapStartTime
        let duration = ThemeConstants.Paging.snapDuration
        let t = min(elapsed / duration, 1.0)

        // Cubic ease-out: 1 - (1-t)^3
        let eased = 1.0 - pow(1.0 - t, 3)
        let offset = snapStartOffset + (snapTargetOffset - snapStartOffset) * eased
        scrollView.contentOffset.x = offset

        if t >= 1.0 {
            finishSnap()
        }
    }

    private func finishSnap() {
        cancelDisplayLink()
        scrollView.isScrollEnabled = true
        scrollView.contentOffset.x = snapTargetOffset
        currentPageIndex = snapTargetPage

        // Detect landing on add-new page (last page)
        let workspacePageCount = pageControllers.count - 1
        if snapTargetPage >= workspacePageCount {
            onAddNewTriggered?()
        } else {
            onPageSnapped?(snapTargetPage)
        }
    }

    private func cancelDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        scrollView.isScrollEnabled = true
    }
}

