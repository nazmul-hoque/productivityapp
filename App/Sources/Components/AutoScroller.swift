import SwiftUI
import UIKit

/// Scrolls the list under a dragged add button when the finger rests near its top or bottom
/// edge, so a to-do can be dropped anywhere in a long list.
///
/// SwiftUI has no way to scroll a `List` by an offset on iOS 17, so rows report the
/// `UIScrollView` that hosts them (see `.dropSlot`) and this drives its `contentOffset`.
@MainActor
final class AutoScroller {
    /// How deep the edge zones are, in points.
    private let zone: CGFloat = 64
    /// Speed at the very edge, in points per second; it ramps up from zero at the zone's inner side.
    private let maxSpeed: CGFloat = 1100

    private let scrollViews = NSHashTable<UIScrollView>.weakObjects()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var point: CGPoint?
    /// The drag starts at the add button, inside the bottom zone; scrolling waits until the finger
    /// has been outside both zones once, so picking the button up doesn't scroll the list.
    private var armed = false
    /// Called with the finger's position after each scroll step, so the insertion line can follow the rows.
    var onScroll: (CGPoint) -> Void = { _ in }

    func register(_ scrollView: UIScrollView) {
        scrollViews.add(scrollView)
    }

    /// Follows the finger (global coordinates); `nil` ends the drag.
    func update(_ point: CGPoint?) {
        self.point = point
        guard point != nil else {
            stop()
            armed = false
            return
        }
        if edgeSpeed() == 0 {
            armed = true
            stop()
        } else if armed {
            start()
        }
    }

    // MARK: - Scrolling

    /// The scroll view under the finger and its visible area, in window coordinates.
    private func target() -> (scrollView: UIScrollView, visible: CGRect)? {
        guard let point else { return nil }
        for scrollView in scrollViews.allObjects where scrollView.window != nil && !scrollView.isHidden {
            let visible = scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: nil)
            if visible.minX <= point.x && point.x <= visible.maxX
                && visible.minY - zone <= point.y && point.y <= visible.maxY + zone {
                return (scrollView, visible)
            }
        }
        return nil
    }

    /// Points per second for the finger's position, ignoring `armed`; negative scrolls up.
    private func edgeSpeed() -> CGFloat {
        guard let point, let visible = target()?.visible else { return 0 }
        let fromTop = point.y - visible.minY
        let fromBottom = visible.maxY - point.y
        if fromTop < zone { return -maxSpeed * min(1, (zone - fromTop) / zone) }
        if fromBottom < zone { return maxSpeed * min(1, (zone - fromBottom) / zone) }
        return 0
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp else { return }
        let speed = armed ? edgeSpeed() : 0
        guard speed != 0, let scrollView = target()?.scrollView else {
            stop()
            return
        }
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let y = min(max(scrollView.contentOffset.y + speed * CGFloat(link.timestamp - last), minY), maxY)
        guard y != scrollView.contentOffset.y else { return }  // At the end; keep waiting in case the finger moves.
        scrollView.contentOffset.y = y
        if let point { onScroll(point) }
    }
}

/// `CADisplayLink` retains its target; this breaks the cycle with `AutoScroller`.
private final class DisplayLinkProxy: NSObject {
    weak var scroller: AutoScroller?

    init(_ scroller: AutoScroller) {
        self.scroller = scroller
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let scroller else {
            link.invalidate()
            return
        }
        scroller.tick(link)
    }
}

/// An invisible view that reports the scroll view it ends up inside.
struct EnclosingScrollViewReader: UIViewRepresentable {
    var found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.found = found
    }

    final class ProbeView: UIView {
        var found: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    found?(scrollView)
                    return
                }
                view = current.superview
            }
        }
    }
}
