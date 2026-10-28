import UIKit

/// Launch work that isn't about a window. The window comes from SceneDelegate: an app built with the iOS 27 SDK must
/// use the scene lifecycle or it stops at launch (GTA-171). Info.plist's UIApplicationSceneManifest names the scenes.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The Lite build (PGLiteMode in Info.plist, build_ipa.sh --lite): the engine and renderer read PG_LITE.
        if Theme.isLite && getenv("PG_LITE") == nil { setenv("PG_LITE", "1", 1) }
        GameSettings.applyExperimentalSwitches()
        // Test (GTA-77): PG_TEST_COLD_SHADERS=1 deletes the system's compiled-shader cache for this app first (every
        // "com.apple.metal" folder in Library/Caches, two levels deep), so the launch compiles every pipeline again, as
        // the first launch after an update that changed the shaders does.
        if ProcessInfo.processInfo.environment["PG_TEST_COLD_SHADERS"] == "1",
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            var deleted: [String] = []
            let fm = FileManager.default
            for level1 in (try? fm.contentsOfDirectory(atPath: caches.path)) ?? [] {
                let path1 = caches.appendingPathComponent(level1)
                if level1 == "com.apple.metal" { try? fm.removeItem(at: path1); deleted.append(level1); continue }
                for level2 in (try? fm.contentsOfDirectory(atPath: path1.path)) ?? [] where level2 == "com.apple.metal" {
                    try? fm.removeItem(at: path1.appendingPathComponent(level2)); deleted.append(level1 + "/" + level2)
                }
            }
            let names = ((try? fm.contentsOfDirectory(atPath: caches.path)) ?? []).joined(separator: ", ")
            let mine = ((try? fm.contentsOfDirectory(atPath: caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "").path)) ?? []).joined(separator: ", ")
            setenv("PG_TEST_COLD_SHADERS_RESULT", (deleted.isEmpty ? "not found" : "deleted " + deleted.joined(separator: ", ")) + " (Library/Caches holds: \(names); its app folder holds: \(mine))", 1)   // the renderer logs it
        }
        ModInstaller.applyPending()
        ModKeyRemap.apply()  // keys that answer a mod's own key (GTA-181), before the mods load
        #if targetEnvironment(simulator)
        // Test: --import-save <file> runs Settings › Import a Story save on that file at launch.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--import-save"), i + 1 < arguments.count {
            switch SaveImport.importSave(from: URL(fileURLWithPath: arguments[i + 1])) {
            case let .imported(title, slot): NSLog("[native-port] TEST: save imported: \(title) into slot \(slot)")
            case let .failed(message): NSLog("[native-port] TEST: save import failed: \(message)")
            }
        }
        #endif
        Analytics.shared.start()
        return true
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac menu bar: Settings… (⌘,) in the app menu, as every Mac app has it.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let settings = UIKeyCommand(title: AppLanguage.choose("Settings"), action: #selector(NativePortViewController.openSettingsFromMenu),
                                    input: ",", modifierFlags: .command)
        builder.insertSibling(UIMenu(options: .displayInline, children: [settings]), afterMenu: .about)
    }
    #endif
}

/// The app's window: the phone's screen, or the Mac's window.
/// The game's window. It notes when a finger last touched the screen, for the Display log line (GTA-200): iOS raises a
/// ProMotion screen's refresh rate while it is touched, so touch and controller play can show different frame rates.
final class GameWindow: UIWindow {
    static var lastTouch: CFTimeInterval = -1000
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { Self.lastTouch = CACurrentMediaTime() }
        super.sendEvent(event)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// One game screen for the app's whole life. The engine starts once per launch, so a scene that connects again
    /// (a Mac window closed and opened again from the Dock, or iOS dropping the scene while the app was away) gets the
    /// same screen back instead of a second one.
    private static var gameScreen: NativePortViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let screen = Self.gameScreen ?? NativePortViewController()
        Self.gameScreen = screen
        if let old = screen.viewIfLoaded?.window { old.rootViewController = nil }
        let window = GameWindow(windowScene: scene)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        self.window = window
        #if targetEnvironment(simulator)
        testWindowSizes(window, in: scene)
        #endif
    }

    #if targetEnvironment(simulator)
    /// Tests (GTA-185): --test-window W1xH1[,W2xH2...] gives the window that size in points, centred, as the iPhone
    /// Duo's screens are (inner 951x669, outer 678x466) on a simulator big enough for it; with --test-fold-every S the
    /// window takes the next size every S seconds while the game runs, as folding and unfolding does.
    private var testSizes: [CGSize] = [], testSizeIndex = 0, testTimer: Timer?
    private func testWindowSizes(_ window: UIWindow, in scene: UIWindowScene) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "--test-window"), i + 1 < arguments.count else { return }
        testSizes = arguments[i + 1].split(separator: ",").compactMap { item in
            let parts = item.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        }
        guard !testSizes.isEmpty else { return }
        placeTestWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.placeTestWindow() }   // once the scene is landscape
        if let j = arguments.firstIndex(of: "--test-fold-every"), j + 1 < arguments.count, let seconds = Double(arguments[j + 1]), testSizes.count > 1 {
            testTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.testSizeIndex = (self.testSizeIndex + 1) % self.testSizes.count
                self.placeTestWindow()
                let size = self.testSizes[self.testSizeIndex]
                GameFolder.log("Test: the window is now \(Int(size.width))×\(Int(size.height)) points (a fold, GTA-185).")
            }
        }
    }
    private func placeTestWindow() {
        guard let window, let scene = window.windowScene else { return }
        let size = testSizes[testSizeIndex], screen = scene.coordinateSpace.bounds
        window.frame = CGRect(x: ((screen.width - size.width) / 2).rounded(), y: ((screen.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }
    #endif
}

/// A TV (AirPlay or an HDMI adapter) as iOS gives it to a scene-based app: a scene with the external display role.
/// NativePortViewController puts the game's picture on it during play (GTA-3); without a window from the app the TV
/// shows the phone's screen, as before Play. Info.plist names this delegate for that role; on iOS 27 the scene only
/// comes after the game screen registers it as a scene accessory (NativePortViewController.registerTVAccessory).
final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The scene configuration's name in Info.plist.
    static let configurationName = "TV"
    static let changed = Notification.Name("PGTVSceneChanged")
    /// The connected TV's scene, nil without one.
    private(set) static var scene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        Self.scene = scene
        GameFolder.log("TV scene connected (\(Int(scene.screen.bounds.width))×\(Int(scene.screen.bounds.height)) points).")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        GameFolder.log("TV scene disconnected.")
        if Self.scene === scene { Self.scene = nil }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
