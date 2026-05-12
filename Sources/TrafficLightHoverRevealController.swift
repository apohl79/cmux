import AppKit

/// Hosts a transparent NSView over the standard traffic-light area of a main
/// workspace window. We use it to detect when the cursor enters the top-left
/// chrome region so the surrounding `WindowDecorationsController` can keep the
/// three native NSWindow buttons hidden while the sidebar is collapsed and
/// reveal them again on hover.
///
/// Not annotated `@MainActor` — `WindowDecorationsController` itself is
/// non-isolated (mirrors the rest of the AppKit chrome glue), and notification
/// observers / AppKit callbacks hop here on the main thread anyway.
final class TrafficLightHoverRevealController {
    /// Width of the transparent hover sensor. Picked to comfortably cover all
    /// three traffic-light buttons plus the standard 8pt leading inset macOS
    /// uses for them at the default chrome bar height.
    static let hoverZoneWidth: CGFloat = 80
    /// Matches the default `ChromeBarHeightSettings.defaultPoints` so the
    /// sensor still covers the buttons at the smallest configurable bar.
    static let hoverZoneHeight: CGFloat = 28

    private let onHoverChanged: (NSWindow) -> Void
    private let views = NSMapTable<NSWindow, TrafficLightHoverRevealView>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    init(onHoverChanged: @escaping (NSWindow) -> Void) {
        self.onHoverChanged = onHoverChanged
    }

    func install(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let view = views.object(forKey: window) ?? {
            let v = TrafficLightHoverRevealView()
            v.autoresizingMask = [.maxXMargin, .minYMargin]
            views.setObject(v, forKey: window)
            return v
        }()
        view.onHoverChanged = { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.onHoverChanged(window)
        }

        if view.superview !== contentView {
            view.removeFromSuperview()
            contentView.addSubview(view, positioned: .above, relativeTo: nil)
        }

        let bounds = contentView.bounds
        let height = Self.hoverZoneHeight
        let originY: CGFloat
        if contentView.isFlipped {
            originY = bounds.minY
        } else {
            originY = max(0, bounds.maxY - height)
        }
        view.frame = NSRect(
            x: 0,
            y: originY,
            width: Self.hoverZoneWidth,
            height: height
        )
        view.updateTrackingAreas()
    }

    func uninstall(from window: NSWindow) {
        guard let view = views.object(forKey: window) else { return }
        view.onHoverChanged = nil
        view.removeFromSuperview()
        views.removeObject(forKey: window)
    }

    func uninstallAll() {
        let enumerator = views.objectEnumerator()
        while let view = enumerator?.nextObject() as? TrafficLightHoverRevealView {
            view.onHoverChanged = nil
            view.removeFromSuperview()
        }
        views.removeAllObjects()
    }

    func isHovering(in window: NSWindow) -> Bool {
        views.object(forKey: window)?.isHovering ?? false
    }
}

/// Transparent NSView whose sole job is to fire enter/exit callbacks so the
/// owning controller can toggle the standard window buttons. It never consumes
/// clicks — `hitTest(_:)` returns nil so events fall through to the regular
/// title bar / traffic-light hit testing.
final class TrafficLightHoverRevealView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            onHoverChanged?(isHovering)
        }
    }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
                .assumeInside,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)

        // AppKit does not synthesise a mouseEntered when we re-install tracking
        // areas (e.g. after resize or layout). Re-check explicitly so the
        // standard buttons do not appear stuck-hidden if the user already had
        // the cursor parked over the reveal zone when the sidebar collapsed.
        if let window, window.isVisible {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(mouseInWindow, from: nil)
            let nowInside = bounds.contains(pointInView)
            if nowInside != isHovering {
                isHovering = nowInside
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
