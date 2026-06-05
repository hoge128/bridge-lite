import SwiftUI
import UIKit

// 横向きを許可するかどうか（Welcome 画面は false、ThumbnailGridView / DetailView は true）
@MainActor var allowLandscape = false

@MainActor func forcePortraitOrientation() {
    guard let scene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
}

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
        allowLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
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
