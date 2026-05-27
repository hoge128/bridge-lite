import UIKit
import BackgroundTasks

/// iOS バックグラウンド読み込み継続の 2 層制御:
///
/// Layer 1 – beginBackgroundTask: バックグラウンド移行時に ~30 秒の実行時間を延長。
///            既存の Swift Task / Rust Tokio スレッドがそのまま継続する。
/// Layer 2 – BGProcessingTask: 30 秒で終わらない大規模フォルダ用。
///            システムが条件良好時（アイドル・充電中）に起動して EXIF 索引を完了させる。
@MainActor
final class BackgroundScanManager {
    static let shared = BackgroundScanManager()
    static let taskIdentifier = "io.github.bridge-lite.ios.exifindex"

    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Layer 1: beginBackgroundTask

    func beginExtendedTime() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "BridgeLiteExifIndex") { [weak self] in
            // 時間切れ: BGProcessingTask をスケジュールしてからタスクを終了する
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleTask()
                let id = self.bgTaskID
                UIApplication.shared.endBackgroundTask(id)
                self.bgTaskID = .invalid
            }
        }
    }

    func endExtendedTime() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - Layer 2: BGProcessingTask

    /// AppDelegate.didFinishLaunchingWithOptions から1回だけ呼ぶ。
    func registerHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundScanManager.shared.performBackgroundIndex(processingTask)
            }
        }
    }

    func scheduleTask() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelScheduledTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    // MARK: - BGProcessingTask 実行本体

    private func performBackgroundIndex(_ bgTask: BGProcessingTask) {
        let dbURL = ScanStore.cacheDBURL()
        guard let url = BookmarkStore.restore() else {
            bgTask.setTaskCompleted(success: false)
            return
        }

        let workTask = Task.detached(priority: .utility) { () -> Bool in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let db = try? BridgeCoreDatabase.open(path: dbURL) else { return false }
                guard !Task.isCancelled else { return false }
                let (_, imageList, _, _) = try await BridgeCore.scanDirectory(url: url, db: db)
                guard !Task.isCancelled else { return false }
                await BridgeCore.indexNewEntries(list: imageList, db: db)
                return !Task.isCancelled
            } catch {
                return false
            }
        }

        // expirationHandler: 時間切れ時に作業をキャンセルする（setTaskCompleted は workTask 側で呼ぶ）
        bgTask.expirationHandler = {
            workTask.cancel()
        }

        Task {
            let success = await workTask.value
            bgTask.setTaskCompleted(success: success)
        }
    }
}
