import AppKit

@MainActor
protocol ScrollWheelPageDelegate: AnyObject {
    func pagerDidUpdateOffset(_ offset: CGFloat)
    func pagerDidSnapToPage(_ pageIndex: Int)
    func pagerPageCount() -> Int
    func pagerCurrentPage() -> Int
}

@MainActor
final class ScrollWheelPageController {

    weak var delegate: ScrollWheelPageDelegate?

    /// The width of a single page in points. Must be set before use.
    var pageWidth: CGFloat = 300

    /// Whether the pager should intercept scroll events.
    var isEnabled: Bool = true

    /// View to exclude from paging — scroll events over this view pass through.
    weak var excludedView: NSView?

    // MARK: - State Machine

    private enum TrackingState {
        case idle
        case undecided
        case trackingHorizontal
    }

    private var trackingState: TrackingState = .idle
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var gestureStartPage: Int = 0
    private var lastScrollEventTime: TimeInterval = 0
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var snapTimer: Timer?

    // Snap animation state
    private var snapStartOffset: CGFloat = 0
    private var snapTargetOffset: CGFloat = 0
    private var snapStartTime: TimeInterval = 0
    private var snapTargetPage: Int = 0

    // MARK: - Lifecycle

    func attach(to window: NSWindow) {
        detach()
        NSLog("[PAGER] attaching event monitor to window")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollEvent(event)
        }
        NSLog("[PAGER] event monitor attached: \(eventMonitor != nil)")
    }

    func detach() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        cancelSnap()
        trackingState = .idle
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        snapTimer?.invalidate()
    }

    /// Jump to a page without animation.
    func jumpToPage(_ pageIndex: Int) {
        cancelSnapAndComplete()
        trackingState = .idle
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        delegate?.pagerDidUpdateOffset(CGFloat(pageIndex))
    }

    /// Animate to a page from the current visual offset.
    func animateToPage(_ pageIndex: Int, from currentOffset: CGFloat) {
        cancelSnapAndComplete()
        trackingState = .idle
        accumulatedDeltaX = 0
        beginSnapAnimation(from: currentOffset, toPage: pageIndex)
    }

    // MARK: - Event Handling

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        NSLog("[PAGER] scroll dX=%.1f dY=%.1f precise=%d phase=%lu momentum=%lu", event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0, event.phase.rawValue, event.momentumPhase.rawValue)
        guard isEnabled else { NSLog("[PAGER] disabled"); return event }
        guard let delegate else { NSLog("[PAGER] no delegate"); return event }

        // Don't mutate pager state while the window is hidden — otherwise the
        // workspace appears on a different page than the user left it on.
        if let window = event.window, !window.isVisible { return event }

        // Let scroll events over the excluded view pass through
        if let excluded = excludedView, trackingState == .idle,
           let window = event.window,
           let hitView = window.contentView?.hitTest(event.locationInWindow),
           hitView.isDescendant(of: excluded) {
            return event
        }

        // Note: We don't block scroll events when a text field has focus because
        // the direction lock ensures vertical scrolling still passes through to text views.
        // Horizontal paging should always work regardless of focus state.

        // Only handle trackpad (continuous) scroll events
        guard event.hasPreciseScrollingDeltas else {
            NSLog("[PAGER] not precise deltas")
            return event
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        switch trackingState {
        case .idle:
            let result = handleIdleEvent(event, deltaX: deltaX, deltaY: deltaY, delegate: delegate)
            if trackingState != .idle {
                NSLog("[PAGER] idle -> %@ dX=%.1f dY=%.1f", String(describing: trackingState), deltaX, deltaY)
            }
            return result
        case .undecided:
            let prevState = trackingState
            let result = handleUndecidedEvent(event, deltaX: deltaX, deltaY: deltaY, delegate: delegate)
            if trackingState != prevState {
                NSLog("[PAGER] undecided -> %@ accX=%.1f accY=%.1f", String(describing: trackingState), accumulatedDeltaX, accumulatedDeltaY)
            }
            return result
        case .trackingHorizontal:
            NSLog("[PAGER] tracking dX=%.1f accX=%.1f", deltaX, accumulatedDeltaX)
            return handleTrackingEvent(event, deltaX: deltaX, deltaY: deltaY, delegate: delegate)
        }
    }

    private func handleIdleEvent(_ event: NSEvent, deltaX: CGFloat, deltaY: CGFloat, delegate: ScrollWheelPageDelegate) -> NSEvent? {
        // Only start tracking if there's meaningful horizontal movement
        guard abs(deltaX) > 0.5 || abs(deltaY) > 0.5 else { return event }

        // Check for momentum phase — don't start a new gesture from momentum
        if event.momentumPhase != [] { return event }

        // If a snap animation is in progress, complete it immediately
        // so the delegate's model state is correct before we start the new gesture.
        cancelSnapAndComplete()

        // Begin undecided tracking
        trackingState = .undecided
        accumulatedDeltaX = deltaX
        accumulatedDeltaY = deltaY
        gestureStartPage = delegate.pagerCurrentPage()
        lastScrollEventTime = CACurrentMediaTime()

        // Consume the event so the NSScrollView doesn't enter its own tracking loop.
        // If direction turns out vertical, the next events will pass through normally.
        return nil
    }

    private func handleUndecidedEvent(_ event: NSEvent, deltaX: CGFloat, deltaY: CGFloat, delegate: ScrollWheelPageDelegate) -> NSEvent? {
        // Gesture ended while undecided — go back to idle
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase != [] {
            trackingState = .idle
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            return nil
        }

        // Reset accumulators if there's been a long gap since the last event,
        // indicating a new gesture intent. Otherwise accumulate across quick
        // discrete scroll ticks that are part of the same swipe motion.
        let now = CACurrentMediaTime()
        if now - lastScrollEventTime > 0.3 {
            accumulatedDeltaX = deltaX
            accumulatedDeltaY = deltaY
        } else {
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY
        }
        lastScrollEventTime = now

        let absX = abs(accumulatedDeltaX)
        let absY = abs(accumulatedDeltaY)
        let threshold = ThemeConstants.Paging.directionLockThreshold

        // Have we moved enough to decide direction?
        // Use a 0.6 ratio so horizontal is chosen unless vertical clearly dominates.
        // Natural trackpad swipes often have slightly more vertical than horizontal initially.
        if absX >= threshold || absY >= threshold {
            if absX >= absY * 0.6 {
                // Lock horizontal
                trackingState = .trackingHorizontal
                return handleTrackingEvent(event, deltaX: 0, deltaY: 0, delegate: delegate)
            } else {
                // Vertical — release and go idle, let next events pass through
                trackingState = .idle
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                return event
            }
        }

        // Consume events while undecided to prevent NSScrollView from entering
        // its own tracking loop and stealing subsequent events.
        return nil
    }

    private func handleTrackingEvent(_ event: NSEvent, deltaX: CGFloat, deltaY: CGFloat, delegate: ScrollWheelPageDelegate) -> NSEvent? {
        // If momentum starts, end the gesture and snap
        if event.momentumPhase != [] {
            snapToNearestPage(delegate: delegate)
            return nil // consume momentum events
        }

        // Gesture ended — snap
        if event.phase == .ended || event.phase == .cancelled {
            snapToNearestPage(delegate: delegate)
            return nil
        }

        // Cross-axis cancellation: if vertical movement suddenly dominates, snap back
        if abs(deltaY) > abs(deltaX) * ThemeConstants.Paging.crossAxisCancelRatio && abs(deltaY) > 3 {
            snapToNearestPage(delegate: delegate)
            return nil
        }

        // Accumulate horizontal delta (negate because scrolling right = negative deltaX = move forward)
        accumulatedDeltaX += deltaX

        // Compute current visual offset
        let pageCount = delegate.pagerPageCount()
        let progress = -accumulatedDeltaX / pageWidth
        var visualOffset = CGFloat(gestureStartPage) + progress

        // Clamp with rubber-band at edges
        let maxPage = CGFloat(pageCount - 1)
        if visualOffset < 0 {
            visualOffset = -rubberBand(abs(visualOffset), dimension: pageWidth)
        } else if visualOffset > maxPage {
            let overshoot = visualOffset - maxPage
            visualOffset = maxPage + rubberBand(overshoot, dimension: pageWidth)
        }

        delegate.pagerDidUpdateOffset(visualOffset)
        return nil // consume the event
    }

    // MARK: - Snap Animation

    private func snapToNearestPage(delegate: ScrollWheelPageDelegate) {
        let pageCount = delegate.pagerPageCount()
        let progress = -accumulatedDeltaX / pageWidth
        let rawOffset = CGFloat(gestureStartPage) + progress
        let threshold = ThemeConstants.Paging.pageChangeThreshold

        // Determine target page
        var targetPage: Int
        let fractional = rawOffset - floor(rawOffset)

        if fractional > (1.0 - threshold) {
            targetPage = Int(ceil(rawOffset))
        } else if fractional < threshold {
            targetPage = Int(floor(rawOffset))
        } else {
            // Between thresholds — use direction of movement
            if progress > 0 {
                targetPage = Int(ceil(rawOffset))
            } else {
                targetPage = Int(floor(rawOffset))
            }
        }

        // Clamp
        targetPage = max(0, min(targetPage, pageCount - 1))

        // Require extra drag to snap to the add-new (last) page
        let lastPage = pageCount - 1
        if targetPage == lastPage && gestureStartPage != lastPage {
            let distanceIntoLastPage = rawOffset - CGFloat(lastPage - 1)
            if distanceIntoLastPage < ThemeConstants.Paging.addNewPageThreshold {
                targetPage = lastPage - 1
            }
        }

        beginSnapAnimation(from: rawOffset, toPage: targetPage)
    }

    private func beginSnapAnimation(from currentOffset: CGFloat, toPage page: Int) {
        cancelSnap()
        trackingState = .idle
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0

        snapStartOffset = currentOffset
        snapTargetOffset = CGFloat(page)
        snapTargetPage = page
        snapStartTime = CACurrentMediaTime()

        // If already at target, finish immediately
        if abs(currentOffset - snapTargetOffset) < 0.001 {
            delegate?.pagerDidUpdateOffset(snapTargetOffset)
            delegate?.pagerDidSnapToPage(page)
            return
        }

        // Use a display-link-like timer
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickSnapAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapTimer = timer
    }

    private func tickSnapAnimation() {
        let elapsed = CACurrentMediaTime() - snapStartTime
        let duration = ThemeConstants.Paging.snapDuration
        let t = min(elapsed / duration, 1.0)

        // Cubic ease-out: 1 - (1-t)^3
        let eased = 1.0 - pow(1.0 - t, 3)

        let offset = snapStartOffset + (snapTargetOffset - snapStartOffset) * CGFloat(eased)
        delegate?.pagerDidUpdateOffset(offset)

        if t >= 1.0 {
            cancelSnap()
            delegate?.pagerDidUpdateOffset(snapTargetOffset)
            delegate?.pagerDidSnapToPage(snapTargetPage)
        }
    }

    private func cancelSnap() {
        snapTimer?.invalidate()
        snapTimer = nil
    }

    /// Cancels any in-progress snap animation and immediately notifies the delegate
    /// of the snap target page, so model state stays consistent before a new gesture starts.
    private func cancelSnapAndComplete() {
        guard snapTimer != nil else {
            cancelSnap()
            return
        }
        let completedPage = snapTargetPage
        cancelSnap()
        delegate?.pagerDidUpdateOffset(CGFloat(completedPage))
        delegate?.pagerDidSnapToPage(completedPage)
    }

    // MARK: - Rubber Band

    /// Rubber band effect for overscroll. Returns a diminished offset.
    private func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        // Standard iOS rubber band formula
        let c: CGFloat = 0.55
        return (1.0 - (1.0 / ((offset * c / dimension) + 1.0))) * dimension
    }
}
