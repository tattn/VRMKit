import Testing
@testable import VRMKitRuntime

@Suite
@MainActor
struct GLTFLoadQueueTests {
    /// A load cancelled while it waits for the one before it gives up its place there
    /// and then, rather than sitting in the queue until the running load is done.
    @Test
    func testALoadCancelledWhileQueuedGivesUpItsPlace() async throws {
        let queue = GLTFLoadQueue()
        // Held as a running load would hold it, so the queued call can only come back by
        // giving up its place.
        try await queue.begin()
        let queued = Task { try await queue.run {} }
        await Task.yield()
        queued.cancel()

        await #expect(throws: CancellationError.self) { try await queued.value }
        // The queue is left intact, so the next call still runs once it is free.
        queue.end()
        #expect(try await queue.run { true })
    }
}
