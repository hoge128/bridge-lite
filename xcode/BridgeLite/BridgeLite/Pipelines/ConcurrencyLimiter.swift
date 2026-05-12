import Foundation

// MARK: - QoS ポリシー

/// バックグラウンドスキャン・レンダリング処理の QoS ポリシー一元管理。
///
/// 通常モード: .utility — 他アプリへの影響を最小化（macOS がバックグラウンド処理として扱う）
/// Burst Mode: .userInitiated — 最大スループット優先（スキャン速度を重視するとき）
///
/// - Note: SettingsStore.shared は @MainActor 分離のため nonisolated なここからは参照不可。
///   burstMode は UserDefaults に書き込まれているので直接読む（UserDefaults はスレッドセーフ）。
enum BridgeQoS {
    private static var isBurstMode: Bool {
        UserDefaults.standard.bool(forKey: "burstMode")
    }
    static var scan: TaskPriority {
        isBurstMode ? .userInitiated : .utility
    }
    static var thumbnail: TaskPriority {
        isBurstMode ? .userInitiated : .utility
    }
    static var rawRender: TaskPriority {
        isBurstMode ? .userInitiated : .utility
    }
    // 通常: 3、Burst: 8（xmpLimiter は毎スキャン時に参照するため動的に効く）
    static var xmpConcurrency: Int {
        isBurstMode ? 8 : 3
    }
}

// MARK: - Concurrency Limiter

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
        do {
            let result = try await work()
            release()
            return result
        } catch {
            release()
            throw error
        }
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
