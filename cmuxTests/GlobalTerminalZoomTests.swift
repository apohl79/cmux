import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GlobalTerminalZoomTests: XCTestCase {

    private let userDefaultsKey = "cmux.globalTerminalZoomDelta"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
#if DEBUG
        GlobalTerminalZoomController.shared.resetForTesting()
#endif
    }

    override func tearDown() {
#if DEBUG
        GlobalTerminalZoomController.shared.resetForTesting()
#endif
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        super.tearDown()
    }

    func testInitialDeltaIsZero() {
        XCTAssertEqual(GlobalTerminalZoomController.shared.delta, 0.0, accuracy: 0.0001)
    }

    func testZoomInIncreasesDeltaByStep() {
        let step = GlobalTerminalZoomController.stepPoints
        let firstDelta = GlobalTerminalZoomController.shared.zoomIn()
        XCTAssertEqual(firstDelta, step, accuracy: 0.0001)

        let secondDelta = GlobalTerminalZoomController.shared.zoomIn()
        XCTAssertEqual(secondDelta, 2.0 * step, accuracy: 0.0001)
    }

    func testZoomOutDecreasesDeltaByStep() {
        let step = GlobalTerminalZoomController.stepPoints
        let delta = GlobalTerminalZoomController.shared.zoomOut()
        XCTAssertEqual(delta, -step, accuracy: 0.0001)
    }

    func testZoomResetReturnsToZero() {
        _ = GlobalTerminalZoomController.shared.zoomIn()
        _ = GlobalTerminalZoomController.shared.zoomIn()
        XCTAssertGreaterThan(GlobalTerminalZoomController.shared.delta, 0.5)

        let resetDelta = GlobalTerminalZoomController.shared.zoomReset()
        XCTAssertEqual(resetDelta, 0.0, accuracy: 0.0001)
        XCTAssertEqual(GlobalTerminalZoomController.shared.delta, 0.0, accuracy: 0.0001)
    }

    func testDeltaIsPersistedAcrossControllerReads() {
        _ = GlobalTerminalZoomController.shared.zoomIn()
        _ = GlobalTerminalZoomController.shared.zoomIn()
        let persisted = UserDefaults.standard.double(forKey: userDefaultsKey)
        XCTAssertEqual(persisted, GlobalTerminalZoomController.shared.delta, accuracy: 0.0001)
        XCTAssertGreaterThan(persisted, 1.5)
    }

    func testZoomOutClampsAtMinimumFontPoints() {
        // Drive the delta deeply negative; it must stop once base+delta hits the min.
        for _ in 0..<200 {
            _ = GlobalTerminalZoomController.shared.zoomOut()
        }
        let base = GlobalTerminalZoomController.baseFontPoints()
        let minPoints = GlobalTerminalZoomController.minimumFontPoints
        XCTAssertEqual(
            GlobalTerminalZoomController.shared.delta,
            minPoints - base,
            accuracy: 0.0001,
            "Negative clamping should stop at min font size"
        )
        let target = GlobalTerminalZoomController.shared.targetFontPoints()
        XCTAssertGreaterThanOrEqual(target, minPoints - 0.0001)
    }

    func testZoomInClampsAtMaximumFontPoints() {
        for _ in 0..<200 {
            _ = GlobalTerminalZoomController.shared.zoomIn()
        }
        let base = GlobalTerminalZoomController.baseFontPoints()
        let maxPoints = GlobalTerminalZoomController.maximumFontPoints
        XCTAssertEqual(
            GlobalTerminalZoomController.shared.delta,
            maxPoints - base,
            accuracy: 0.0001,
            "Positive clamping should stop at max font size"
        )
        let target = GlobalTerminalZoomController.shared.targetFontPoints()
        XCTAssertLessThanOrEqual(target, maxPoints + 0.0001)
    }

    func testSetDeltaOverridesAndClamps() {
        let huge = GlobalTerminalZoomController.shared.setDelta(10_000)
        let base = GlobalTerminalZoomController.baseFontPoints()
        XCTAssertEqual(huge, GlobalTerminalZoomController.maximumFontPoints - base, accuracy: 0.0001)

        let tiny = GlobalTerminalZoomController.shared.setDelta(-10_000)
        XCTAssertEqual(tiny, GlobalTerminalZoomController.minimumFontPoints - base, accuracy: 0.0001)
    }

    func testStatusSnapshotReportsBaseAndTarget() {
        _ = GlobalTerminalZoomController.shared.setDelta(2.0)
        let snapshot = GlobalTerminalZoomController.shared.statusSnapshot()
        XCTAssertEqual(snapshot.delta, 2.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.baseFontPoints, GlobalTerminalZoomController.baseFontPoints(), accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.targetFontPoints,
            snapshot.baseFontPoints + snapshot.delta,
            accuracy: 0.0001
        )
    }

    func testDidChangeNotificationPostsOnDeltaChange() {
        let expectation = XCTestExpectation(description: "didChangeNotification fires on zoomIn")
        let observer = NotificationCenter.default.addObserver(
            forName: GlobalTerminalZoomController.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = GlobalTerminalZoomController.shared.zoomIn()
        wait(for: [expectation], timeout: 1.0)
    }

    func testDefaultShortcutsAreOptionCommandModifiers() {
        let zoomIn = KeyboardShortcutSettings.Action.globalTerminalZoomIn.defaultShortcut
        let zoomOut = KeyboardShortcutSettings.Action.globalTerminalZoomOut.defaultShortcut
        let reset = KeyboardShortcutSettings.Action.globalTerminalZoomReset.defaultShortcut

        for shortcut in [zoomIn, zoomOut, reset] {
            XCTAssertFalse(shortcut.isUnbound, "Global zoom shortcuts must have default bindings")
            XCTAssertTrue(shortcut.firstStroke.command)
            XCTAssertTrue(shortcut.firstStroke.option)
            XCTAssertFalse(shortcut.firstStroke.shift)
            XCTAssertFalse(shortcut.firstStroke.control)
        }
        XCTAssertEqual(zoomIn.firstStroke.key, "=")
        XCTAssertEqual(zoomOut.firstStroke.key, "-")
        XCTAssertEqual(reset.firstStroke.key, "0")
    }

    func testGlobalZoomShortcutsDoNotCollideWithBrowserZoom() {
        let browserIn = KeyboardShortcutSettings.Action.browserZoomIn.defaultShortcut
        let browserOut = KeyboardShortcutSettings.Action.browserZoomOut.defaultShortcut
        let browserReset = KeyboardShortcutSettings.Action.browserZoomReset.defaultShortcut

        let globalIn = KeyboardShortcutSettings.Action.globalTerminalZoomIn.defaultShortcut
        let globalOut = KeyboardShortcutSettings.Action.globalTerminalZoomOut.defaultShortcut
        let globalReset = KeyboardShortcutSettings.Action.globalTerminalZoomReset.defaultShortcut

        // Different modifier set means no clash regardless of key parity.
        XCTAssertNotEqual(browserIn.firstStroke.option, globalIn.firstStroke.option)
        XCTAssertNotEqual(browserOut.firstStroke.option, globalOut.firstStroke.option)
        XCTAssertNotEqual(browserReset.firstStroke.option, globalReset.firstStroke.option)
    }

    func testActionsAreApplicationContext() {
        // Global zoom must not be gated by browser/terminal focus context — it always works.
        XCTAssertEqual(KeyboardShortcutSettings.Action.globalTerminalZoomIn.shortcutContext, .application)
        XCTAssertEqual(KeyboardShortcutSettings.Action.globalTerminalZoomOut.shortcutContext, .application)
        XCTAssertEqual(KeyboardShortcutSettings.Action.globalTerminalZoomReset.shortcutContext, .application)
    }
}
