#if canImport(RealityKit)
import Foundation

/// Runs one loader's loads one at a time: they share the resources they decode, so a
/// second call waits rather than discarding the first one's work.
@MainActor
final class GLTFLoadQueue {
    private struct Wait {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isRunning = false
    private var waits: [Wait] = []
    private var lastWaitID = 0
    /// Catches a cancellation landing between a load taking its number and queueing
    /// under it, which would otherwise leave the wait in the queue for good.
    private var cancelledWaits: Set<Int> = []

    /// Runs `load` once the loads queued before it have finished.
    ///
    /// - Throws: `CancellationError` when the wait itself is cancelled, having given up
    ///   its place rather than holding the queue back until the running load is done.
    func run<T>(_ load: () async throws -> T) async throws -> T {
        try await begin()
        defer { end() }
        return try await load()
    }

    func begin() async throws {
        try Task.checkCancellation()
        guard isRunning else {
            isRunning = true
            return
        }
        lastWaitID += 1
        let id = lastWaitID
        defer { cancelledWaits.remove(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard cancelledWaits.remove(id) == nil else {
                    return continuation.resume(throwing: CancellationError())
                }
                waits.append(Wait(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.giveUpWait(withID: id) }
        }
    }

    /// Handed straight to the next call in line, so nothing slips in between.
    func end() {
        if waits.isEmpty {
            isRunning = false
        } else {
            waits.removeFirst().continuation.resume()
        }
    }

    /// Drops a cancelled wait from the queue. One that has yet to queue, or that already
    /// holds the queue, is noted instead: it is the load itself that then sees it.
    private func giveUpWait(withID id: Int) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else {
            cancelledWaits.insert(id)
            return
        }
        waits.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
#endif
