import Foundation

/// actor-based セマフォで最大並列数を制御
actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private var running: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { Task { await release() } }
        return try await work()
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        running += 1
    }

    private func release() {
        running -= 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        }
    }
}
