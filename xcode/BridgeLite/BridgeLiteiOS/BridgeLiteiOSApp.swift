import SwiftUI
import UIKit

// 全画面表示など横向きを許可したい VC がこれを true にする
@MainActor var allowLandscape = false

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        BackgroundScanManager.shared.registerHandler()
        return true
    }

    @MainActor func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        allowLandscape ? .all : .portrait
    }
}

@main
struct BridgeLiteiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
