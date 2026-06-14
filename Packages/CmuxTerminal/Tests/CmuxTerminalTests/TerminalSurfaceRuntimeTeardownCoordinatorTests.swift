import Foundation
import Testing
@testable import CmuxTerminal

/// Records freed pointers behind an actor so the @Sendable free closures can
/// report back across the worker hop.
private actor FreedSurfaceRecorder {
    /// Freed pointers as Sendable bit patterns.
    private(set) var freed: [UInt] = []
    private var continuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ pointerBits: UInt) {
        freed.append(pointerBits)
        let count = freed.count
        for waiter in continuations.removeValue(forKey: count) ?? [] {
            waiter.resume()
        }
    }

    /// Suspends until `count` frees have been recorded.
    func waitForFreeCount(_ count: Int) async {
        guard freed.count < count else { return }
        await withCheckedContinuation { continuation in
            continuations[count, default: []].append(continuation)
        }
    }
}

private final class TeardownOrderRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.tests.teardown-order")
    private var events: [String] = []
    private var continuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: String) {
        let waiters = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            events.append(event)
            return continuations.removeValue(forKey: events.count) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func snapshot() -> [String] {
        queue.sync { events }
    }

    func waitForEventCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = queue.sync { () -> Bool in
                guard events.count < count else { return true }
                continuations[count, default: []].append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class RecordingTeeLease: TerminalByteTeeLease, @unchecked Sendable {
    private let recorder: TeardownOrderRecorder

    init(recorder: TeardownOrderRecorder) {
        self.recorder = recorder
    }

    func release() {
        recorder.record("teeRelease")
    }
}

@Suite struct TerminalSurfaceRuntimeTeardownCoordinatorTests {
    @Test func enqueuedTeardownInvokesInjectedFreeWithTheSamePointer() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test",
            surface: surface,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )

        await recorder.waitForFreeCount(1)
        #expect(await recorder.freed == [UInt(bitPattern: surface)])
    }

    @Test func teardownsForMultipleSurfacesAllFree() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }

        for surface in surfaces {
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.batch",
                surface: surface,
                callbackContext: nil,
                freeSurface: { pointer in
                    let bits = UInt(bitPattern: pointer)
                    Task { await recorder.record(bits) }
                }
            )
        }

        await recorder.waitForFreeCount(surfaces.count)
        #expect(await Set(recorder.freed) == Set(surfaces.map { UInt(bitPattern: $0) }))
    }

    @Test func teeLeaseReleasesAfterNativeFreeCompletes() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = TeardownOrderRecorder()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.tee",
            surface: surface,
            callbackContext: nil,
            teeLease: RecordingTeeLease(recorder: recorder),
            freeSurface: { _ in
                recorder.record("free")
            }
        )

        await recorder.waitForEventCount(2)
        #expect(recorder.snapshot() == ["free", "teeRelease"])
    }
}
