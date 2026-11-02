import UIKit

/// How the engine starts: the same two choices as the web build's loading
/// screen (Story Mode / Sandbox Mode). Raw values are the engine's start mode.
enum GameMode: Int, CaseIterable {
    case story = 1
    case sandbox = 2

    var title: String { self == .story ? AppLanguage.choose("Story mode") : AppLanguage.choose("Sandbox") }
    var detail: String {
        switch self {
        case .story: return AppLanguage.choose("The campaign with missions. Continues your latest save, or starts from the Prologue.")
        case .sandbox: return AppLanguage.choose("Free roam anywhere on the map with every weapon. No missions.")
        }
    }
}

/// Player preferences, kept in UserDefaults across launches.
final class GameSettings {
    static let shared = GameSettings()
    private let defaults = UserDefaults.standard

    var gyroAim: GyroAimMode {
        get { GyroAimMode(rawValue: defaults.integer(forKey: "gyroAim")) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "gyroAim") }
    }
    var gyroSensitivity: Double {
        get { defaults.object(forKey: "gyroSensitivity") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "gyroSensitivity") }
    }
    var gyroInvertY: Bool {
        get { defaults.bool(forKey: "gyroInvertY") }
        set { defaults.set(newValue, forKey: "gyroInvertY") }
    }

    var tiltSteer: TiltSteerMode {
        get { TiltSteerMode(rawValue: defaults.integer(forKey: "tiltSteer")) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "tiltSteer") }
    }
    /// Phone rotation, in degrees, for full steering lock.
    var tiltFullLock: Double {
        get { defaults.object(forKey: "tiltFullLock") as? Double ?? 22 }
        set { defaults.set(min(max(newValue, 10), 45), forKey: "tiltFullLock") }
    }

    /// Your own server with the game files, e.g. https://my-pc.tailnet.ts.net.
    /// A cloud build can bake in a default (Info.plist PGDefaultAssetServer).
    var assetServer: String {
        get {
            if let saved = defaults.string(forKey: "assetServer"), !saved.isEmpty { return saved }
            return Bundle.main.object(forInfoDictionaryKey: "PGDefaultAssetServer") as? String ?? ""
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "assetServer") }
    }

    // Touch controls.
    var controlOpacity: Double {
        get { defaults.object(forKey: "controlOpacity") as? Double ?? 0.8 }
        set { defaults.set(min(max(newValue, 0.2), 1), forKey: "controlOpacity") }
    }
    var controlScale: Double {
        get { defaults.object(forKey: "controlScale") as? Double ?? 1.0 }
        set { defaults.set(min(max(newValue, 0.7), 1.5), forKey: "controlScale") }
    }
    // Independent experimental controls; original v1.3 stick is the default.
    // Do not conflate swipes with input device classification: the mouse path
    // is intentionally tested as a separate option, not assumed to retain auto-aim.
    enum CameraTouchMode: Int, CaseIterable {
        case stick = 0
        case swipePad = 1
        case swipeMouse = 2

        var title: String {
            switch self {
            case .stick: return AppLanguage.choose("Virtual right stick")
            case .swipePad: return AppLanguage.choose("Swipe (controller)")
            case .swipeMouse: return AppLanguage.choose("Swipe (mouse experiment)")
            }
        }
    }
    var cameraTouchMode: CameraTouchMode {
        // Swipe always drives the game's mouse: the controller swipe felt choppy, worst on the
        // vertical axis, because a finger can only tilt the stick up to the game's max turn speed.
        get {
            #if targetEnvironment(simulator)
            // Tests: --test-camera-mode <0 stick, 2 swipe> for this run only.
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "--test-camera-mode"), i + 1 < arguments.count { return arguments[i + 1] == "0" ? .stick : .swipeMouse }
            #endif
            return (CameraTouchMode(rawValue: defaults.integer(forKey: "cameraTouchMode")) ?? .stick) == .stick ? .stick : .swipeMouse
        }
        set {
            defaults.set(newValue.rawValue, forKey: "cameraTouchMode")
            // Remember the chosen swipe variant while the user switches to the
            // controller tab. Never overwrite it when selecting the stick.
            if newValue != .stick { defaults.set(newValue.rawValue, forKey: "preferredSwipeMode") }
        }
    }
    var preferredSwipeMode: CameraTouchMode {
        let saved = CameraTouchMode(rawValue: defaults.integer(forKey: "preferredSwipeMode"))
        return saved == .swipePad ? .swipePad : .swipeMouse
    }
    static let swipeSensitivityMinimum = 0.2
    static let swipeSensitivityMaximum = 15.0
    static let swipeSensitivityDefault = 3.0
    var swipeLookSensitivity: Double {
        get { defaults.object(forKey: "swipeLookSensitivity") as? Double ?? Self.swipeSensitivityDefault }
        set { defaults.set(min(max(newValue, Self.swipeSensitivityMinimum), Self.swipeSensitivityMaximum), forKey: "swipeLookSensitivity") }
    }
    var swipeAimSensitivity: Double {
        get { defaults.object(forKey: "swipeAimSensitivity") as? Double ?? Self.swipeSensitivityDefault }
        set { defaults.set(min(max(newValue, Self.swipeSensitivityMinimum), Self.swipeSensitivityMaximum), forKey: "swipeAimSensitivity") }
    }

    // Swipe moves the game's mouse by relative pixels; 1x was far too slow on a phone screen.
    static let mouseSensitivityDefault = 5.0
    var mouseLookSensitivity: Double {
        get { defaults.object(forKey: "mouseLookSensitivity") as? Double ?? Self.mouseSensitivityDefault }
        set { defaults.set(min(max(newValue, Self.swipeSensitivityMinimum), Self.swipeSensitivityMaximum), forKey: "mouseLookSensitivity") }
    }
    var mouseAimSensitivity: Double {
        get { defaults.object(forKey: "mouseAimSensitivity") as? Double ?? Self.mouseSensitivityDefault }
        set { defaults.set(min(max(newValue, Self.swipeSensitivityMinimum), Self.swipeSensitivityMaximum), forKey: "mouseAimSensitivity") }
    }
    var lookSensitivity: Double {
        get { defaults.object(forKey: "lookSensitivity") as? Double ?? 2.0 }
        set { defaults.set(min(max(newValue, 0.3), 3), forKey: "lookSensitivity") }
    }
    /// Camera speed while aiming (the game slows the camera when aiming).
    var aimSensitivity: Double {
        get { defaults.object(forKey: "aimSensitivity") as? Double ?? 1.3 }
        set { defaults.set(min(max(newValue, 0.3), 4), forKey: "aimSensitivity") }
    }
    /// Fire also locks on, like the classic mobile GTA ports.
    var fireAlsoAims: Bool {
        get { defaults.object(forKey: "fireAlsoAims") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fireAlsoAims") }
    }

    /// GTA's targeting preference: 0 traditional lock, 1 assisted aim,
    /// 2 assisted free aim, 3 free aim. Touch play defaults to assisted.
    var targetingMode: Int {
        get { defaults.object(forKey: "targetingMode") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "targetingMode") }
    }
    static var targetingTitles: [String] { [AppLanguage.choose("Traditional lock-on"), AppLanguage.choose("Assisted aim"), AppLanguage.choose("Assisted free aim"), AppLanguage.choose("Free aim")] }

    /// nil until the player has chosen on the launch screen.
    /// Sandbox map: 0 the GTA V map, 1 the test level the game files include (env_test).
    var sandboxMap: Int {
        get { defaults.integer(forKey: "sandboxMap") == 1 ? 1 : 0 }
        set { defaults.set(newValue == 1 ? 1 : 0, forKey: "sandboxMap") }
    }
    static var sandboxMapTitles: [String] { ["GTA V", AppLanguage.choose("GTA VI test map")] }
    var gameModeChoice: GameMode? {
        get { (defaults.object(forKey: "gameMode") as? Int).flatMap(GameMode.init) }
        set { defaults.set(newValue?.rawValue, forKey: "gameMode") }
    }
    /// Sandbox was the only mode before the choice existed.
    var gameMode: GameMode {
        get { gameModeChoice ?? .sandbox }
        set { gameModeChoice = newValue }
    }

    // Graphics. The default comes from the measured device tier.
    lazy var tier = DeviceTier.probe(capMB: memoryCapMB)
    var graphicsPreset: GraphicsPreset {
        // integer(forKey:) also reads "-graphicsPreset 4" given as a launch argument (a string).
        get {
            // GTA-241 (v1.5.2): 4 GB iPhones that saved a preset above Ultra Performance start from Ultra Performance
            // again, once. Not where only a memory cap makes the limit small (a test phone keeps its own choice).
            if memoryCapMB == 0, tier.lowMemory, !defaults.bool(forKey: "lowMemoryLiteReset") {
                defaults.set(true, forKey: "lowMemoryLiteReset")
                if let saved = defaults.object(forKey: "graphicsPreset") as? Int, saved > GraphicsPreset.lite.rawValue { defaults.removeObject(forKey: "graphicsPreset") }
            }
            guard defaults.object(forKey: "graphicsPreset") != nil, let preset = GraphicsPreset(rawValue: defaults.integer(forKey: "graphicsPreset")) else {
                #if targetEnvironment(macCatalyst)
                // Mac: Quality at most by default (about 80 FPS on an M4 with the frame rate unlocked); Ultra and Max stay a choice.
                return GraphicsPreset(rawValue: min(tier.recommended.rawValue, GraphicsPreset.quality.rawValue)) ?? .quality
                #else
                return tier.recommended
                #endif
            }
            return preset == .lite && !GraphicsPreset.liteAvailable ? .battery : preset
        }
        set { defaults.set(newValue.rawValue, forKey: "graphicsPreset") }
    }
    var resolutionScale: Double {
        get { defaults.object(forKey: "resolutionScale") as? Double ?? 1.0 }
        set { defaults.set(min(max(newValue, 0.5), 1.0), forKey: "resolutionScale") }
    }
    /// Render at the screen's shape instead of a stretched 16:9 picture.
    /// Render height in pixels, changeable while playing; 0 follows the detail preset.
    var renderHeight: Int {
        get { defaults.integer(forKey: "renderHeight") }
        set { defaults.set(max(0, newValue), forKey: "renderHeight") }
    }
    var matchScreenShape: Bool {
        get { defaults.object(forKey: "matchScreenShape") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "matchScreenShape") }
    }
    /// A hardware keyboard and mouse play through the game's own PC controls (on by default).
    /// Settings › Memory cap: the most memory (MB) the game may use, 0 automatic (the app's limit).
    var memoryCapMB: Int {
        get { defaults.integer(forKey: "memoryCapMB") }
        set { defaults.set(max(0, newValue), forKey: "memoryCapMB") }
    }
    /// The player's own graphics details over the preset (GTA-84): engine option name -> value, e.g.
    /// "textureQuality": "2". A detail not listed follows the preset. Kept when the preset changes.
    var graphicsOverrides: [String: String] {
        get { (defaults.dictionary(forKey: "graphicsOverrides") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "graphicsOverrides") }
    }
    /// A Sprint button on foot (sprinting also works by holding the move stick at its edge). Off by default.
    var sprintButton: Bool {
        get { defaults.bool(forKey: "sprintButton") }
        set { defaults.set(newValue, forKey: "sprintButton") }
    }
    /// Left/right buttons instead of the steering stick in vehicles. Off by default.
    var steeringButtons: Bool {
        get { defaults.bool(forKey: "steeringButtons") }
        set { defaults.set(newValue, forKey: "steeringButtons") }
    }
    /// Optional airplane throttle/rudder stick. Helicopters keep their buttons.
    var airplaneRightStick: Bool {
        get { defaults.bool(forKey: "airplaneRightStick") }
        set { defaults.set(newValue, forKey: "airplaneRightStick") }
    }
    /// Lower the frame rate while the phone is hot (NativePortViewController.thermalChanged). Off by default.
    var steadyWhenHot: Bool {
        get { defaults.bool(forKey: "steadyWhenHot") }
        set { defaults.set(newValue, forKey: "steadyWhenHot") }
    }
    /// Graphics › Sharper upscaling (MetalFX), off by default: it costs some GPU time.
    var sharperUpscaling: Bool {
        get { defaults.bool(forKey: "sharperUpscaling") }
        set { defaults.set(newValue, forKey: "sharperUpscaling"); PGSetSharperUpscaling(newValue ? 1 : 0) }
    }
    /// This device › Experimental (v1.4.3, on by default): improvements that player logs still have to confirm,
    /// each with a switch to turn it off. Read by the engine and renderer, so they apply when the app starts.
    var smarterTextureLoading: Bool {   // GTA-128: grey ground after long play
        get { defaults.object(forKey: "expSmarterTextureLoading") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "expSmarterTextureLoading") }
    }
    var lighterBigTextures: Bool {      // GTA-122: the largest textures without their top level
        get { defaults.object(forKey: "expLighterBigTextures") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "expLighterBigTextures") }
    }
    var fastEngineThreads: Bool {       // GTA-92: engine threads on the fast cores, queries sent at once
        get { defaults.object(forKey: "expFastEngineThreads") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "expFastEngineThreads") }
    }
    var compressedAlphaTextures: Bool { // GTA-118: BC3 textures kept as ASTC (lossy alpha); on by default since v1.4.4 (Kevin)
        get { defaults.object(forKey: "expCompressedAlphaTextures") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "expCompressedAlphaTextures") }
    }
    var steadyCityLowMemory: Bool {     // GTA-148: about 2 GB for the app: Lite draws detail closer, fewer people and cars
        get { defaults.object(forKey: "expSteadyCityLowMemory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "expSteadyCityLowMemory") }
    }
    var meshMemoryRelease: Bool {       // GTA-152: the engine's copy of each mesh handed back once the GPU has it; on by default below a 2,600 MB app limit (Kevin, 2026-10-21)
        // GTA-217: on every iPhone and iPad, with pages shared by several meshes too (mode 3: about 480 MB in a 6 GB city drive).
        // GTA-208/GTA-231: on Macs whose app limit is under 6 GB (60% of an 8 GB Mac: 4,915 MB). Lab Mac A/B 2026-10-26 at
        // that limit, teleport stress: 0 stops in 3 runs against 3, the same rural ground, engine memory 338 MB lower.
        get {
            #if targetEnvironment(macCatalyst)
            return defaults.object(forKey: "expMeshMemoryRelease") as? Bool ?? (tier.memoryLimitMB < 6144)
            #else
            return defaults.object(forKey: "expMeshMemoryRelease") as? Bool ?? true
            #endif
        }
        set { defaults.set(newValue, forKey: "expMeshMemoryRelease") }
    }
    var smallerEngineHeaps: Bool {      // GTA-124: Replay and debug heaps 16/128 MB instead of 196/220, off by default
        get { defaults.object(forKey: "expSmallerEngineHeaps") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "expSmallerEngineHeaps") }
    }
    /// A switch turned off sets the engine's own off value, unless a test launch already set it.
    static func applyExperimentalSwitches() {
        let settings = GameSettings.shared
        func off(_ name: String, _ value: String) { if getenv(name) == nil { setenv(name, value, 1) } }
        if !settings.smarterTextureLoading { off("PG_GUARD_POOL_ROOM", "0") }
        if !settings.lighterBigTextures { off("PG_BIG_MIP_SKIP", "0") }
        if !settings.fastEngineThreads { off("PG_ENGINE_QOS", "off"); off("PG_QUERY_COMMIT_MS", "2") }
        if !settings.compressedAlphaTextures { off("PG_ASTC_BC3", "0") }
        if settings.smallerEngineHeaps { off("PG_SMALL_ENGINE_HEAPS", "1") }
        if settings.meshMemoryRelease { off("PG_MESH_RELEASE", "3") }
    }
    /// Game controller feedback (on by default): rumble on the controller's motors, and the
    /// DualSense's adaptive triggers (ControllerFeedback).
    var controllerRumble: Bool {
        get { defaults.object(forKey: "controllerRumble") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "controllerRumble") }
    }
    var adaptiveTriggers: Bool {
        get { defaults.object(forKey: "adaptiveTriggers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "adaptiveTriggers") }
    }
    /// DualSense / DualShock light bar: the character's colour, flashing with the wanted level.
    var controllerLight: Bool {
        get { defaults.object(forKey: "controllerLight") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "controllerLight") }
    }
    var showFPS: Bool {
        get { defaults.object(forKey: "showFPS") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFPS") }
    }
    /// The FPS counter also shows CPU power, busy cores and the heat state (GTA-216): what heats the phone, while playing.
    var showPower: Bool {
        get { defaults.bool(forKey: "showPower") }
        set { defaults.set(newValue, forKey: "showPower") }
    }
    /// Touch controls › Minimap (GTA-131): where the game's minimap sits. The game reads it when it starts.
    enum MinimapPlace: Int, CaseIterable {
        case bottomLeft, topLeft, custom
        var title: String { [AppLanguage.choose("Bottom left"), AppLanguage.choose("Top left"), AppLanguage.choose("Custom")][rawValue] }
    }
    /// Subtitles above the home bar (GTA-95): the subtitle line moves up 5% of the screen (frontend.xml), so the home
    /// bar doesn't cover it. On by default on iPhones with a home bar.
    var subtitlesAboveHomeBar: Bool {
        get { defaults.object(forKey: "subtitlesAboveHomeBar") as? Bool ?? Self.hasHomeBar }
        set { defaults.set(newValue, forKey: "subtitlesAboveHomeBar") }
    }
    /// Face ID iPhones and iPads: no home button, a home bar at the bottom of the screen.
    static let hasHomeBar: Bool = {
        var info = utsname(); uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // Home-button iPhones: 8/8 Plus (iPhone10,1/2/4/5) and SE 2nd/3rd generation (iPhone12,8, iPhone14,6).
        return !["iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5", "iPhone12,8", "iPhone14,6"].contains(model) && !model.hasPrefix("iPhone9,")
    }()
    var minimapPlace: MinimapPlace {
        get { MinimapPlace(rawValue: defaults.integer(forKey: "minimapPlace")) ?? .bottomLeft }
        set { defaults.set(newValue.rawValue, forKey: "minimapPlace") }
    }
    /// The custom place, in the game's HUD units: offset from the usual bottom-left corner (x to the right,
    /// y negative = up) and a size factor.
    var minimapCustom: (dx: Double, dy: Double, scale: Double) {
        get {
            let v = defaults.array(forKey: "minimapCustom") as? [Double] ?? []
            return v.count == 3 ? (v[0], v[1], v[2]) : (0, 0, 1)
        }
        set { defaults.set([newValue.dx, newValue.dy, newValue.scale], forKey: "minimapCustom") }
    }
    /// What the game gets for the chosen place. Top left: up until the map's top edge is just below the screen's.
    var minimapLayout: (dx: Double, dy: Double, scale: Double) {
        switch minimapPlace {
        case .bottomLeft: return (0, 0, 1)
        case .topLeft: return (0, -0.79, 1)
        case .custom: return minimapCustom
        }
    }
    /// Touch controls › Help messages: where the game shows its help box ("Press … to …"). Its own place is the top left,
    /// where a minimap moved to the top covers it (and it covers the map), so then Top right is the default.
    enum HelpTextPlace: Int, CaseIterable {
        case topLeft = 0, topRight = 1, bottomMiddle = 2, custom = 3, topMiddle = 4
        static var allCases: [HelpTextPlace] { [.topLeft, .topMiddle, .topRight, .bottomMiddle, .custom] }
        var title: String {
            switch self {
            case .topLeft: return AppLanguage.choose("Top left")
            case .topMiddle: return AppLanguage.choose("Top middle")
            case .topRight: return AppLanguage.choose("Top right")
            case .bottomMiddle: return AppLanguage.choose("Bottom middle")
            case .custom: return AppLanguage.choose("Custom")
            }
        }
    }
    /// With the Controller buttons touch scheme on screen (GTA-195), LB sits under the top-left place: top middle then,
    /// under the top bar (GTA-197). With a controller playing the game's own place stays.
    var defaultHelpTextPlace: HelpTextPlace { minimapAtTop ? .topRight : GameSettings.hudContext == .pad ? .topMiddle : .topLeft }
    var helpTextPlace: HelpTextPlace {
        get { (defaults.object(forKey: "helpTextPlace") as? Int).flatMap(HelpTextPlace.init) ?? defaultHelpTextPlace }
        set { defaults.set(newValue.rawValue, forKey: "helpTextPlace") }
    }
    /// The custom place: the box's corner in the game's HUD units (from the HUD's top left); the size stays 1 (a larger
    /// size made the game's box only a little wider, not its text larger).
    var helpTextCustom: (x: Double, y: Double, scale: Double) {
        get {
            let v = defaults.array(forKey: "helpTextCustom") as? [Double] ?? []
            return v.count == 3 ? (v[0], v[1], v[2]) : (0, 0, 1)
        }
        set { defaults.set([newValue.x, newValue.y, newValue.scale], forKey: "helpTextCustom") }
    }
    /// What the game gets for a place (HelpTextGeometry: the box starts 0.0165 right of it and is 0.2 wide). Top right
    /// keeps the box inside the HUD's right edge, at the top as the game stacks it; bottom middle puts it low in the middle (a little left of centre, clear of the cover and crouch buttons),
    /// above the subtitles.
    func helpTextLayout(for place: HelpTextPlace) -> (x: Double, y: Double, scale: Double) {
        switch place {
        case .topLeft: return (0, 0, 1)
        case .topRight: return (0.742, 0, 1)
        case .topMiddle: return (0.3835, 0.125, 1)
        case .bottomMiddle: return (0.354, 0.62, 1)
        case .custom: return helpTextCustom
        }
    }
    var helpTextLayout: (x: Double, y: Double, scale: Double) { helpTextLayout(for: helpTextPlace) }
    /// The map sits in the top half: the FPS counter moves to the bottom left instead.
    var minimapAtTop: Bool { minimapLayout.dy < -0.4 && minimapLayout.dx < 0.25 }
    var keyboardMouse: Bool {
        get { defaults.object(forKey: "keyboardMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keyboardMouse") }
    }
    /// Self Radio's play order (GTA-5): 2 shuffle (the default here: songs start at the beginning and Next song
    /// works), 1 in order, 0 like a radio station (the PC's default: songs join midway, no skipping).
    var selfRadioMode: Int {
        get { defaults.object(forKey: "selfRadioMode") as? Int ?? 2 }
        set { defaults.set(min(max(newValue, 0), 2), forKey: "selfRadioMode") }
    }
    /// Settings › Touch controls › Touch scheme (GTA-195): the situational layout (default), or every Xbox controller
    /// button on screen all the time (ControllerPadView). A Mac has no touch screen: always situational there.
    enum TouchScheme: String, CaseIterable {
        case situational, controller
        var title: String { self == .situational ? AppLanguage.choose("Situational") : AppLanguage.choose("Controller buttons") }
    }
    var touchScheme: TouchScheme {
        get {
            #if targetEnvironment(macCatalyst)
            return .situational
            #else
            return defaults.string(forKey: "touchScheme").flatMap(TouchScheme.init) ?? .situational
            #endif
        }
        set { defaults.set(newValue.rawValue, forKey: "touchScheme") }
    }
    /// Hide the touch controls while a game controller is connected (on by default).
    var hideTouchWithController: Bool {
        get { defaults.object(forKey: "hideTouchWithController") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hideTouchWithController") }
    }
    var sixtyFPS: Bool { frameRateCap != 30 }
    /// Frame rate cap: 30, 60, or 0 for unlocked (up to the screen's refresh rate, 120 on ProMotion).
    var frameRateCap: Int {
        get {
            // integer(forKey:) also reads "-frameRateCap 60" given as a launch argument (a string; device tests, GTA-200).
            if defaults.object(forKey: "frameRateCap") != nil {
                let cap = defaults.integer(forKey: "frameRateCap")
                if [0, 30, 60].contains(cap) || cap == 40 && Self.supports40 { return cap }
            }
            #if targetEnvironment(macCatalyst)
            if defaults.object(forKey: "sixtyFPS") == nil { return 0 } // Mac: unlocked by default, no battery or heat limit like a phone's
            #endif
            return defaults.bool(forKey: "sixtyFPS") ? 60 : 30 // older versions stored a 60 FPS switch
        }
        set { defaults.set(newValue, forKey: "frameRateCap") }
    }
    static func frameRateTitle(_ cap: Int) -> String { cap == 0 ? AppLanguage.choose("Unlocked") : "\(cap) FPS" }
    /// 40 FPS: a third of a 120 Hz ProMotion screen's refreshes, so each frame shows equally long. Smoother than
    /// unlocked for phones that run between 40 and 60 (a quarter of ProMotion play sessions, PostHog 2026-10-21).
    /// A 60 Hz screen can't show 40 evenly, so the choice is only there with 120 Hz.
    static var supports40: Bool {
        #if targetEnvironment(simulator)
        // The simulator says 60 Hz; PG_TEST_40_FPS=1 offers 40 anyway, to test the pacing path.
        if ProcessInfo.processInfo.environment["PG_TEST_40_FPS"] == "1" { return true }
        #endif
        return UIScreen.main.maximumFramesPerSecond >= 120
    }
    static var frameRateChoices: [Int] { supports40 ? [30, 40, 60, 0] : [30, 60, 0] }
    /// The engine's frame limiter (in 60 Hz refreshes: 0 none, 1 = 60, 2 = 30); 40 runs unlimited and the
    /// renderer paces the pictures instead (PGSetPresentInterval).
    static func engineFrameLimit(_ cap: Int) -> Int32 { cap == 60 ? 1 : cap == 30 ? 2 : 0 }
    static func presentInterval(_ cap: Int) -> Double { cap == 40 ? 1.0 / 40 : 0 }

    // Crash fallback: a launch that never reached a stable world is treated
    // as a memory kill, and the last preset that worked is restored.
    private var bootPending: Bool {
        get { defaults.bool(forKey: "graphicsBootPending") }
        set { defaults.set(newValue, forKey: "graphicsBootPending") }
    }
    private var lastGoodPreset: GraphicsPreset? {
        get { (defaults.object(forKey: "lastGoodPreset") as? Int).flatMap(GraphicsPreset.init) }
        set { defaults.set(newValue?.rawValue, forKey: "lastGoodPreset") }
    }
    /// What changed after a launch that did not finish (shown once, in a popup, on the next start).
    struct BootRecovery {
        let failed: GraphicsPreset
        let fallback: GraphicsPreset
        /// The custom resolution that was set back to Auto, if any.
        let resetHeight: Int?
        let memoryLimitMB: Int
    }
    /// The previous launch didn't finish starting (iOS closed the app while it loaded). Changes nothing.
    var previousBootFailed: Bool {
        #if targetEnvironment(simulator)
        if !ProcessInfo.processInfo.arguments.contains("--simulate-failed-boot") { return false }
        #endif
        return bootPending
    }
    /// Lowers the settings when the previous launch failed. Returns what changed, or nil.
    func recoverFromFailedBoot() -> BootRecovery? {
        #if targetEnvironment(simulator)
        // Simulator runs are often stopped from Xcode; only phones need this (unless testing it).
        if !ProcessInfo.processInfo.arguments.contains("--simulate-failed-boot") { bootPending = false; return nil }
        #endif
        guard bootPending else { return nil }
        bootPending = false
        let failed = graphicsPreset
        // A preset that already ran stably on this phone is not the problem (the app was more likely
        // closed by an update or by Xcode): keep it, and only undo a resolution raised above it.
        let fallback = lastGoodPreset == failed ? failed
            : lastGoodPreset.flatMap { $0.rawValue < failed.rawValue ? $0 : nil }
            ?? GraphicsPreset(rawValue: max(GraphicsPreset.available[0].rawValue, min(failed.rawValue - 1, tier.recommended.rawValue))) ?? .performance
        // A custom resolution above the fallback's own also costs memory: back to Auto (unless that
        // resolution already ran stably with this preset).
        let provenHeight = fallback == lastGoodPreset ? defaults.integer(forKey: "lastGoodRenderHeight") : 0
        let resetHeight = renderHeight > max(fallback.height, provenHeight) ? renderHeight : nil
        guard fallback != failed || resetHeight != nil else { return nil }
        graphicsPreset = fallback
        if resetHeight != nil { renderHeight = 0 }
        return BootRecovery(failed: failed, fallback: fallback, resetHeight: resetHeight, memoryLimitMB: tier.memoryLimitMB)
    }
    /// "Try again anyway" in the popup: put the settings back as they were.
    func undoRecovery(_ recovery: BootRecovery) {
        graphicsPreset = recovery.failed
        if let height = recovery.resetHeight { renderHeight = height }
    }
    func markBootStarted() { bootPending = true }
    /// Leaving the app is not a crash.
    func markBootInterrupted() { bootPending = false }
    func markBootStable() {
        bootPending = false
        lastGoodPreset = graphicsPreset
        defaults.set(renderHeight == 0 ? graphicsPreset.height : renderHeight, forKey: "lastGoodRenderHeight")
    }
}
