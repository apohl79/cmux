import AppKit

/// Detects when the cursor is inside the top-left chrome region of a main
/// workspace window so the surrounding `WindowDecorationsController` can keep
/// the three native NSWindow buttons hidden while the sidebar is collapsed and
/// reveal them again on hover.
///
/// Implementation note: we use a global `NSEvent.addLocalMonitorForEvents`
/// observer rather than `NSTrackingArea` on a hidden subview in `contentView`.
/// Tracking areas placed under the titlebar layer fire unreliably when the
/// cursor enters from above the window or when the window just became key —
/// the user has to wiggle the cursor for `mouseEntered` to be synthesised.
/// A monitor sees every cursor move while the app is active and can answer
/// "is the cursor inside the zone right now?" deterministically.
///
/// Not annotated `@MainActor` — `WindowDecorationsController` itself is
/// non-isolated (mirrors the rest of the AppKit chrome glue), and notification
/// observers / AppKit callbacks hop here on the main thread anyway.
final class TrafficLightHoverRevealController {
    /// Width of the reveal zone. Picked to comfortably cover all three
    /// traffic-light buttons plus the standard ~8pt leading inset macOS uses
    /// for them.
    static let hoverZoneWidth: CGFloat = 80
    /// Height of the reveal zone. Matches the default
    /// `ChromeBarHeightSettings.defaultPoints` plus a few pt of buffer so the
    /// cursor still triggers reveal when entering from above the window.
    static let hoverZoneHeight: CGFloat = 32

    private let onHoverChanged: (NSWindow) -> Void
    /// Per-window hover state, keyed weakly so closing a window drops state.
    private var states: [ObjectIdentifier: Bool] = [:]
    /// Windows we are currently observing. Weakly held; we drop entries as we
    /// see them disappear.
    private var observedWindows = NSHashTable<NSWindow>.weakObjects()
    private var monitor: Any?

    init(onHoverChanged: @escaping (NSWindow) -> Void) {
        self.onHoverChanged = onHoverChanged
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func install(in window: NSWindow) {
        let alreadyObserved = observedWindows.contains(window)
        observedWindows.add(window)
        installMonitorIfNeeded()
        // `.mouseMoved` events are only dispatched while the window has
        // `acceptsMouseMovedEvents = true`. Mirror the minimal-mode hover
        // coordinator pattern so other owners (minimal-mode) don't see their
        // setting clobbered when we uninstall.
        WindowMouseMovedEventsCoordinator.enable(for: window, owner: ownerToken)
        // Seed the hovering state synchronously so the first apply(to:) after
        // the sidebar collapses can reveal the buttons immediately if the
        // cursor is already parked over the zone.
        let initial = isCursorInZone(for: window)
        let previous = states[ObjectIdentifier(window)] ?? false
        states[ObjectIdentifier(window)] = initial
        #if DEBUG
        cmuxDebugLog(
            "tlhover.install win=\(window.windowNumber) existed=\(alreadyObserved) initialHover=\(initial)"
        )
        #endif
        if previous != initial {
            onHoverChanged(window)
        }
    }

    func uninstall(from window: NSWindow) {
        observedWindows.remove(window)
        states.removeValue(forKey: ObjectIdentifier(window))
        WindowMouseMovedEventsCoordinator.disable(for: window, owner: ownerToken)
        #if DEBUG
        cmuxDebugLog("tlhover.uninstall win=\(window.windowNumber)")
        #endif
        if observedWindows.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            #if DEBUG
            cmuxDebugLog("tlhover.monitor.removed")
            #endif
        }
    }

    func uninstallAll() {
        let snapshot = observedWindows.allObjects
        observedWindows.removeAllObjects()
        states.removeAll()
        for window in snapshot {
            WindowMouseMovedEventsCoordinator.disable(for: window, owner: ownerToken)
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Reference identity used as the owner token in
    /// `WindowMouseMovedEventsCoordinator`. We can't pass `self` directly
    /// because `WindowMouseMovedEventsCoordinator.disable` is called from
    /// `deinit` of the outer `WindowDecorationsController` and `self` may
    /// already be torn down by then.
    private let ownerToken: AnyObject = NSObject()

    func isHovering(in window: NSWindow) -> Bool {
        states[ObjectIdentifier(window)] ?? false
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .mouseEntered, .mouseExited]
        ) { [weak self] event in
            self?.handle(event: event)
            return event
        }
        #if DEBUG
        cmuxDebugLog("tlhover.monitor.installed")
        #endif
    }

    private func handle(event: NSEvent) {
        // The event may target any window — re-evaluate every observed window
        // using global cursor location so the reveal also triggers when the
        // cursor enters from outside the window.
        let observed = observedWindows.allObjects
        guard !observed.isEmpty else { return }
        for window in observed {
            let nowInside = isCursorInZone(for: window)
            let key = ObjectIdentifier(window)
            let previous = states[key] ?? false
            if previous != nowInside {
                states[key] = nowInside
                #if DEBUG
                cmuxDebugLog(
                    "tlhover.hover.change win=\(window.windowNumber) hover=\(nowInside) " +
                    "evt=\(event.type.rawValue)"
                )
                #endif
                onHoverChanged(window)
            }
        }
    }

    private func isCursorInZone(for window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized else { return false }
        // Screen-coordinate hit test so the reveal works regardless of which
        // window is key or whether the cursor entered from outside the app.
        let screenPoint = NSEvent.mouseLocation
        let frame = window.frame
        let leadingX = frame.minX
        let topY = frame.maxY
        let zoneRect = NSRect(
            x: leadingX,
            y: topY - Self.hoverZoneHeight,
            width: Self.hoverZoneWidth,
            height: Self.hoverZoneHeight
        )
        return zoneRect.contains(screenPoint)
    }
}
