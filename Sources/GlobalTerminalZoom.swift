import AppKit
import Foundation

/// App-wide terminal zoom level. A single delta (in points) is applied to every
/// live `TerminalSurface` across every workspace, and re-applied to surfaces as
/// they become ready so newly-created splits/workspaces inherit the level.
@MainActor
final class GlobalTerminalZoomController {
    static let shared = GlobalTerminalZoomController()

    static let didChangeNotification = Notification.Name("cmux.globalTerminalZoomDidChange")

    private static let userDefaultsKey = "cmux.globalTerminalZoomDelta"

    static let stepPoints: Double = 1.0
    static let minimumFontPoints: Double = 4.0
    static let maximumFontPoints: Double = 72.0

    private var observer: NSObjectProtocol?

    private(set) var delta: Double {
        didSet {
            if abs(oldValue - delta) < 0.0005 {
                return
            }
            UserDefaults.standard.set(delta, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private init() {
        self.delta = UserDefaults.standard.object(forKey: Self.userDefaultsKey).flatMap { value in
            (value as? Double) ?? (value as? NSNumber)?.doubleValue
        } ?? 0.0
    }

    /// Wire up the new-surface observer. Call once during app startup.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let surface = notification.object as? TerminalSurface else { return }
            Task { @MainActor [weak self] in
                self?.applyZoom(to: surface)
            }
        }
    }

    /// Increment the global zoom by one step. Returns the new delta.
    @discardableResult
    func zoomIn() -> Double {
        return setDelta(delta + Self.stepPoints)
    }

    /// Decrement the global zoom by one step. Returns the new delta.
    @discardableResult
    func zoomOut() -> Double {
        return setDelta(delta - Self.stepPoints)
    }

    /// Reset the global zoom back to the base config font size.
    @discardableResult
    func zoomReset() -> Double {
        return setDelta(0.0)
    }

    /// Override the persisted delta and broadcast to every live surface.
    @discardableResult
    func setDelta(_ newDelta: Double) -> Double {
        let clamped = clampedDelta(for: newDelta)
        delta = clamped
        applyToAllSurfaces(reason: "setDelta")
        return clamped
    }

    /// Target font size in points = base config font size + current delta, clamped.
    func targetFontPoints(baseFontPoints: Double? = nil) -> Double {
        let base = baseFontPoints ?? Self.baseFontPoints()
        return clampedFontPoints(base + delta)
    }

    /// Base font size, read from the cached GhosttyConfig.
    static func baseFontPoints() -> Double {
        Double(GhosttyConfig.load().fontSize)
    }

    /// Apply the current zoom to a single surface. Returns true if a binding
    /// action was issued (false when the surface has no runtime yet).
    @discardableResult
    func applyZoom(to surface: TerminalSurface) -> Bool {
        let points = targetFontPoints()
        let action = String(format: "set_font_size:%.3f", points)
        let handled = surface.performBindingAction(action)
#if DEBUG
        cmuxDebugLog(
            "globalZoom.apply surface=\(surface.id.uuidString.prefix(5)) " +
            "delta=\(String(format: "%.2f", delta)) target=\(String(format: "%.2f", points)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
        return handled
    }

    func applyToAllSurfaces(reason: String) {
        let surfaces = TerminalSurfaceRegistry.shared.allSurfaces()
#if DEBUG
        cmuxDebugLog(
            "globalZoom.broadcast reason=\(reason) " +
            "delta=\(String(format: "%.2f", delta)) " +
            "target=\(String(format: "%.2f", targetFontPoints())) count=\(surfaces.count)"
        )
#endif
        for surface in surfaces {
            _ = applyZoom(to: surface)
        }
    }

    /// Snapshot used by tests and the debug socket: per-surface font size + the
    /// current global zoom state.
    struct SurfaceSnapshot {
        let id: UUID
        let fontPoints: Double?
    }

    struct StatusSnapshot {
        let delta: Double
        let baseFontPoints: Double
        let targetFontPoints: Double
        let surfaces: [SurfaceSnapshot]
    }

    func statusSnapshot() -> StatusSnapshot {
        let base = Self.baseFontPoints()
        let target = targetFontPoints(baseFontPoints: base)
        let surfaces = TerminalSurfaceRegistry.shared.allSurfaces().map { surface -> SurfaceSnapshot in
            SurfaceSnapshot(id: surface.id, fontPoints: surface.currentFontPoints())
        }
        return StatusSnapshot(
            delta: delta,
            baseFontPoints: base,
            targetFontPoints: target,
            surfaces: surfaces
        )
    }

    // MARK: - Clamping

    private func clampedFontPoints(_ value: Double) -> Double {
        min(Self.maximumFontPoints, max(Self.minimumFontPoints, value))
    }

    private func clampedDelta(for proposedDelta: Double) -> Double {
        let base = Self.baseFontPoints()
        let clampedFont = clampedFontPoints(base + proposedDelta)
        return clampedFont - base
    }

#if DEBUG
    /// Test-only: clear persisted delta and reset to zero without broadcasting.
    func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        delta = 0.0
    }
#endif
}

extension TerminalSurface {
    /// Convenience accessor for the surface's current runtime font size in
    /// points. Returns nil if the runtime surface is not yet alive.
    func currentFontPoints() -> Double? {
        guard let surface = surface else { return nil }
        return cmuxCurrentSurfaceFontSizePoints(surface).map(Double.init)
    }
}
