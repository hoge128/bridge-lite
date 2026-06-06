// Sparkle is the Direct (DMG) distribution updater. The Mac App Store build
// (APPSTORE compilation condition) relies on App Store auto-update instead and
// must not link or embed Sparkle, so the whole file is compiled out there.
#if !APPSTORE
import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject {
    static let shared = UpdaterController()

    let controller: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    var updater: SPUUpdater { controller.updater }

    private override init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        super.init()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    // nil = Info.plist の SUFeedURL を使用
    // ローカルテスト時のみ "http://localhost:8000/appcast.xml" を返すよう一時的に変更する
    // (手順: cd docs && python3 -m http.server 8000)
}
#endif
