import SwiftUI
import AVFoundation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if UserDefaults.standard.object(forKey: "uitest_login") != nil || UserDefaults.standard.object(forKey: "uitest_play") != nil
            || UserDefaults.standard.object(forKey: "uitest_tab") != nil || UserDefaults.standard.bool(forKey: "uitest_log")
            || UserDefaults.standard.object(forKey: "uitest_search") != nil {
            TestLog.enabled = true
            HangWatch.start()
        }
        _ = Downloads.shared
        URLCache.shared = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == Downloads.sessionID { Downloads.shared.backgroundDone = completionHandler }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.mask
    }
}

/// Browsing is portrait only; the player may turn to landscape.
enum Orientation {
    @MainActor static func set(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        AppDelegate.mask = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows {
                var vc = w.rootViewController
                while let v = vc {
                    v.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = v.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { e in dlog("rotate error: \(e.localizedDescription)") }
        }
    }
}

@main
struct AlnurIPTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}
