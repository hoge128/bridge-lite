import Foundation

/// actor-based セマフォで最大並列数を制御。
/// キャンセルに対応しており、待機中のタスクがキャンセルされるとキューから除去される。
actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private var running: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { Task { release() } }
        return try await work()
    }

    private func acquire() async throws {
        if running < maxConcurrent {
            running += 1
            return
        }
        let id = UUID()
        // withTaskCancellationHandler: 親 Task がキャンセルされたとき waiter をキューから除去する。
        // これにより、旧スキャンの task が limiter を占有し続けることを防ぐ。
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.removeWaiter(id: id) }
        }
        running += 1
    }

    private func removeWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        running -= 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        }
    }
}
