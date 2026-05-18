import Foundation

/// Batches thumbnail JPEG writes to SQLite in a single BEGIN…COMMIT transaction per flush.
///
/// Replaces the 1-connection-per-thumbnail pattern (bridge_store_cached_thumbnail).
/// Enqueue is non-blocking — items are pushed to the Rust batch builder immediately and
/// flushed in the background. Flushes are chained so only one SQLite writer is active at
/// a time, avoiding WAL contention that would otherwise cause beach-ball hangs.
///
/// Flush triggers:
///   1. batchSize items accumulated → start flush immediately
///   2. drain() called → flush any remainder and wait for the entire chain to finish
actor ThumbnailWriteBuffer {
    private let builder: BridgeCoreThumbBuilder
    private let batchSize: Int
    private var pendingCount: Int = 0
    /// Tail of the flush chain. Each new flush task awaits the previous one,
    /// serializing SQLite writes without blocking thumbnail generation.
    private var currentFlushTask: Task<Void, Never>?

    init(db: BridgeCoreDatabase, batchSize: Int = 32) {
        builder = BridgeCoreThumbBuilder(bridge_thumb_batch_new(db.inner))
        self.batchSize = batchSize
    }

    func enqueue(url: URL, data: Data, aspectOk: Bool = true, rawOrientation: UInt8 = 0) {
        data.withUnsafeBytes { raw in
            bridge_thumb_batch_push(
                builder.inner, url.path,
                raw.bindMemory(to: UInt8.self),
                aspectOk, rawOrientation
            )
        }
        pendingCount += 1
        if pendingCount >= batchSize {
            startFlush()
        }
    }

    /// Flush all remaining items and wait for the entire flush chain to finish.
    /// Call this after all enqueue() calls are done (scan complete or cancelled).
    func drain() async {
        if pendingCount > 0 { startFlush() }
        if let task = currentFlushTask { await task.value }
    }

    // MARK: - Private

    /// Appends a new flush task to the chain. The new task awaits the previous one first,
    /// ensuring at most one concurrent SQLite writer at any time.
    private func startFlush() {
        pendingCount = 0
        let b = builder
        let prev = currentFlushTask
        currentFlushTask = Task.detached(priority: BridgeQoS.thumbnail) {
            await prev?.value
            bridge_thumb_batch_flush(b.inner)
        }
    }
}
