import UIKit
import MetalKit
import GameController
import AVFAudio
import AVFoundation
#if targetEnvironment(macCatalyst)
import CoreAudio   // UnsafeMutableAudioBufferListPointer; iOS has it through AVFAudio
#endif
import UniformTypeIdentifiers
import os

private func engineLog(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let message, let context else { return }
    let controller = Unmanaged<NativePortViewController>.fromOpaque(context).takeUnretainedValue()
    LogWriter.shared.engine(String(cString: message), to: controller)
}

/// The log file and the engine's lines. The engine can print thousands of lines a second (a player's
/// log had 3 million in one session); one main-thread hop per line, each opening the file, starved
/// the UI: the whole app lagged and touch releases arrived late, so buttons acted held. Each line is
/// written at once through one open file handle on the thread that logs it (a crash's last lines
/// must reach the file), and the UI gets the lines in batches at most every 50 ms.
final class LogWriter {
    static let shared = LogWriter()
    private let queue = DispatchQueue(label: "log-writer", qos: .utility)
    private var handle: FileHandle?
    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false

    func open(_ file: URL) {
        lock.lock(); try? handle?.close(); handle = try? FileHandle(forWritingTo: file); _ = try? handle?.seekToEnd(); lock.unlock()
    }
    /// One line from the app itself, written in order with the engine's.
    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock(); try? handle?.write(contentsOf: data); lock.unlock()
    }
    func engine(_ line: String, to controller: NativePortViewController) {
        let data = (line + "\n").data(using: .utf8)
        lock.lock()
        if let data { try? handle?.write(contentsOf: data) }
        pending.append(line); let schedule = !flushScheduled; flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.05) {
            self.lock.lock(); let batch = self.pending; self.pending.removeAll(keepingCapacity: true); self.flushScheduled = false; self.lock.unlock()
            DispatchQueue.main.async { controller.engineLines(batch) }
        }
    }
}

final class NativePortViewController: UIViewController, MTKViewDelegate {
    private var metalView: MTKView!
    private var queue: MTLCommandQueue?
    private let output = UITextView()
    private let fpsLabel = UILabel()
    // Top left, or bottom left while the minimap sits at the top (GTA-131).
    private lazy var fpsAtTop = fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
    private lazy var fpsAtBottom = fpsLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
    /// iOS gives the game less than the city needs (the limit that recommends Ultra Performance; GTA-148). The FPS counter
    /// then starts with a red warning triangle, so a screenshot of missing textures shows at once that it's this phone.
    private lazy var lowMemoryDevice: Bool = {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return GameSettings.shared.tier.memoryLimitMB < 2600
        #endif
    }()
    private lazy var lowMemoryMark: NSAttributedString = {
        let triangle = NSTextAttachment()
        triangle.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        triangle.bounds = CGRect(x: 0, y: -1.5, width: 13, height: 12)
        let mark = NSMutableAttributedString(attachment: triangle)
        mark.append(NSAttributedString(string: " "))
        return mark
    }()
    /// The buttons that will be on screen (GTA-197), before the first frame of play decides it (pollController).
    private func expectedHUDContext() -> HUDTouchContext {
        #if targetEnvironment(macCatalyst)
        return .controller
        #else
        // As pollController decides: a touch-controls preview keeps them on screen unless a test controller is asked for.
        let arguments = ProcessInfo.processInfo.arguments
        var controller = !GCController.controllers().isEmpty && !arguments.contains("--touch-controls-preview")
        #if targetEnvironment(simulator)
        if arguments.contains("--test-controller") { controller = true }
        #endif
        if controller && GameSettings.shared.hideTouchWithController { return .controller }
        return GameSettings.shared.touchScheme == .controller ? .pad : .situational
        #endif
    }
    /// The HUD layout editor opened by the debug channel closed (GTA-197 tests).
    func debugHUDLayoutChanged() { placeFPSLabel() }
    private lazy var fpsAtLeft = fpsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12)
    /// A place the player chose in Settings › HUD layout (GTA-196): two guides from the safe area's top left, as wide and
    /// high as that fraction of the room the safe area leaves around the label.
    private let fpsRoomX = UILayoutGuide(), fpsRoomY = UILayoutGuide()
    private var fpsCustom: [NSLayoutConstraint] = []
    /// Help messages show at the top left this run (the game reads their place when it starts).
    private var helpTopLeft = true
    private func placeFPSLabel() {
        NSLayoutConstraint.deactivate(fpsCustom)
        fpsCustom = []
        if fpsRoomX.owningView == nil { view.addLayoutGuide(fpsRoomX); view.addLayoutGuide(fpsRoomY) }
        let safe = view.safeAreaLayoutGuide, size = HUDGeometry.fpsSize(lowMemory: lowMemoryDevice)
        guard let place = GameSettings.shared.fpsPlace else {
            // Its own place: the top left, or the bottom left when the minimap is at the top. With touch controls on
            // screen, lower down on the left, so a help message at the top left starts clear of it (GTA-197).
            let bottom = GameSettings.shared.minimapAtTop
            let lower = bottom ? nil : HUDGeometry.fpsDefaultDrop(GameSettings.hudContext, helpTopLeft: helpTopLeft)
            fpsAtLeft.isActive = true
            fpsAtTop.isActive = !bottom && lower == nil
            fpsAtBottom.isActive = bottom
            if let lower {
                fpsCustom = [fpsRoomY.topAnchor.constraint(equalTo: safe.topAnchor),
                             fpsRoomY.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: lower),
                             fpsLabel.topAnchor.constraint(equalTo: fpsRoomY.bottomAnchor)]
                NSLayoutConstraint.activate(fpsCustom)
            }
            return
        }
        NSLayoutConstraint.deactivate([fpsAtLeft, fpsAtTop, fpsAtBottom])
        fpsCustom = [
            fpsRoomX.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            fpsRoomX.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: place.x, constant: -place.x * size.width),
            fpsRoomY.topAnchor.constraint(equalTo: safe.topAnchor),
            fpsRoomY.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: place.y, constant: -place.y * size.height),
            fpsLabel.leadingAnchor.constraint(equalTo: fpsRoomX.trailingAnchor),
            fpsLabel.topAnchor.constraint(equalTo: fpsRoomY.bottomAnchor),
        ]
        NSLayoutConstraint.activate(fpsCustom)
    }
    private let inputTestLabel = UILabel()
    private var wasMouseSwipeActive = false
    private var lastDeviceDiagnostic = ""
    private var lastDeviceLogAt: CFTimeInterval = 0
    private var lastFPSLabelUpdate: CFTimeInterval = 0
    /// The start screen; it hides once the game's world is up.
    private lazy var home = HomeView(modes: GameMode.allCases.map { ($0.title, $0 == .story ? "book.fill" : "map.fill") }, log: output)
    private var launchButton: UIButton { home.playButton }
    private var preloadLabel: UILabel { home.preloadLabel }
    private var controllerLabel: UILabel { home.controllerLabel }
    private var diagnosticsOverlay: UIView? { home }
    private let audioEngine = AVAudioEngine()
    private var audioSource: AVAudioSourceNode?
    private lazy var loadingPill: UILabel = {
        let label = PaddedLabel()
        label.text = AppLanguage.choose("Loading…")
        label.font = Theme.body(14, .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.isUserInteractionEnabled = false
        return label
    }()
    /// Friend Request (GTA-73): how far the Lifeinvader presentation is, while the TV shows nothing.
    private lazy var presentationPill: UILabel = {
        let label = PaddedLabel()
        label.font = Theme.body(13, .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.isUserInteractionEnabled = false
        return label
    }()
    private var presentationSecond = -1
    /// The boot stopped and the audio was shut down on purpose (not restarted when the app is active again).
    private var audioShutDown = false
    private var audioRetry: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var lastControllerPoll: CFTimeInterval?
    private var lines: [String] = []
    private var metrics: [String: String] = [:]
    private var logFile: URL?
    private let touchControls = TouchControlsView(frame: .zero)
    /// Settings › Touch scheme › Controller buttons (GTA-195): every controller button on screen, under the touch layer.
    private let controllerPad = ControllerPadView(frame: .zero)
    private let modKeys = ModKeysView(frame: .zero)
    private let gyro = GyroInput()
    private var engineStarted = false
    /// The app was in the background at least once since it opened (the log's "App back in the foreground.").
    private var wasInBackground = false
    /// leftApp ran for the current time away (reset when the app is active again).
    private var leftAppHandled = false
    private let playStats = PlayStats()
    private var bootedPreset = GameSettings.shared.graphicsPreset
    private var bootedMode: GameMode?
    private var stableTimer: Timer?
    private var healthTimer: Timer?
    private var introView: IntroVideoView?
    private var lastCPU: (cpu: Double, wall: Double)?
    private var thermalFrameLimit: Int32 = -1
    private var thermalPresentInterval = 0.0

    /// A hot phone runs slower (iOS lowers the chip's speed), so uncapped frame rates swing between
    /// 60 and 15 within minutes; a player's log went "serious" 30 s in. With "Steady frame rate when
    /// hot" (off by default) the cap steps down while the phone is hot (fair: at most 60, serious: 30)
    /// and back to the player's choice when it cools; switching it off restores the choice.
    @objc private func thermalChanged() {
        // Benchmarks keep their own frame limit.
        if ProcessInfo.processInfo.environment["PG_BENCHMARK"] != nil { return }
        DispatchQueue.main.async { [self] in
            let cap = GameSettings.shared.frameRateCap
            let chosen = GameSettings.engineFrameLimit(cap)
            let state = ProcessInfo.processInfo.thermalState
            var limit = chosen
            if GameSettings.shared.steadyWhenHot {
                if state == .fair, cap == 0 { limit = 1 }
                if state == .serious || state == .critical { limit = 2 }
            }
            // 40 FPS paces the pictures in the renderer (the engine runs unlimited); 30 when hot replaces it.
            let interval = limit == chosen ? GameSettings.presentInterval(cap) : 0
            guard limit != thermalFrameLimit || interval != thermalPresentInterval else { return }
            if thermalFrameLimit >= 0 || limit != chosen || interval > 0 {
                appendLog("Thermal state \(["nominal", "fair", "serious", "critical"][min(3, state.rawValue)]): frame limit \(interval > 0 ? "40 FPS (paced)" : limit == 0 ? "off" : limit == 1 ? "60 FPS" : "30 FPS").")
                PGSetFrameLimit(limit)
                PGSetPresentInterval(interval)
            }
            thermalFrameLimit = limit
            thermalPresentInterval = interval
            updateDisplayRate()
        }
    }
    /// The refresh rate the game asks of the screen (GTA-200). Core Animation picks a ProMotion screen's rate: inside the
    /// display link's range it picks what suits it, and it lifts the screen to 120 Hz while a finger is on the glass. Touch
    /// players got 120 Hz that way, but a controller player never touches the screen, so with the old range (60 to 120, or
    /// the system default) the screen could stay at 60 or 80 Hz and the game could show no more pictures than that. Each
    /// frame rate now asks for one fixed rate, the same with touch or a controller:
    /// - Unlocked, 40 and 60 FPS: the screen's top rate (120 on ProMotion). 40 FPS is every third refresh of 120 Hz, and
    ///   the engine's 60 FPS limiter runs at 62-63 FPS, which a 60 Hz screen would hold back with pictures queued (input lag).
    /// - 30 FPS, and 30 when "Steady frame rate when hot" steps down: 60 Hz, which shows 30 evenly without the cost of 120.
    ///   Also 60 Hz while the game is on a TV: the phone's screen then shows only the controls.
    /// Low Power Mode, Limit Frame Rate and a hot device still cap the screen; the system lowers the rate then.
    /// PG_DISPLAY_RATE_OLD=1 (tests only) keeps the request of v1.4, for a before/after on one build.
    private func updateDisplayRate() {
        let cap = GameSettings.shared.frameRateCap
        let top = Float((view.window?.windowScene?.screen ?? UIScreen.main).maximumFramesPerSecond)   // the screen the game is on
        let environment = ProcessInfo.processInfo.environment
        let range: CAFrameRateRange
        if environment["PG_DISPLAY_RATE_OLD"] == "1" {
            range = cap == 0 || cap == 40 ? CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top) : .default
        } else {
            // What the engine runs at now: a benchmark's own limit, the hot-device step-down, or the player's choice.
            var limit = GameSettings.engineFrameLimit(cap), interval = GameSettings.presentInterval(cap)
            if environment["PG_BENCHMARK"] != nil {
                limit = Int32(environment["PG_BENCHMARK_FRAME_LIMIT"] ?? "") ?? 0; interval = 0
            } else if thermalFrameLimit >= 0 {
                limit = thermalFrameLimit; interval = thermalPresentInterval
            }
            // With the game on a TV the phone's screen shows only the controls: 60 Hz is plenty there.
            var rate = limit >= 2 && interval == 0 || tvWindow != nil ? min(60, top) : top
            // GTA-216 (another team's native port): iOS lets the performance cores sleep when the display link runs slower
            // than the screen, and CPU-bound frames then take longer. PG_DISPLAY_RATE=top (tests, until the phone A/B
            // decides) keeps the display link at the screen's top rate at every frame cap; the engine's limiter and the
            // present interval still pace the pictures. Test switch only: no gain on Kevin's phone (GTA-216 batch 1).
            if environment["PG_DISPLAY_RATE"] == "top" && tvWindow == nil { rate = top }
            range = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
        displayLink?.preferredFrameRateRange = range
        let asked = range.maximum == 0 ? "the system default" : range.minimum == range.maximum ? "\(Int(range.maximum)) Hz" : "\(Int(range.minimum))-\(Int(range.maximum)) Hz"
        if asked != askedDisplayRate {
            askedDisplayRate = asked
            appendLog("Display: asks the screen for \(asked) (frame rate \(GameSettings.frameRateTitle(cap)), screen up to \(Int(top)) Hz).")
        }
    }
    private var askedDisplayRate = ""
    /// Display link calls since the last Display line, and the rate its latest call was for (GTA-200).
    private var lastPowerSample = 0.0, powerText = ""
    private var displayLinkCalls = 0, displayLinkSince = CACurrentMediaTime(), displayLinkHz = 0.0
    /// Every 10 s with the Health line (GTA-200): the rate asked, the display link's rate, how many pictures reached the
    /// screen and the gaps between them, and whether a finger touched the screen or a controller is connected.
    private func logDisplay() {
        var shown = 0.0, fastGap = 0.0, medianGap = 0.0, notShown: UInt32 = 0
        PGShownFrameStats(&shown, &fastGap, &medianGap, &notShown)
        let now = CACurrentMediaTime()
        let calls = Double(displayLinkCalls) / max(0.001, now - displayLinkSince)
        displayLinkCalls = 0; displayLinkSince = now
        let touched = now - GameWindow.lastTouch < 10
        #if targetEnvironment(simulator)
        let controller = GCController.controllers().contains { $0.extendedGamepad != nil } || ProcessInfo.processInfo.arguments.contains("--test-controller")
        #else
        let controller = GCController.controllers().contains { $0.extendedGamepad != nil }
        #endif
        appendLog(String(format: "Display: asked %@ · display link %.0f Hz, %.0f calls/s · shown %.0f FPS, gaps %.1f ms fastest 5%%, %.1f ms median, %u not shown · touch %@ · controller %@",
                         askedDisplayRate, displayLinkHz, calls, shown, fastGap, medianGap, notShown, touched ? "yes" : "no", controller ? "yes" : "no"))
    }
    private var lastHealth: [UInt64] = [0, 0, 0, 0, 0, 0, 0, 0]
    private var padProof: PGPadState?
    /// Bumps when a new story-cheat sequence starts, so an older one stops writing the pad.
    private var storyCheatToken = 0
    /// Cheats › Spawn vehicle and the cheat actions: the note at the top while the game carries one out.
    private var vehicleSpawnTimer: Timer?
    private var vehicleSpawnNotice: UIView?
    private var lastGameStatus: UInt32 = 999
    private var worldReadyAt: CFTimeInterval?
    private var tiltNeutral: Double?
    private var tiltSince: CFTimeInterval?
    private var tiltSmoothed: Double = 0
    private var touchControlsAvailable = false
    private var lastTouchInputTrace = ""
    private var movementProofStarted = false
    private var proofController: GCController?
    private let controllerFeedback = ControllerFeedback()
    private var proofInputSamples = 0
    private var proofInputActive = false
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// The debug channel (DebugChannel.swift): its controller input, held until a time; the last pad sample sent.
    /// On the Mac only with PG_DEBUG_PORT set (GTA-176: tests on a real Mac without driving its mouse).
    private var debugPad = PGPadState(), debugPadUntil: CFTimeInterval = 0
    private(set) var debugLastPad = PGPadState()
    var debugTouchControls: DebugTouchSurface { controllerPad.isHidden ? touchControls : controllerPad }
    func debugPressPlay() { launchButton.sendActions(for: .touchUpInside) }
    /// The stop panel's mod button (GTA-178): pressed; its title after.
    func debugPressStopFix() -> String? { stopFixButton?.sendActions(for: .primaryActionTriggered); return stopFixButton?.configuration?.title }
    func debugHold(_ pad: PGPadState, for seconds: Double) { debugPad = pad; debugPadUntil = CACurrentMediaTime() + seconds }
    #endif
    #if targetEnvironment(simulator)
    private var simulatorKeys = Set<UIKeyboardHIDUsage>()
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // With keyboard and mouse on, keys reach the game as PC keys instead (KeyboardMouse).
        let pcKeys = GameSettings.shared.keyboardMouse && KeyboardMouse.shared.hasKeyboard
        for press in presses { if let key = press.key, !pcKeys { simulatorKeys.insert(key.keyCode) } }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { simulatorKeys.remove(key.keyCode) } }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        simulatorKeys.removeAll()
        super.pressesCancelled(presses, with: event)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// Playing with keyboard and mouse in front: the cursor is captured and keys belong to the game.
    /// Menus, Settings, a stopped game or another app in front give them back.
    private var macPlaying: Bool {
        engineStarted && GameSettings.shared.keyboardMouse && KeyboardMouse.shared.hasMouse && stoppedPanel == nil
            && presentedViewController == nil && !modKeys.trayOpen && UIApplication.shared.applicationState == .active
    }
    /// The window changed size while playing (left fullscreen, or dragged): the game takes the new size once
    /// the change settles, instead of stretching the picture it started with.
    private var macGameSize = CGSize.zero
    private var macResize: DispatchWorkItem?
    private lazy var macHomeWidth = home.widthAnchor.constraint(equalToConstant: 1024)
    private lazy var macHomeHeight = home.heightAnchor.constraint(equalToConstant: 768)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size, scale = HomeView.macScale(forHeight: size.height)
        if home.transform.a != scale { home.transform = CGAffineTransform(scaleX: scale, y: scale) }
        if macHomeWidth.constant != size.width / scale { macHomeWidth.constant = size.width / scale }
        if macHomeHeight.constant != size.height / scale { macHomeHeight.constant = size.height / scale }
        guard engineStarted, macGameSize != .zero, size != macGameSize else { return }
        macResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Not while the app is inactive: quitting from fullscreen shrinks the window first, and the device restore
            // that resize starts, with the pause menu opening, stopped the game during the quit (GTA-171, GTA-89).
            guard let self, self.view.bounds.size != self.macGameSize, UIApplication.shared.applicationState == .active else { return }
            self.macGameSize = self.view.bounds.size
            self.applyLiveResolution()
        }
        macResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    /// Paused on the Mac: Settings and Mods, as the touch controls offer them on iPhone. They're clicked with the
    /// game's own cursor (the Mac's stays captured), so the buttons themselves take no clicks.
    private let macPauseBar = UIStackView()
    private var macPauseButtons: [(button: UIButton, action: () -> Void)] = []
    private var macLeftWasDown = false
    /// The scroll wheel (and trackpad scrolling) as the window's scroll events: one notch per scroll step
    /// (KeyboardMouse.scroll; GameController's mouse scroll is unreliable on macOS). Up is the next weapon.
    private var macScrollY: CGFloat = 0
    @objc private func macScrolled(_ pan: UIPanGestureRecognizer) {
        let y = pan.translation(in: view).y
        if pan.state == .began { macScrollY = 0 }
        let delta = y - macScrollY
        macScrollY = y
        if engineStarted && delta != 0 { KeyboardMouse.shared.scroll(up: delta > 0) }
    }
    private func makeMacPauseBar() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(macScrolled))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []   // scrolls only, never clicks or drags
        view.addGestureRecognizer(scroll)
        func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.image = UIImage(systemName: symbol)
            config.imagePadding = 6
            config.cornerStyle = .capsule
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
            config.baseForegroundColor = .white
            let button = UIButton(configuration: config)
            button.isUserInteractionEnabled = false
            macPauseButtons.append((button, action))
            return button
        }
        macPauseBar.addArrangedSubview(button(AppLanguage.choose("Settings"), "gearshape.fill") { [weak self] in self?.showSettings() })
        macPauseBar.addArrangedSubview(button(AppLanguage.choose("Mods"), "puzzlepiece.extension.fill") { [weak self] in self?.modKeys.toggleTray() })
        macPauseBar.axis = .horizontal
        macPauseBar.spacing = 10
        macPauseBar.isHidden = true
        macPauseBar.isUserInteractionEnabled = false
        macPauseBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(macPauseBar)
        NSLayoutConstraint.activate([
            macPauseBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            macPauseBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }
    /// Every frame: shows the bar while the game's pause menu is open, lights the button under the game's cursor
    /// and runs it on a click.
    private func updateMacPauseBar() {
        let show = engineStarted && PGPauseMenuActive() && stoppedPanel == nil && presentedViewController == nil
            && UIApplication.shared.applicationState == .active && KeyboardMouse.shared.hasMouse
        macPauseBar.isHidden = !show
        macPauseButtons[1].button.isHidden = !modKeys.active   // Mods only while a script mod runs, as on iPhone
        // The click counts once, before anything runs: opening Settings polls the input again (touch controls
        // reset), and a click still seen as new there opened Settings over and over until the stack ran out.
        let down = KeyboardMouse.shared.leftDown
        let clicked = down && !macLeftWasDown
        macLeftWasDown = down
        var x: Float = 0, y: Float = 0
        guard show, PGMousePosition(&x, &y) else { return }
        let point = CGPoint(x: CGFloat(x) * view.bounds.width, y: CGFloat(y) * view.bounds.height)
        for (button, action) in macPauseButtons where !button.isHidden {
            let over = button.convert(button.bounds, to: view).insetBy(dx: -4, dy: -4).contains(point)
            button.configuration?.baseBackgroundColor = UIColor.black.withAlphaComponent(over ? 0.85 : 0.6)
            button.alpha = over ? 1 : 0.85
            if over && clicked { DispatchQueue.main.async(execute: action) }   // after this poll, not inside it
        }
    }
    // The game reads the keyboard itself (KeyboardMouse); passing its keys on makes macOS beep at each one.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !macPlaying { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !macPlaying { super.pressesEnded(presses, with: event) }
    }
    #endif

    override var prefersStatusBarHidden: Bool { true }
    // iOS 27.1's vertical bar (preferredVerticalBarBehavior) stays automatic: turning it off put a horizontal status
    // bar's space at the top of the iPhone Duo's outer screen, although the status bar is hidden (GTA-185).
    /// While playing with a mouse (iPad), the pointer is captured so moving it looks around.
    override var prefersPointerLocked: Bool { engineStarted && GameSettings.shared.keyboardMouse && KeyboardMouse.shared.hasMouse }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        controllerFeedback.log = { [weak self] in self?.appendLog($0) }
        let device = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: .zero, device: device)
        queue = device?.makeCommandQueue()
        metalView.delegate = self
        metalView.clearColor = MTLClearColorMake(0.025, 0.025, 0.035, 1)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)

        controllerLabel.text = AppLanguage.choose("Controller: none connected")
        // Progress text (preparing assets, loading) shows on the disabled Play button.
        let playStyle = launchButton.configurationUpdateHandler
        launchButton.configurationUpdateHandler = { [weak self] button in
            playStyle?(button)
            // Before Play is pressed a disabled button still says Play (files or mode missing).
            let play = ModGuard.withoutModsNextStart ? AppLanguage.choose("Play without mods") : AppLanguage.choose("Play")
            let title = button.isEnabled || !(self?.engineStarted ?? false) ? play : button.title(for: .disabled) ?? AppLanguage.choose("Loading…")
            var text = AttributedString(title)
            text.font = Theme.display(20, .heavy)
            text.foregroundColor = button.isEnabled ? UIColor(red: 0.16, green: 0.07, blue: 0.02, alpha: 1) : UIColor(white: 1, alpha: 0.7)
            button.configuration?.attributedTitle = text
            button.configuration?.image = title == play ? UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(weight: .heavy)) : nil
        }
        launchButton.addTarget(self, action: #selector(startEngine), for: .touchUpInside)
        output.isEditable = false
        output.isHidden = !ProcessInfo.processInfo.arguments.contains("--show-log")
        output.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        output.textColor = .white
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.layer.cornerRadius = 12
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: AppLanguage.changed, object: nil)
        home.settingsButton.addAction(UIAction { [weak self] _ in self?.showSettings() }, for: .touchUpInside)
        home.layoutButton.addAction(UIAction { [weak self] _ in self?.showLayoutEditor() }, for: .touchUpInside)
        home.onFiles = { [weak self] in self?.showGameFiles() }
        home.onMap = { [weak self] index in
            guard let self, !self.engineStarted else { return }
            GameSettings.shared.sandboxMap = index
            self.refreshModeChoice()
        }
        home.onMode = { [weak self] index in
            guard let self, !self.engineStarted else { return }
            GameSettings.shared.gameMode = GameMode.allCases[index]
            self.refreshModeChoice()
        }
        updateServerStatus()
        // Automation: --forget-game-folder starts with no game folder chosen (download and Continue tests, GTA-93).
        if ProcessInfo.processInfo.arguments.contains("--forget-game-folder") { GameFolder.clear() }
        // Debug/automation: --local-game-folder /path (a folder the app can already read) skips the picker.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--local-game-folder"), index + 1 < ProcessInfo.processInfo.arguments.count {
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1])
            if case let .refused(problem) = GameFolder.choose(folder) { appendLog("Game folder refused: " + problem) }
        }
        if GameFolder.isChosen { updateServerStatus() }
        else if !GameSettings.shared.assetServer.isEmpty { testAssetServer() }
        // Debug/automation: --game-mode story|sandbox picks the mode before Play.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--game-mode"), index + 1 < arguments.count {
            GameSettings.shared.gameMode = arguments[index + 1] == "story" ? .story : .sandbox
        }
        refreshModeChoice()
        home.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(home)
        fpsLabel.text = "— FPS"
        fpsLabel.isHidden = true
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        fpsLabel.textColor = .white
        fpsLabel.textAlignment = .center
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        fpsLabel.layer.cornerRadius = 6
        fpsLabel.clipsToBounds = true
        fpsLabel.isUserInteractionEnabled = false
        fpsLabel.accessibilityLabel = AppLanguage.choose("Game frame rate")
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)
        inputTestLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        inputTestLabel.textColor = .white
        inputTestLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        inputTestLabel.layer.cornerRadius = 6
        inputTestLabel.clipsToBounds = true
        inputTestLabel.textAlignment = .center
        inputTestLabel.isUserInteractionEnabled = false
        inputTestLabel.isHidden = true
        inputTestLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputTestLabel)
        touchControls.translatesAutoresizingMaskIntoConstraints = false
        touchControls.isHidden = true
        touchControls.inputChanged = { [weak self] in self?.pollController() }
        touchControls.openSettings = { [weak self] in self?.showSettings() }
        touchControls.hintsChanged = { [weak self] line in self?.appendLog(line) }
        KeyboardMouse.shared.start()
        KeyboardMouse.shared.changed = { [weak self] in
            guard let self else { return }
            self.appendLog("Keyboard: \(KeyboardMouse.shared.hasKeyboard ? "connected" : "none"), mouse: \(KeyboardMouse.shared.hasMouse ? "connected" : "none")")
            self.setNeedsUpdateOfPrefersPointerLocked()
        }
        view.addSubview(touchControls)
        // Under the touch layer, which keeps only Settings and Mods while this scheme is on (GTA-195).
        controllerPad.frame = view.bounds
        controllerPad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controllerPad.isHidden = true
        controllerPad.inputChanged = { [weak self] in self?.pollController() }
        controllerPad.overlay = touchControls
        view.insertSubview(controllerPad, belowSubview: touchControls)
        // Script mods asking for typed text (a car to spawn by name, a search) get the iPhone keyboard.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkModTextRequest() }
        // Script mods' keys (shows itself only while a script mod runs), above the touch controls.
        modKeys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modKeys)
        #if targetEnvironment(macCatalyst)
        makeMacPauseBar()
        #endif
        // The 🧩 Mods control lives in the touch controls (it is placed and moved like the others); the
        // tray it opens, the D-pad and the keyboard are ModKeysView.
        modKeys.activeChanged = { [weak self] active in self?.touchControls.modsActive = active }
        modKeys.anchor = { [weak self] in
            guard let self, let frame = self.touchControls.modsButtonFrame else { return nil }
            return self.touchControls.convert(frame, to: self.modKeys)
        }
        touchControls.openMods = { [weak self] in self?.modKeys.toggleTray() }
        #if targetEnvironment(simulator)
        // Test: PG_TEST_MODS_TRAY=<seconds> opens the mod tray that long after launch (screenshots).
        if let after = ProcessInfo.processInfo.environment["PG_TEST_MODS_TRAY"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.modKeys.toggleTray(); self?.appendLog("TEST: mod tray opened") }
        }
        #endif
        NSLayoutConstraint.activate([
            modKeys.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modKeys.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modKeys.topAnchor.constraint(equalTo: view.topAnchor),
            modKeys.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Diagnostics overlay sits over the transparent gesture surface but
        // cannot intercept touches (isUserInteractionEnabled=false).
        view.bringSubviewToFront(inputTestLabel)
        NSLayoutConstraint.activate([
            touchControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchControls.topAnchor.constraint(equalTo: view.topAnchor),
            touchControls.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NSLayoutConstraint.activate([
            fpsAtLeft,
            fpsAtTop,
            fpsLabel.widthAnchor.constraint(equalToConstant: lowMemoryDevice ? 84 : 68),
            fpsLabel.heightAnchor.constraint(equalToConstant: 24),
            inputTestLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            inputTestLabel.topAnchor.constraint(equalTo: fpsLabel.bottomAnchor, constant: 5),
            inputTestLabel.widthAnchor.constraint(equalToConstant: 210),
            inputTestLabel.heightAnchor.constraint(equalToConstant: 23)
        ])
        phoneGameConstraints = [
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
        NSLayoutConstraint.activate(phoneGameConstraints)
        #if targetEnvironment(macCatalyst)
        // Mac: the start screen is laid out for an iPad, so in a big window it's drawn smaller and scaled up to
        // fill it (viewDidLayoutSubviews; HomeView keeps its text sharp at that scale).
        NSLayoutConstraint.activate([
            home.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            home.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            macHomeWidth, macHomeHeight
        ])
        #else
        NSLayoutConstraint.activate([
            home.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            home.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            home.topAnchor.constraint(equalTo: view.topAnchor),
            home.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #endif
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFile = directory.appendingPathComponent("native-port.log")
        // Keep the previous run's log: after a crash it is the one worth sharing (Settings, Share log).
        // Only a run that started the game replaces it, so opening the app a few times after a crash
        // (without playing) doesn't push the crash out.
        let previous = directory.appendingPathComponent("native-port-previous.log")
        let lastRunPlayed = ((try? FileManager.default.attributesOfItem(atPath: logFile!.path)[.size] as? NSNumber)?.intValue ?? 0) > 16_384
        // A run that stopped is kept on its own until a log is sent, however often the game is started again (GTA-159).
        let stopReason = RunEnd.keepIfStopped(log: logFile!, becomesPrevious: lastRunPlayed || !FileManager.default.fileExists(atPath: previous.path))
        if lastRunPlayed || !FileManager.default.fileExists(atPath: previous.path) {
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logFile!, to: previous)
        }
        try? Data().write(to: logFile!)
        LogWriter.shared.open(logFile!)
        #if targetEnvironment(macCatalyst)
        appendLog("GTA V Port \(Theme.appVersion) on macOS \(UIDevice.current.systemVersion) (Mac app)")
        #else
        appendLog("GTA V Port \(Theme.appVersion) on iOS \(UIDevice.current.systemVersion)")
        #endif
        appendLog("Native UIKit + Metal host. Engine compiled into the app; no WebView or JIT.")
        appendLog("Metal device: \(device?.name ?? "unavailable")")
        if let stopReason { appendLog("Last run: \(stopReason). Its log is kept (\(RunEnd.stoppedName)) and goes with the next log sent.") }
        #if !targetEnvironment(macCatalyst)
        IOSDiagnostics.shared.log = { [weak self] line in self?.appendLog(line) }
        IOSDiagnostics.shared.start()
        #endif
        RunEnd.testCrashIfAsked(atLaunch: true)
        GameFolder.log = { [weak self] line in self?.appendLog(line) }
        // A game folder moved into Files › On My iPhone › GTA V Port is found without any picking.
        lookForGameFiles()
        NotificationCenter.default.addObserver(self, selector: #selector(lookForGameFiles), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(installChanged), name: .gameInstallChanged, object: nil)
        displayLink = CADisplayLink(target: self, selector: #selector(pollController))
        updateDisplayRate()
        displayLink?.add(to: .main, forMode: .common)
        #if targetEnvironment(simulator)
        DebugChannel.shared.start(self)
        #elseif targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.environment["PG_DEBUG_PORT"] != nil { DebugChannel.shared.start(self) }
        #endif
        observeExternalDisplays()
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged), name: .GCControllerDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseTouchControls), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(leftApp), name: UIApplication.didEnterBackgroundNotification, object: nil)
        #if targetEnvironment(macCatalyst)
        // A Mac app is quit rather than sent to the background; quitting is not a failed launch.
        NotificationCenter.default.addObserver(self, selector: #selector(leftApp), name: UIApplication.willTerminateNotification, object: nil)
        #endif
        // The log says when the app was in the background, so measurements and stalls can be told apart.
        // An end while the game runs in the foreground is a stop (GTA-159); leaving the app first is not.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in RunEnd.playing(false) }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            RunEnd.playing(self?.engineStarted == true); self?.leftAppHandled = false
        }
        for (name, label) in [(UIApplication.willResignActiveNotification, "inactive"), (UIApplication.didEnterBackgroundNotification, "in the background"),
                              (UIApplication.willEnterForegroundNotification, "back in the foreground"), (UIApplication.didBecomeActiveNotification, "active")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == UIApplication.didEnterBackgroundNotification { self.wasInBackground = true }
                // With scenes (GTA-171) iOS also says "will enter foreground" as the app opens; only a return counts.
                if name == UIApplication.willEnterForegroundNotification && !self.wasInBackground { return }
                self.appendLog("App \(label).")
            }
        }
        // A newer release on GitHub: say so once per version, pointing to the Telegram group.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            UpdateCheck.run(from: self) { [weak self] line in DispatchQueue.main.async { self?.appendLog(line) } }
        }
        // GTA-153: after an update, mods the previous version had on but didn't use stay off; after a start with
        // mods that didn't finish, the mods are the first suspect (17% of starts with mods failed on v1.4.4, 1.5% without).
        let modsSwitchedOff = ModGuard.afterUpdate()
        if !modsSwitchedOff.isEmpty {
            appendLog("Mods: \(modsSwitchedOff.count) switched off after the update (the previous version didn't use them): \(modsSwitchedOff.joined(separator: ", ")).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.explainModsSwitchedOff(modsSwitchedOff) }
        }
        if ModGuard.previousStartFailedWithMods(bootPending: GameSettings.shared.previousBootFailed) {
            appendLog("Previous start had mods on and didn't finish; offering to start without them.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.offerStartWithoutMods() }
        } else {
            recoverGraphicsAfterFailedBoot()
        }
        if ProcessInfo.processInfo.arguments.contains("--touch-controls-preview") {
            diagnosticsOverlay?.isHidden = true
            touchControlsAvailable = true
            fpsLabel.isHidden = !GameSettings.shared.showFPS
            touchControls.isHidden = false
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preloadChanged), name: .assetPreloadChanged, object: nil)
        // Continue an unfinished "Download all game files" after a relaunch.
        AssetPreloader.shared.resumeIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("--preload-autostart") {
            // Debug: start the download without tapping (simulator checks).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let message = AssetPreloader.shared.start() { self.appendLog("Preload refused: " + message) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-layout-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showLayoutEditor() }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-help-text-editor") || ProcessInfo.processInfo.arguments.contains("--open-hud-layout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let editor = HUDLayoutEditorController(select: ProcessInfo.processInfo.arguments.contains("--open-help-text-editor") ? .helpText : nil)
                editor.onDone = { [weak self] in self?.placeFPSLabel() }
                self.present(editor, animated: false)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-game-files") || ProcessInfo.processInfo.arguments.contains("--install-link") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showGameFiles() }
        }
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSettings() }
        }
        if ProcessInfo.processInfo.arguments.contains("--boot-engine") {
            DispatchQueue.main.async { self.startEngine() }
        }
    }

    @objc private func preloadChanged() {
        let summary = AssetPreloader.shared.launchSummary
        preloadLabel.text = summary
        preloadLabel.isHidden = summary == nil
    }

    /// A batch of engine lines (LogWriter has written them to the file already).
    func engineLines(_ batch: [String]) {
        // Only the last 500 lines can show; older ones in a big batch only need their checks.
        for line in batch { handleLine(line, written: true, show: false) }
        lines.append(contentsOf: batch.suffix(500))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        refreshLogView()
    }

    func appendLog(_ line: String) {
        // Lines also come from background work (checking the game files); the log view is UI.
        guard Thread.isMainThread else { DispatchQueue.main.async { self.appendLog(line) }; return }
        NSLog("[native-port] %@", line)
        handleLine(line, written: false, show: true)
    }

    private func handleLine(_ line: String, written: Bool, show: Bool) {
        playStats.line(line)
        // Why the game stops (GTA-178): the lines StopCause reads, kept for the stop panel.
        if line.hasPrefix("Fatal Error:") || line.hasPrefix("Native trap functions:") {
            stopEvidence.append(line)
            if stopEvidence.count > 12 { stopEvidence.removeFirst() }
        } else if line.hasPrefix("Executing changeset ") {
            stopEvidence.removeAll { $0.hasPrefix("Executing changeset ") }
            stopEvidence.append(line)
        }
        if line.hasPrefix("ASSET_WARM_PROGRESS ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3 {
                let size = Double(parts[2]).map { String(format: "%.1f GB", $0 * 1048576 / 1_000_000_000) } ?? ""
                launchButton.setTitle(AppLanguage.interpolate(AppLanguage.choose("Preparing assets… {arg0}% · {arg1}"), [String(parts[1]), size]), for: .disabled); launchButton.setNeedsUpdateConfiguration()
            }
        }
        if line == "ASSET_WARM_COMPLETE" { launchButton.setTitle(AppLanguage.choose("Loading…"), for: .disabled); launchButton.setNeedsUpdateConfiguration() }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--capture-world") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { PGCaptureNativeFrame("optimized-world") }
        }
        if line == "WORLD_READY", let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--pad-script"), i + 1 < ProcessInfo.processInfo.arguments.count, !movementProofStarted {
            movementProofStarted = true
            runPadScript(ProcessInfo.processInfo.arguments[i + 1])
        }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--verify-pad"), !movementProofStarted {
            movementProofStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.verifyVirtualPad() }
        }
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--verify-movement"), !movementProofStarted {
            movementProofStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.verifyMovement() }
        }
        if line == "WORLD_READY" { PGSetTargetingMode(Int32(GameSettings.shared.targetingMode)); PGSetSelfRadioMode(Int32(GameSettings.shared.selfRadioMode)); if worldReadyAt == nil { worldReadyAt = CACurrentMediaTime() } }
        // Debug: --open-settings-in-game opens Settings 10 s into the world.
        if line == "WORLD_READY", ProcessInfo.processInfo.arguments.contains("--open-settings-in-game") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.showSettings() }
        }
        if line == "WORLD_READY", healthTimer == nil {
            // Every 10 s: memory, how often the memory guard held streaming back, and game-file reads.
            healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.logHealth() }
            NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            thermalChanged()
        }
        if line.hasPrefix("Pause menu graphics for the next start") { keepPauseMenuGraphics(line) }
        if line == "WORLD_READY" { RunEnd.testCrashIfAsked() }
        if line == "WORLD_READY", stableTimer == nil {
            // Three minutes in the world counts as a launch that fits in memory.
            stableTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in GameSettings.shared.markBootStable(); ModGuard.startedStably() }
            // Which switched-on mods the game used (scripts load once the player exists), for the next update (GTA-153).
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.recordModUse() }
            #if targetEnvironment(simulator)
            // Automation: --test-pause-resize <s> opens the pause menu that long into play, then resizes live
            // 3 s later, as Settings does when the resolution changes while the game is paused.
            let testArguments = ProcessInfo.processInfo.arguments
            if let i = testArguments.firstIndex(of: "--test-pause-resize"), i + 1 < testArguments.count, let seconds = Double(testArguments[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if !testArguments.contains("--test-no-pause") { self?.appendLog("Test: opening the pause menu."); PGRequestPauseMenu() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.appendLog("Test: live resize while paused."); PGSetBackBufferSize(960, 444)
                    }
                }
            }
            #endif
        }
        if line == "WORLD_READY" || line.contains("\"label\":\"First frame\"") {
            diagnosticsOverlay?.isHidden = true
            #if !targetEnvironment(macCatalyst)
            touchControlsAvailable = true   // a Mac has no touch screen: keyboard, mouse or a controller
            #endif
            fpsLabel.isHidden = !GameSettings.shared.showFPS
        }
        if line.hasPrefix("Native boot stopped:") || line == "iOS could not reserve the engine memory." {
            audioShutDown = true
            audioEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            metalView.isPaused = true
        }
        // The engine couldn't get its memory at all (iPhone 8, 8 Plus and X on a free Apple ID): say so,
        // instead of a frozen picture that drops back to the home screen.
        if line == "iOS could not reserve the engine memory." {
            showEngineStopped(title: AppLanguage.choose("Not enough memory on this iPhone"),
                              message: AppLanguage.choose("iOS can't give the game the memory it needs on this iPhone. iPhone 8, 8 Plus and X usually can't run it with a free Apple ID; a paid developer account or TrollStore may help. Send the log if your iPhone is newer."))
        }
        // The engine stopped during play (a trap on one of its threads, or an unported function):
        // the picture freezes or goes black and the pause menu never opens. The touch Settings button
        // may be hidden (it is with a controller), so a panel offers Send log and Settings (GTA-21).
        if engineStarted, line.hasPrefix("Native game thread stopped:") || line.hasPrefix("Native boot stopped:")
            || line.hasPrefix("Engine stopped at unported host function:") {
            if stableTimer?.isValid != false { ModGuard.stoppedWhileStarting() }
            showEngineStopped()
        }
        if !written { LogWriter.shared.write(line) }
        for key in ["[wgpu] fps:", "[wgpu] draw costs", "Native frame costs:", "Phone memory:", "WORLD_READY"] where line.hasPrefix(key) {
            metrics[key] = line
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), let logFile {
                try? data.write(to: logFile.deletingLastPathComponent().appendingPathComponent("native-metrics.json"), options: .atomic)
            }
        }
        guard show else { return }
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        refreshLogView()
    }

    private func refreshLogView() {
        guard diagnosticsOverlay?.isHidden != true else { return }
        output.text = lines.joined(separator: "\n")
        if !output.text.isEmpty { output.scrollRangeToVisible(NSRange(location: output.text.utf16.count - 1, length: 1)) }
    }

    /// The game's intro (Resources/intro.mp4) plays over the boot screen while the engine loads
    /// behind it; it fades out when it ends or on a tap, onto whatever the game shows by then.
    private func playIntro() {
        let arguments = ProcessInfo.processInfo.arguments
        let forced = ProcessInfo.processInfo.environment["PG_TEST_INTRO"] != nil // automated launches skip it unless asked
        guard introView == nil, forced || !arguments.contains("--boot-engine"), ProcessInfo.processInfo.environment["PG_BENCHMARK"] == nil,
              let url = Bundle.main.url(forResource: "intro", withExtension: "mp4") else { return }
        let intro = IntroVideoView(frame: view.bounds, url: url, muted: arguments.contains("--mute"))
        intro.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        intro.finished = { [weak self, weak intro] in
            introPlaying = false
            UIView.animate(withDuration: 0.4, animations: { intro?.alpha = 0 }) { _ in intro?.removeFromSuperview(); self?.introView = nil }
        }
        view.addSubview(intro)
        introView = intro
        introPlaying = true
        intro.play()
        // Overlays added while it plays (touch controls, the FPS label) stay underneath it.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak intro] timer in
            guard let self, let intro, intro.superview != nil else { timer.invalidate(); return }
            self.view.bringSubviewToFront(intro)
        }
        appendLog("Intro video playing.")
    }

    /// The launch screen asks for a mode once; after that it remembers it.
    private func refreshModeChoice() {
        let choice = GameSettings.shared.gameModeChoice
        home.setMode(choice.flatMap { GameMode.allCases.firstIndex(of: $0) }, detail: choice?.detail ?? AppLanguage.choose("Choose Story mode or Sandbox to play."), enabled: !engineStarted)
        let testMap = GameFolder.isChosen && GameFolder.testMapAvailable
        if !testMap && GameSettings.shared.sandboxMap == 1 { GameSettings.shared.sandboxMap = 0 }
        home.setMap(GameSettings.shared.sandboxMap, visible: choice == .sandbox, enabled: !engineStarted, testMapAvailable: testMap)
        updatePlayEnabled()
    }

    @objc private func startEngine() {
        if GameSettings.shared.gameModeChoice == nil {
            // Automated launches without a choice keep the old sandbox start.
            guard ProcessInfo.processInfo.arguments.contains("--boot-engine") else { return }
        }
        guard let path = EnginePaths.manifest else {
            appendLog("Asset manifest is missing from the app bundle.")
            return
        }
        // No game files on this device and a server that doesn't answer: the game would start with no files and
        // stop (8 v1.4.4 logs, GTA-153). Check the server once more; if it still doesn't answer, open Game files.
        if !engineStarted, !GameFolder.isChosen, serverAnswered != true, !ProcessInfo.processInfo.arguments.contains("--boot-engine") {
            launchButton.isEnabled = false
            testAssetServer { [weak self] answered in
                guard let self else { return }
                if answered { self.startEngine(); return }
                self.appendLog("Play: no game files on this device and the server doesn't answer (\(self.serverProblem)); opened Game files.")
                self.updatePlayEnabled()
                self.showGameFiles()
            }
            return
        }
        #if targetEnvironment(macCatalyst)
        // Fullscreen first: the game keeps the size it starts at, so starting in a window and then going
        // fullscreen stretches the picture. Waits for the switch (about a second), then starts.
        if !engineStarted, MacWindow.enterFullScreen() {
            launchButton.isEnabled = false
            appendLog("Mac: switching to fullscreen before the game starts.")
            var waited = 0.0
            func startWhenFullScreen() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.engineStarted else { return }
                    waited += 0.2
                    // A short settle after the switch so the view has its final size.
                    if MacWindow.isFullScreen && waited >= 1.0 || waited >= 4 { self.startEngine() } else { startWhenFullScreen() }
                }
            }
            startWhenFullScreen()
            return
        }
        #endif
        metalView.isPaused = true
        metalView.delegate = nil
        // Dawn owns the drawable size from here; MTKView must not reset it on layout.
        metalView.autoResizeDrawable = false
        PGAttachMetalLayer(Unmanaged.passUnretained(metalView.layer).toOpaque())
        DispatchQueue.main.async { [weak self] in self?.updateExternalDisplay(resize: false) }
        launchButton.isEnabled = false
        home.settingsButton.isHidden = true
        home.layoutButton.isHidden = true
        engineStarted = true
        RunEnd.playing(true)
        setNeedsUpdateOfPrefersPointerLocked()   // the pointer lock depends on engineStarted
        #if targetEnvironment(macCatalyst)
        macGameSize = view.bounds.size
        #else
        phoneGameSize = view.bounds.size; followedSize = phoneGameSize
        #endif
        ModInstaller.gameRunning = true
        playStats.gameStarting(GameSettings.shared.gameMode, sandboxMap: GameSettings.shared.sandboxMap)
        refreshModeChoice()
        let mode = GameSettings.shared.gameMode
        bootedMode = mode
        let testMap = mode == .sandbox && GameSettings.shared.sandboxMap == 1
        PGSetStartMode(testMap ? 3 : Int32(mode.rawValue))
        let minimap = GameSettings.shared.minimapLayout
        PGSetMinimapLayout(minimap.dx, minimap.dy, minimap.scale)
        // The buttons on screen decide the help messages' own place (GTA-197): know them before the game reads it.
        GameSettings.hudContext = expectedHUDContext()
        let help = GameSettings.shared.helpTextLayout
        PGSetHelpTextLayout(help.x, help.y, help.scale)
        helpTopLeft = help == (0, 0, 1)
        PGSetSubtitleRaise(GameSettings.shared.subtitlesAboveHomeBar ? 0.05 : 0)
        GameSettings.shared.applyHUDLayout()
        TouchControlsView.minimapLayout = minimap
        placeFPSLabel()
        appendLog("Game mode: \(mode.title)\(mode == .sandbox ? " on " + GameSettings.sandboxMapTitles[GameSettings.shared.sandboxMap] : "")")
        bootedPreset = GameSettings.shared.graphicsPreset
        // A TV already connected gets the picture from the start, in its own shape.
        let tvScreen = ProcessInfo.processInfo.arguments.contains("--no-tv") ? nil : TVSceneDelegate.scene?.screen
        appendLog("Graphics: " + GraphicsConfiguration.apply(GameSettings.shared, screen: tvScreen?.bounds.size ?? view.bounds.size, tv: tvScreen != nil))
        appendLog("Device: " + GameSettings.shared.tier.summary)
        // Which screen the game starts on and what the system keeps clear on it (the iPhone Duo's two screens, GTA-185).
        let insets = view.safeAreaInsets
        appendLog("Screen: \(Int(view.bounds.width))×\(Int(view.bounds.height)) points at \(Int(view.window?.windowScene?.screen.scale ?? 0))x, safe area insets top \(Int(insets.top)), left \(Int(insets.left)), bottom \(Int(insets.bottom)), right \(Int(insets.right)).")
        GameSettings.shared.markBootStarted()
        playIntro()
        launchButton.setTitle(AppLanguage.choose("Loading…"), for: .disabled); launchButton.setNeedsUpdateConfiguration()
        appendLog("Native touch controls support held buttons, sprint and weapon selection.")
        installModsForTest()
        if ModGuard.starting() { PGSetModsOff(true) } else { noticeMods() }
        noticeLowMemory()
        startAudio()
        let (root, rootNote) = EnginePaths.filesRoot()
        if let rootNote { appendLog(rootNote) }
        // Self Radio (GTA-5): the song list the game reads, from Files › GTA V Port › Self Radio.
        try? FileManager.default.createDirectory(at: SelfRadio.folder, withIntermediateDirectories: true)
        let songs = Int(PGUserMusicPrepare(SelfRadio.folder.path, root))
        if songs > 0 || !SelfRadio.files().isEmpty {
            appendLog("Self Radio: \(songs) songs" + (songs < SelfRadio.minimumSongs ? " (the station shows with \(SelfRadio.minimumSongs) or more)." : "."))
        }
        // The game's own settings.xml only holds graphics and display options, which the app sets on
        // every launch. Some choices in the game's pause menu (MSAA, DirectX version, resolution)
        // stopped it from starting at all, so the file is reset before each launch.
        for mode in ["userdata", "sandbox"] {
            let settings = "\(root)/\(mode)/Documents/Rockstar Games/GTA V/settings.xml"
            if (try? FileManager.default.removeItem(atPath: settings)) != nil { appendLog("Reset the game's own graphics settings (\(mode)); use the app's Settings for graphics.") }
        }
        if GameFolder.isChosen {
            guard let data = GameFolder.open() else {
                appendLog("The game folder on this iPhone can't be opened any more. Choose it again.")
                showWhenFree(title: AppLanguage.choose("Game files not found"), message: AppLanguage.choose("The game folder was moved or deleted. Put it back in Files › On My iPhone › GTA V Port, or pick it again."))
                GameFolder.clear(); updateServerStatus(); launchButton.isEnabled = true; launchButton.setTitle(AppLanguage.choose("Play"), for: .normal)
                return
            }
            PGSetLocalGameFolder(data.path)
        } else {
            PGSetAssetServer(GameSettings.shared.assetServer)
        }
        AssetPreloader.shared.engineRunning = true
        path.withCString { manifest in
            root.withCString { PGStartEngine(manifest, $0, engineLog, Unmanaged.passUnretained(self).toOpaque()) }
        }
    }

    /// GTA-153: which of the switched-on mods this start used; the next update keeps the unused ones off.
    private func recordModUse() {
        guard !ModGuard.startsWithoutMods else { return }
        var buffer = [CChar](repeating: 0, count: 65536)
        PGModsUsed(&buffer, buffer.count)
        let used = Set(String(cString: buffer).split(separator: "\n").map(String.init))
        let on = ModInstaller.installed().filter { $0.enabled && $0.waiting == 0 }
        guard !on.isEmpty else { return }
        ModGuard.recordUse(used)
        let unused = on.filter { !used.contains($0.name) }.map(\.name)
        appendLog("Mods: this start used \(on.count - unused.count) of \(on.count) switched-on mods\(unused.isEmpty ? "" : "; not used: " + unused.joined(separator: ", ")).")
    }

    private func verifyMovement() {
        let testController = GCController.withExtendedGamepad()
        guard let pad = testController.extendedGamepad else {
            appendLog("Movement proof needs the native touch controller.")
            return
        }
        appendLog("Movement proof: capturing the world before native controller input.")
        PGCaptureNativeFrame("movement-before")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.proofController = testController
            self.proofInputActive = true
            self.proofInputSamples = 0
            pad.leftThumbstick.setValueForXAxis(0, yAxis: 0.8)
            pad.rightThumbstick.setValueForXAxis(0.25, yAxis: 0)
            self.appendLog("Movement proof: native controller sticks active.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.proofInputActive = false
                self.appendLog("Movement proof: \(self.proofInputSamples) controller samples delivered to the engine.")
                pad.leftThumbstick.setValueForXAxis(0, yAxis: 0)
                pad.rightThumbstick.setValueForXAxis(0, yAxis: 0)
                self.proofController = nil
                PGCaptureNativeFrame("movement-after")
                self.appendLog("Movement proof: native controller sticks released.")
            }
        }
    }

    /// Debug: scripted controller input, "step;step;..." with steps "wait:<s>", "hold:<buttons>:<s>"
    /// (buttons: a b x y l1 r1 lt rt down up left right start rx+ rx- ry+ ry- lx+ lx- ly+ ly-, joined with +), "frame:<name>".
    /// Debug: --watch-memory <address> <length> logs which bytes change between pad-script frames.
    private var watchSnapshot: [UInt8]?
    private func watchMemory(_ label: String) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--watch-memory"), i + 2 < args.count,
              let start = UInt64(args[i + 1]), let length = Int(args[i + 2]) else { return }
        var now = [UInt8](repeating: 0, count: length)
        guard now.withUnsafeMutableBytes({ PGDebugReadMemory(start, $0.baseAddress, UInt64(length)) }) else { return }
        if let before = watchSnapshot {
            var changes: [String] = []
            for k in 0..<length where before[k] != now[k] { changes.append("\(start + UInt64(k)):\(before[k])>\(now[k])") }
            appendLog("Memory watch \(label): \(changes.count) changed " + changes.prefix(400).joined(separator: " "))
        }
        watchSnapshot = now
    }
    private func runPadScript(_ script: String) {
        var at = 0.0
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":").map(String.init)
            switch parts.first {
            case "wait": at += Double(parts.count > 1 ? parts[1] : "1") ?? 1
            case "limit":
                let value = Int32(parts.count > 1 ? parts[1] : "2") ?? 2
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { PGSetFrameLimit(value) }
            case "weapon":
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { PGNextAircraftWeapon(); self.appendLog("Pad script: next aircraft weapon") }
            case "frame":
                let name = parts.count > 1 ? parts[1] : "script"
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { PGCaptureNativeFrame(name); self.appendLog("Pad script: frame \(name)"); self.watchMemory(name) }
            case "hold":
                var state = PGPadState(); var held = PadButtons()
                // Stick directions end in + or -, so "ly++a+rx+" is ly+, a and rx+.
                let spec = parts.count > 1 ? parts[1] : ""
                let names = (try? NSRegularExpression(pattern: "[lr][xy][+-]|[a-z0-9]+"))?
                    .matches(in: spec, range: NSRange(spec.startIndex..., in: spec))
                    .compactMap { Range($0.range, in: spec).map { String(spec[$0]) } } ?? []
                for name in names {
                    switch name {
                    case "a": held.insert(.a); case "b": held.insert(.b); case "x": held.insert(.x); case "y": held.insert(.y)
                    case "l1": held.insert(.l1); case "r1": held.insert(.r1); case "down": held.insert(.down); case "up": held.insert(.up)
                    case "left": held.insert(.left); case "right": held.insert(.right); case "start": held.insert(.start)
                    case "lt": state.leftTrigger = 1; case "rt": state.rightTrigger = 1
                    case "rx+": state.rightX = 1; case "rx-": state.rightX = -1; case "ry+": state.rightY = 1; case "ry-": state.rightY = -1
                    case "ly+": state.leftY = 1; case "ly-": state.leftY = -1; case "lx+": state.leftX = 1; case "lx-": state.leftX = -1
                    default: break
                    }
                }
                state.padButtons = held
                let duration = Double(parts.count > 2 ? parts[2] : "0.3") ?? 0.3
                let label = String(step)
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.padProof = state; self.appendLog("Pad script: \(label)") }
                at += duration
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.padProof = PGPadState() }
            default: break
            }
        }
        // Hand input back to the touch controls (and controller) when the script ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.5) { self.padProof = nil; self.appendLog("Pad script: done") }
    }

    /// Presses one of the game's own controller cheat sequences, then gives the pad back.
    private func playStoryCheat(_ cheat: StoryCheat, resumed: Bool = false) {
        // Settings paused the game; cheats are typed in play, so leave the pause menu first (Start).
        if PGPauseMenuActive() && !resumed {
            appendLog("Story cheat \(cheat.title): leaving the pause menu first.")
            PGRequestPauseMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.playStoryCheat(cheat, resumed: true) }
            return
        }
        let status = PGGameStatus()
        if PGPauseMenuActive() || (status & (1 | 4 | 8 | 16)) != 0 {
            appendLog("Story cheat skipped (\(cheat.title)): pause menu, cutscene, or no player.")
            return
        }
        storyCheatToken += 1
        let token = storyCheatToken
        appendLog("Story cheat: \(cheat.title)")
        var at = 0.4
        // Each press spans several frames even when a frame runs long (a 0.09 s press was about
        // 3 frames at 30 FPS, and one stutter could drop it and void the whole cheat).
        let hold = 0.15
        let gap = 0.1
        for input in cheat.inputs {
            let state = input.state
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, self.storyCheatToken == token else { return }
                self.padProof = state
            }
            at += hold
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, self.storyCheatToken == token else { return }
                self.padProof = PGPadState()
            }
            at += gap
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.15) { [weak self] in
            guard let self, self.storyCheatToken == token else { return }
            self.padProof = nil
            self.appendLog("Story cheat entered: \(cheat.title)")
        }
    }

    /// Simulator proof that the engine accepts the virtual controller and
    /// that controller aiming locks on: walk, pick a gun from the wheel, aim.
    private func verifyVirtualPad() {
        func log(_ step: String) { appendLog("Pad proof: \(step); input device \(PGLastInputDevice()), targeting mode \(PGTargetingMode())") }
        func pad(_ build: (inout PGPadState) -> Void) -> PGPadState { var s = PGPadState(); build(&s); return s }
        let steps: [(Double, PGPadState?, String?, String?)] = [
            (0, PGPadState(), "before input", "pad-before"),
            (0.5, pad { $0.leftY = 0.8 }, nil, nil),
            (3.5, PGPadState(), "walked forward", "pad-moved"),
            // Weapon wheel: hold L1 and point the right stick at a slot.
            (4.5, pad { $0.padButtons = .l1 }, nil, nil),
            (5.3, pad { $0.padButtons = .l1; $0.rightX = 1 }, "wheel open, pointing right", "pad-wheel"),
            (6.3, PGPadState(), "wheel released", nil),
            (8.0, pad { $0.leftTrigger = 1 }, nil, nil),
            (9.2, pad { $0.leftTrigger = 1 }, "aim held", "pad-aim"),
            (9.4, pad { $0.leftTrigger = 1; $0.rightX = 0.35 }, nil, nil),
            (10.0, pad { $0.leftTrigger = 1; $0.rightTrigger = 1 }, nil, nil),
            (10.6, pad { $0.leftTrigger = 1; $0.rightTrigger = 1 }, "aim and fire", "pad-fire"),
            (11.5, PGPadState(), "released", nil)]
        for (time, state, message, frame) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                if let state { self.padProof = state }
                if let message { log(message) }
                if let frame { PGCaptureNativeFrame(frame) }
            }
        }
    }

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Players' own music (Spotify, Apple Music) keeps playing alongside the game instead of stopping it (GTA-132).
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let source = AVAudioSourceNode(format: format) { _, _, count, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
                PGFillAudio(left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), count)
                // The game's sound waits for the intro video (its ring is still read, so nothing piles up).
                if introPlaying { memset(left, 0, Int(count) * 4); memset(right, 0, Int(count) * 4) }
                return noErr
            }
            audioSource = source
            audioEngine.attach(source)
            audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
            #if targetEnvironment(simulator)
            // Simulator runs are silent unless --sound is passed (test runs play through the Mac's speakers).
            if !ProcessInfo.processInfo.arguments.contains("--sound") { audioEngine.mainMixerNode.outputVolume = 0 }
            #endif
            // Silent test runs on a phone.
            if ProcessInfo.processInfo.arguments.contains("--mute") { audioEngine.mainMixerNode.outputVolume = 0 }
            try audioEngine.start()
            observeAudioInterruptions()
        } catch { appendLog("Native audio setup failed: \(error.localizedDescription)") }
    }

    /// A call, Siri, another app's audio or the app going to the background stops the audio engine,
    /// and iOS doesn't start it again: the game was silent after coming back (log 418). Restarted when
    /// the interruption ends, when the app is active again, and when the route or format changes.
    private func observeAudioInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            self?.appendLog("Audio interruption \(type == .began ? "began" : "ended").")
            if type == .ended { self?.resumeAudio(reason: "interruption ended") }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeAudio(reason: "app active") }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in self?.resumeAudio(reason: "audio configuration changed") }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeAudio(reason: "media services reset") }
    }
    /// Activation fails while a call or Siri still holds the audio ("Session activation failed", logs 666 and
    /// 752), so a failed restart is tried again a few times, 0.5 to 8 s apart, while the app is in front (GTA-132).
    private func resumeAudio(reason: String, attempt: Int = 0) {
        guard audioSource != nil, !audioEngine.isRunning, !audioShutDown else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try audioEngine.start()
            appendLog("Audio restarted (\(reason)\(attempt > 0 ? ", try \(attempt + 1)" : "")).")
        } catch {
            appendLog("Audio could not restart (\(reason)): \(error.localizedDescription)")
            guard attempt < 5, UIApplication.shared.applicationState == .active else { return }
            audioRetry?.cancel()
            let retry = DispatchWorkItem { [weak self] in self?.resumeAudio(reason: reason, attempt: attempt + 1) }
            audioRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(1 << attempt), execute: retry)
        }
    }

    /// The gamepad to play with: the one the player touched last, never the PS VR2 Sense pair
    /// (visionOS lists them as a gamepad too) while another controller is connected.
    static func activeController() -> GCController? {
        let gamepads = GCController.controllers().filter { $0.extendedGamepad != nil }
        // The Sense pair keeps generating events (tracking, drift) and would keep stealing
        // "current"; only fall back to it when nothing else is connected.
        let real = gamepads.filter { !($0.vendorName ?? "").localizedCaseInsensitiveContains("Sense") }
        if real.isEmpty { return gamepads.first }
        if let current = GCController.current, real.contains(where: { $0 === current }) { return current }
        return real.first
    }

    @objc private func controllerChanged() {
        let names = GCController.controllers().map { ($0.vendorName ?? "Gamepad") + ($0.extendedGamepad == nil ? " (no extended gamepad profile)" : "") }
        appendLog("Controllers: " + (names.isEmpty ? "none" : names.joined(separator: ", ")))
        pollController()
    }

    // MARK: Folding (iPhone Duo) and other screen size changes

    #if !targetEnvironment(macCatalyst)
    /// Folding or unfolding the iPhone Duo moves the game to its other screen (outer 678×466 points, inner 951×669;
    /// GTA-185), so the game screen changes size while the game runs. A live back-buffer resize stops some runs on
    /// iPhone (GTA-89), so the picture follows without one: it keeps its render size and fills the new screen when its
    /// shape is within 4% of the one the game started on (the Duo's two screens differ by 2.3%); past that (another
    /// window size) it keeps its shape with bars. The next start renders in the new screen's shape.
    private var phoneGameSize = CGSize.zero, followedSize = CGSize.zero
    private var phoneResize: DispatchWorkItem?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard engineStarted, phoneGameSize != .zero, view.bounds.size != followedSize else { return }
        phoneResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.followScreenSize() }
        phoneResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)   // once the change settles
    }
    private func followScreenSize() {
        let size = view.bounds.size
        guard size != followedSize, size.width > 0, size.height > 0 else { return }
        let before = followedSize
        followedSize = size
        updateDisplayRate()
        let keepShape = abs((size.width / size.height) / (phoneGameSize.width / phoneGameSize.height) - 1) > 0.04
        if tvWindow == nil { metalView.layer.contentsGravity = keepShape ? .resizeAspect : .resize }
        appendLog("Screen: \(Int(size.width))×\(Int(size.height)) points (was \(Int(before.width))×\(Int(before.height))). The picture "
                  + (tvWindow != nil ? "is on the TV." : keepShape ? "keeps its shape with bars until the next start." : "fills it at its render size."))
    }

    /// iOS 27: a display link that moves with the window's scene to the screen it's on (the Duo's inner or outer
    /// screen). A plain CADisplayLink stays on the main screen, and the controls are read on its ticks.
    private weak var displayLinkScene: UIWindowScene?
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        followSceneWithDisplayLink()
    }
    private func followSceneWithDisplayLink() {
        guard #available(iOS 27, *), let scene = view.window?.windowScene, scene !== displayLinkScene else { return }
        var link: CADisplayLink?
        #if compiler(>=6.4)   // the iOS 27 SDK (Xcode 27)
        link = scene.displayLink(target: self, selector: #selector(pollController))
        #else
        // Built with an older SDK (Xcode 26.2, the release toolchain): the same iOS 27 call, looked up by name.
        typealias Make = @convention(c) (AnyObject, Selector, AnyObject, Selector) -> Unmanaged<CADisplayLink>?
        let make = NSSelectorFromString("displayLinkWithTarget:selector:")
        if scene.responds(to: make) {
            link = unsafeBitCast(scene.method(for: make), to: Make.self)(scene, make, self, #selector(pollController))?.takeUnretainedValue()
        }
        #endif
        guard let link else { appendLog("Display link: the scene's could not be made; the main screen's stays."); return }
        displayLink?.invalidate()
        displayLink = link
        displayLinkScene = scene
        updateDisplayRate()
        link.add(to: .main, forMode: .common)
        appendLog("Display link: follows the game's scene to the screen it's on (iOS 27).")
    }
    #endif

    // MARK: TV (AirPlay and HDMI)

    /// With a TV connected (AirPlay screen mirroring or an HDMI adapter), the game picture goes to the TV
    /// during play and the phone keeps the touch controls over black (GTA-3). The TV comes as its own scene
    /// (TVSceneDelegate, GTA-171); before Play the app gives it no window, so it shows the phone's screen.
    private var tvWindow: UIWindow?
    private var phoneGameConstraints: [NSLayoutConstraint] = []
    private func observeExternalDisplays() {
        let center = NotificationCenter.default
        center.addObserver(forName: TVSceneDelegate.changed, object: nil, queue: .main) { [weak self] _ in self?.externalDisplayChanged() }
        center.addObserver(forName: UIScreen.modeDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.externalDisplayChanged() }
        #if !targetEnvironment(macCatalyst)
        registerTVAccessory()
        #endif
    }
    /// A TV's scene can connect, drop and connect again within a moment (the iOS 27 simulator did), and each move of
    /// the picture resizes the game live (risky on iPhone, GTA-89): the picture moves once the TV has settled.
    private var tvSettle: DispatchWorkItem?
    private func externalDisplayChanged() {
        tvSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateExternalDisplay() }
        tvSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    #if !targetEnvironment(macCatalyst)
    /// iOS 27 connects a TV's scene only for a screen that registered it as a scene accessory (UISceneAccessory);
    /// iOS 16 to 26 connect it from Info.plist's scene manifest. Kept for the app's life; the registration is the
    /// UISceneAccessoryRegistration.
    private var tvAccessory: NSObject?
    private func registerTVAccessory() {
        guard tvAccessory == nil, #available(iOS 27, *) else { return }
        let configuration = UISceneConfiguration(name: TVSceneDelegate.configurationName, sessionRole: .windowExternalDisplayNonInteractive)
        #if compiler(>=6.4)   // the iOS 27 SDK (Xcode 27)
        tvAccessory = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        #else
        // Built with an older SDK (Xcode 26.2, the release toolchain): the same iOS 27 calls, looked up by name.
        let make = NSSelectorFromString("externalNonInteractiveSceneAccessoryWithConfiguration:"), register = NSSelectorFromString("registerSceneAccessory:")
        guard let type = NSClassFromString("UISceneAccessory") as? NSObject.Type, type.responds(to: make), responds(to: register),
              let accessory = type.perform(make, with: configuration)?.takeUnretainedValue() else {
            appendLog("TV: iOS 27 without UISceneAccessory; a TV shows the phone's screen.")
            return
        }
        tvAccessory = perform(register, with: accessory)?.takeUnretainedValue() as? NSObject
        #endif
        guard let tvAccessory else { appendLog("TV: the scene accessory could not be registered; a TV shows the phone's screen."); return }
        // Read "available" only if this iOS has it: an unknown key raises and would stop the app at launch.
        let readable = tvAccessory.responds(to: NSSelectorFromString("isAvailable")) || tvAccessory.responds(to: NSSelectorFromString("available"))
        let state = readable ? ((tvAccessory.value(forKey: "available") as? Bool) == true ? "connected" : "not connected") : "unknown"
        appendLog("TV: scene accessory registered (a TV is \(state)).")
    }
    #endif
    private func updateExternalDisplay(resize: Bool = true) {
        var resize = resize
        let scene = engineStarted && !ProcessInfo.processInfo.arguments.contains("--no-tv") ? TVSceneDelegate.scene : nil
        if let scene {
            let tv = scene.screen
            if tvWindow?.windowScene === scene, tvWindow?.bounds == tv.bounds { return }
            // A TV connected again is a new scene: the old one's window goes (the picture keeps its size if the TV's is the same).
            if let old = tvWindow, old.windowScene !== scene {
                if old.bounds == tv.bounds { resize = false }
                old.isHidden = true; old.rootViewController = nil; tvWindow = nil
            }
            let window = tvWindow ?? UIWindow(windowScene: scene)
            window.frame = tv.bounds
            if window.rootViewController == nil {
                let root = UIViewController()
                root.view.backgroundColor = .black
                window.rootViewController = root
            }
            tv.overscanCompensation = .none
            if metalView.superview !== window.rootViewController?.view {
                NSLayoutConstraint.deactivate(phoneGameConstraints)
                metalView.removeFromSuperview()
                let host = window.rootViewController!.view!
                host.addSubview(metalView)
                NSLayoutConstraint.activate([
                    metalView.leadingAnchor.constraint(equalTo: host.leadingAnchor), metalView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    metalView.topAnchor.constraint(equalTo: host.topAnchor), metalView.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
                view.backgroundColor = .black
            }
            window.isHidden = false
            tvWindow = window
            appendLog("TV connected (\(Int(tv.bounds.width * tv.scale))×\(Int(tv.bounds.height * tv.scale))): the game shows on the TV, the controls stay on the phone.")
        } else if let window = tvWindow {
            metalView.removeFromSuperview()
            view.insertSubview(metalView, at: 0)
            NSLayoutConstraint.activate(phoneGameConstraints)
            window.isHidden = true
            tvWindow = nil
            appendLog("TV disconnected: the game is back on the phone.")
        } else { return }
        updateDisplayRate()   // the phone's screen only shows the controls while the game is on the TV
        if resize { applyLiveResolution() }
    }

    // MARK: Game file server

    /// Back in the app (for example after moving the game folder in Files): look again. Checking every
    /// file takes about a second, so it runs off the main thread.
    @objc private func lookForGameFiles() {
        guard !engineStarted, !GameFolder.isChosen || GameFolder.inAppFolder, !lookingForGameFiles, !GameInstallManager.shared.isRunning else { return }
        lookingForGameFiles = true
        if !GameFolder.isChosen { home.setFiles(.busy, title: AppLanguage.choose("Looking for your game files…"), detail: "") }
        DispatchQueue.global(qos: .userInitiated).async {
            GameFolder.findInAppFolder()
            DispatchQueue.main.async {
                self.lookingForGameFiles = false
                self.updateServerStatus()
                self.logStartupStatus()
            }
        }
    }
    private var lookingForGameFiles = false
    private var startupStatusLogged = false
    /// Once per launch: where the game files are and the main settings, so a log sent from the
    /// start screen (without playing) still shows why the game can't start.
    private func logStartupStatus() {
        guard !startupStatusLogged else { return }
        startupStatusLogged = true
        var files: String
        if GameFolder.isChosen {
            files = "\(GameFolder.inAppFolder ? "in the app's folder" : "picked in Files") (\"\(GameFolder.name)\")"
            if GameFolder.acceptedProblemCount > 0 { files += ", \(GameFolder.acceptedProblemCount) problem files, played anyway" }
        } else if let problem = GameFolder.appFolderProblem {
            files = "found but can't be used: " + problem
        } else {
            files = "none found"
        }
        if !GameFolder.archivesFound.isEmpty { files += "; archives: " + GameFolder.archivesFound.map(\.lastPathComponent).joined(separator: ", ") }
        let free = (try? GameFolder.appFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).flatMap { $0 }
        let settings = GameSettings.shared
        appendLog("Startup: game files \(files). Free storage \(free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"). Memory limit \(settings.tier.memoryLimitMB) MB (increased memory limit \(DeviceTier.increasedMemoryGranted.map { $0 ? "granted" : "not granted" } ?? "unknown")). \(settings.gameMode.title), \(settings.graphicsPreset.title).\(GameFolder.insideLiveContainer ? " Inside LiveContainer." : "")")
    }
    @objc private func installChanged() {
        guard !engineStarted else { return }
        updateServerStatus()
        // Finished while the game files screen was closed: say how it went here.
        guard presentedViewController == nil, case let .finished(result) = GameInstallManager.shared.state else { return }
        GameInstallManager.shared.acknowledge()
        switch result {
        case .success: appendLog("Game files installed and checked.")
        case let .failure(message): showWhenFree(title: AppLanguage.choose("Couldn't get the game files"), message: message)
        case .webPage: showGameFiles()
        }
    }
    /// Shows where the game files come from, and whether Play can start.
    private func updateServerStatus(_ status: String? = nil) {
        // A download running in the background shows on the card (tap it for the full progress).
        if case let .running(update) = GameInstallManager.shared.state {
            home.setFiles(.busy, title: update.title, detail: update.detail.split(separator: "\n").first.map(String.init) ?? AppLanguage.choose("Tap to see the progress."))
            updatePlayEnabled()
            return
        }
        // A server address that isn't a web address would boot the game with no files at all.
        let raw = GameSettings.shared.assetServer
        let server = Self.isServerAddress(raw) ? raw : ""
        if GameFolder.isChosen {
            let place = GameFolder.inAppFolder ? AppLanguage.choose("In the GTA V Port folder") : AppLanguage.choose("On this iPhone")
            let problems = GameFolder.acceptedProblemCount
            home.setFiles(problems > 0 ? .attention : .ready, title: "\"\(GameFolder.name)\"",
                          detail: problems > 0
                            ? AppLanguage.interpolate(problems == 1 ? AppLanguage.choose("{arg0} · 1 problem file, playing anyway") : AppLanguage.choose("{arg0} · {arg1} problem files, playing anyway"), [place, String(problems)])
                            : AppLanguage.interpolate(AppLanguage.choose("{arg0} · every file checked"), [place]))
        } else if server.isEmpty, let report = GameFolder.appFolderReport {
            home.setFiles(.problem, title: report.explanation.title, detail: AppLanguage.choose("Found your game folder, but it can't be used yet. Tap to see why and how to fix it."))
        } else if server.isEmpty, !raw.isEmpty {
            home.setFiles(.problem, title: AppLanguage.choose("Server address isn't a web address"), detail: AppLanguage.choose("Tap to change it."))
        } else if server.isEmpty {
            home.setFiles(.attention, title: AppLanguage.choose("Add your game files"), detail: GameFolder.archivesFound.isEmpty ? AppLanguage.choose("Tap to find them on this iPhone, or get them from a link or an archive.") : AppLanguage.choose("Found a game archive. Tap to unpack it."))
        } else if status == AppLanguage.choose("checking…") {
            home.setFiles(.busy, title: AppLanguage.choose("Streaming from your server"), detail: server)
        } else {
            let ok = status == nil || status == AppLanguage.choose("connected ✓")
            home.setFiles(ok ? .ready : .problem, title: AppLanguage.choose("Streaming from your server"), detail: server + (status.map { " · " + $0 } ?? ""))
        }
        updatePlayEnabled()
    }
    /// Play needs game files and a chosen mode.
    private func updatePlayEnabled() {
        let server = Self.isServerAddress(GameSettings.shared.assetServer)
        launchButton.isEnabled = !engineStarted && !GameInstallManager.shared.isRunning && (GameFolder.isChosen || server) && GameSettings.shared.gameModeChoice != nil
    }
    static func isServerAddress(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return (scheme == "http" || scheme == "https") && !host.isEmpty
    }
    /// The game files screen: checking, finding, downloading and unpacking.
    /// A script mod opened the game's on-screen keyboard: the Mod keys keyboard takes the text.
    private func checkModTextRequest() {
        var title = [CChar](repeating: 0, count: 160), text = [CChar](repeating: 0, count: 1024), maxLength: Int32 = 0
        guard PGAsiTextRequest(&title, title.count, &text, text.count, &maxLength) else { return }
        modKeys.startTextRequest(title: String(cString: title), text: String(cString: text), maxLength: Int(maxLength))
        appendLog("Mods: a script asks for text: \(String(cString: title))")
        #if targetEnvironment(simulator)
        // Test: PG_TEST_TEXT_ANSWER types an answer and presses Done after a few seconds (screenshots first).
        if let answer = ProcessInfo.processInfo.environment["PG_TEST_TEXT_ANSWER"] {
            appendLog("TEST: text box shown: \(String(cString: title))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.modKeys.testAnswer(answer) }
        }
        #endif
    }

    /// Simulator test: --install-mod <file> (repeatable) runs the in-app installer on each file before the
    /// game starts, as if picked in Settings › Mods, and logs what it did.
    private func installModsForTest() {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        for (i, arg) in args.enumerated() where arg == "--install-mod" && i + 1 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            do {
                let folder = try ModInstaller.unpack(file)
                let plan = ModInstaller.plan(folder: folder, name: file.lastPathComponent, index: .load(manifest: EnginePaths.manifest))
                try ModInstaller.install(plan)
                appendLog("TEST: installed mod \(plan.name)\(plan.unsupported ? " (unsupported)" : ""): \(plan.items.map { $0.target }.joined(separator: ", ")); skipped \(plan.skipped.map { $0.file + " (" + $0.reason + ")" }.joined(separator: ", "))")
                try? FileManager.default.removeItem(at: folder)
            } catch { appendLog("TEST: mod install failed for \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        #endif
    }

    /// Mods (GTA-69): once per set of mod files, says that mods can break things and where mod help is.
    private func noticeMods() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Mods")
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        ModInstaller.placeWaitingFiles()
        // Switched-off mods (folders ending in .off) and files still waiting to be placed don't count.
        // The signature must be the same on every launch (Swift's hashValue isn't), so it's FNV-1a.
        var count = 0, signature: UInt64 = 14695981039346656037
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if name.hasSuffix(".off") || name == ".pending" { walk.skipDescendants(); continue }
            guard name != "README.txt", !name.hasPrefix(".") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            count += 1
            // Relative to the Mods folder: the app's own folder path changes with every app update.
            for byte in url.path.replacingOccurrences(of: folder.path, with: "").utf8 { signature = (signature ^ UInt64(byte)) &* 1099511628211 }
            signature = (signature ^ UInt64(values?.fileSize ?? 0)) &* 1099511628211
        }
        guard count > 0 else { return }
        appendLog("Mods folder: \(count) file\(count == 1 ? "" : "s").")
        let key = "modsNoticeSignature", value = "\(count)-\(signature)"
        guard UserDefaults.standard.string(forKey: key) != value else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PG_TEST_NO_MODS_NOTICE"] != nil { return }
        #endif
        UserDefaults.standard.set(value, forKey: key)
        showWhenFree(title: AppLanguage.choose("Mods are on"),
                     message: AppLanguage.interpolate(AppLanguage.choose("{arg0} mod files are active. Mods can cause crashes and glitches that we can't fix: ask about them in the Mods topic on Telegram. Send logs only for problems that also happen without mods."), [String(count)]))
    }

    /// Low memory (GTA-148): once, on a device where iOS gives the game less than the city needs (the limit that
    /// recommends Ultra Performance), says what to expect there and that more memory is what helps.
    private func noticeLowMemory() {
        #if !targetEnvironment(macCatalyst)
        let limit = GameSettings.shared.tier.memoryLimitMB, key = "lowMemoryNoticeShown"
        guard lowMemoryDevice, !UserDefaults.standard.bool(forKey: key) else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PG_TEST_NO_MODS_NOTICE"] != nil { return }   // the harness: no notices
        #endif
        UserDefaults.standard.set(true, forKey: key)
        var message = AppLanguage.interpolate(AppLanguage.choose("iOS gives the game only about {arg0} MB on this device, less than the city needs. Expect a less detailed city and textures that load late or stay missing. That's normal here, so there's no need to report it."), [String(limit)])
        if DeviceTier.increasedMemoryGranted != true {
            message += AppLanguage.choose("\n\nMore memory helps the most: install the app with AltStore 2.3 or newer, which adds extra memory on a free Apple ID.")
        }
        message += AppLanguage.choose("\n\nThe red triangle next to the FPS counter marks a phone with this little memory.")
        appendLog("Low memory notice shown (app limit \(limit) MB).")
        showWhenFree(title: AppLanguage.choose("Low memory on this device"), message: message)
        #endif
    }

    private func showGameFiles() {
        guard !engineStarted, presentedViewController == nil else { return }
        let controller = GameFilesViewController()
        controller.serverProblem = GameFolder.isChosen || serverAnswered != false || serverProblem.isEmpty ? nil : serverProblem
        controller.onChange = { [weak self] in self?.updateServerStatus() }
        controller.onServer = { [weak self] server in
            GameFolder.clear()
            GameSettings.shared.assetServer = server
            self?.appendLog("Game files: streaming from \(server)")
            self?.testAssetServer()
        }
        let navigation = UINavigationController(rootViewController: controller)
        Theme.styleNavigation(navigation)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }
    /// "Restart now?" in the game's own pause menu (Settings › Graphics there) froze the game: the port can't restart
    /// it (GTA-166). The engine now logs the graphics the player chose that the app passes at launch
    /// (EngineHost.c, pg_settings_restart: "Pause menu graphics for the next start (GTA-166): textureQuality=2 ...").
    /// They become the player's own details in Settings › Graphics (a value equal to the preset's follows the preset
    /// again) and apply the next time the game starts.
    private func keepPauseMenuGraphics(_ line: String) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let preset = GameSettings.shared.graphicsPreset
        var overrides = GameSettings.shared.graphicsOverrides
        var kept: [String] = []
        for pair in line[line.index(after: colon)...].split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let option = preset.engineOptions.first(where: { $0.hasPrefix("-\(parts[0])=") }) else { continue }
            let presetValue = String(option.dropFirst(parts[0].count + 2))
            overrides[parts[0]] = Double(parts[1]) == Double(presetValue) ? nil : parts[1]
            kept.append(pair.description)
        }
        GameSettings.shared.graphicsOverrides = overrides
        appendLog("Graphics: the pause menu asked to restart the game; " + (kept.isEmpty ? "nothing the app sets changed." : "kept for the next start: " + kept.joined(separator: ", ") + "."))
        showWhenFree(title: AppLanguage.choose("Graphics"), message: kept.isEmpty
            ? AppLanguage.choose("The game can't restart itself here, and this change has no effect on this device. Set the graphics in Settings › Graphics.")
            : AppLanguage.choose("The game can't restart itself here, so these changes apply the next time you start the game. They're saved in Settings › Graphics."))
    }
    /// Shows a message once nothing else (like the closing folder picker) is on screen; iOS drops
    /// alerts presented during another presentation.
    private func showWhenFree(title: String, message: String, attempt: Int = 0) {
        if (presentedViewController != nil || transitionCoordinator != nil) && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showWhenFree(title: title, message: message, attempt: attempt + 1) }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("OK"), style: .default))
        present(alert, animated: true)
    }
    /// The server answered with the game's file list (nil: not checked yet).
    private var serverAnswered: Bool?
    private var serverProblem = ""
    /// Checks that the server answers with the game's file list.
    private func testAssetServer(then done: ((Bool) -> Void)? = nil) {
        var server = GameSettings.shared.assetServer
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: server + "/data/manifest.json"), url.scheme?.hasPrefix("http") == true else {
            serverAnswered = false; serverProblem = "not a valid address"
            updateServerStatus(AppLanguage.choose("not a valid address")); done?(false); return
        }
        serverAnswered = nil
        updateServerStatus(AppLanguage.choose("checking…"))
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.serverAnswered = code == 200
                self.serverProblem = code == 200 ? "" : error?.localizedDescription ?? "HTTP \(code)"
                if code == 200 { self.updateServerStatus(AppLanguage.choose("connected ✓")) }
                else if let error { self.updateServerStatus(AppLanguage.interpolate(AppLanguage.choose("can't connect ({arg0})"), [error.localizedDescription])) }
                else { self.updateServerStatus(AppLanguage.interpolate(AppLanguage.choose("answered {arg0}; is the address the folder with data/ and b/?"), [String(code)])) }
                done?(code == 200)
            }
        }.resume()
    }
    private func recoverGraphicsAfterFailedBoot() {
        guard let recovery = GameSettings.shared.recoverFromFailedBoot() else { return }
        appendLog("Previous launch on \(recovery.failed.title) did not finish; lowered to \(recovery.fallback.title)\(recovery.resetHeight.map { ", resolution \($0)p back to Auto" } ?? "").")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.explainRecovery(recovery) }
    }
    /// The previous start had mods on and didn't finish (GTA-153): start once without them, or keep them.
    private func offerStartWithoutMods() {
        let alert = UIAlertController(title: AppLanguage.choose("The game stopped while starting"),
                                      message: AppLanguage.choose("Your mods were on. A broken or unsupported mod is the most common reason a start fails. Start without mods this time? They stay installed, and the next start uses them again."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Start without mods"), style: .default) { _ in
            ModGuard.withoutModsNextStart = true
            GameSettings.shared.markBootInterrupted()   // the mods get the blame, not the graphics settings
            self.appendLog("Chose to start without mods.")
            self.launchButton.setNeedsUpdateConfiguration()
        })
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Keep my mods"), style: .cancel) { _ in
            self.appendLog("Kept the mods after the failed start.")
            self.recoverGraphicsAfterFailedBoot()
        })
        present(alert, animated: true)
    }
    /// After an update: the mods switched off because the previous version didn't use them (GTA-153).
    private func explainModsSwitchedOff(_ names: [String]) {
        let list = names.prefix(10).map { "• " + $0 }.joined(separator: "\n") + (names.count > 10 ? "\n" + AppLanguage.interpolate(AppLanguage.choose("…and {arg0} more"), [String(names.count - 10)]) : "")
        showWhenFree(title: AppLanguage.choose("Some mods are off after the update"),
                     message: AppLanguage.choose("This version handles mods differently. The previous version didn't load these, so they could act differently now. They're off until you turn them on in Settings › Mods:") + "\n\n" + list)
    }
    /// The popup after a launch that ran out of memory: what happened, what changed, and the way back.
    private func explainRecovery(_ recovery: GameSettings.BootRecovery) {
        let lowered = recovery.fallback != recovery.failed
        let title = lowered ? AppLanguage.interpolate(AppLanguage.choose("Graphics lowered to {arg0}"), [recovery.fallback.title]) : AppLanguage.choose("Resolution set back to Auto")
        var message = AppLanguage.interpolate(AppLanguage.choose("The game closed while starting on {arg0}"), [recovery.failed.title])
        if let height = recovery.resetHeight { message += AppLanguage.interpolate(AppLanguage.choose(" at {arg0}p"), [String(height)]) }
        message += AppLanguage.interpolate(AppLanguage.choose(". That usually means this setting needs more memory than iOS gives the app on this iPhone (about {arg0} MB)."), [String(recovery.memoryLimitMB)])
        message += lowered ? AppLanguage.interpolate(AppLanguage.choose("\n\nThe game now starts on {arg0}"), [recovery.fallback.title]) : AppLanguage.choose("\n\nThe game now starts at its usual resolution")
        message += recovery.resetHeight != nil && lowered ? AppLanguage.choose(" with Auto resolution.") : "."
        message += AppLanguage.choose(" You can change this any time in Settings.")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("OK"), style: .cancel))
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Share log"), style: .default) { _ in
            let logs = RunEnd.reportLogs().map(\.url)
            let sheet = UIActivityViewController(activityItems: logs, applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.view
            self.present(sheet, animated: true)
        })
        alert.addAction(UIAlertAction(title: AppLanguage.interpolate(AppLanguage.choose("Try {arg0} again"), [recovery.failed.title]), style: .destructive) { _ in
            GameSettings.shared.undoRecovery(recovery)
            self.appendLog("Kept \(recovery.failed.title) after the warning.")
        })
        present(alert, animated: true)
    }

    private var healthLines = 0
    private var lastStoryMission = "", lastReplayState: Int32 = -1
    private func logHealth() {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS
        var used = ok ? Int(vm.phys_footprint / 1_048_576) : -1
        #if targetEnvironment(simulator)
        if used >= 0 { used += Int(PGGPUTextureBytes() / 1_048_576) }   // counted as an iPhone counts it (see EngineHost.c)
        #endif
        let available = Int(PGProcessAvailableMemory() / 1_048_576)
        let free = available > 0 ? available : max(0, GameSettings.shared.tier.memoryLimitMB - used)
        healthLines += 1
        // An interruption that never ends (another app's audio, logs 700 and 613) leaves the game silent while it plays on (GTA-132).
        // Not while another app still plays: the player's own music would be cut off every 10 s.
        if !audioEngine.isRunning, UIApplication.shared.applicationState == .active, !AVAudioSession.sharedInstance().isOtherAudioPlaying {
            resumeAudio(reason: "silent while playing")
        }
        if healthLines % 6 == 1 { PGLogMemoryPools() }   // where the memory is, once a minute
        // What the footprint is made of, every 30 s (GTA-217). Walking the app's memory takes a few ms: off the main thread.
        if healthLines % 3 == 1 { DispatchQueue.global(qos: .utility).async { PGLogMemoryBreakdown("30 s") } }
        var reads = [UInt64](repeating: 0, count: 6)
        reads.withUnsafeMutableBufferPointer { PGAssetHealth($0.baseAddress) }
        let now = [PGMemoryBudgetClamps()] + reads + [PGMemoryBudgetEvictions()]
        // What players see of streaming (GTA-116): requests still waiting, how long loads took, what was unloaded.
        var stream = [UInt64](repeating: 0, count: 6)
        stream.withUnsafeMutableBufferPointer { PGStreamingHealth($0.baseAddress) }
        let gpuMS = PGGPUFrameMilliseconds()
        let d = zip(now, lastHealth).map { $0 &- $1 }
        lastHealth = now
        let avgMS = d[1] > 0 ? Double(d[6]) / Double(d[1]) / 1000 : 0
        // iOS slows the chip down as the phone heats up; the same frames then take longer.
        let thermal = ["nominal", "fair", "serious", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]
        // CPU time the whole app used, in cores, since the last line (what heats the phone).
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let wall = CACurrentMediaTime()
        let cores = lastCPU.map { (cpu - $0.cpu) / max(0.001, wall - $0.wall) } ?? 0
        lastCPU = (cpu, wall)
        // Which mission and where (GTA-106), so a report can be replayed at the same moment in the simulator.
        var name = [CChar](repeating: 0, count: 64), position: (Float, Float, Float) = (0, 0, 0), replay: Int32 = -1
        let story = withUnsafeMutablePointer(to: &position) { $0.withMemoryRebound(to: Float.self, capacity: 3) { PGStoryContext(&name, name.count, $0, &replay) } }
        if story {
            let mission = String(cString: name)
            if mission != lastStoryMission { lastStoryMission = mission; appendLog("Story: \(mission.isEmpty ? "no mission running" : "mission \(mission) running")") }
            if replay != lastReplayState { if replay == 1 { appendLog("Story: Mission failed screen") }; lastReplayState = replay }
        }
        playStats.health(fps: Double(PGRenderedFramesPerSecond()), thermal: ProcessInfo.processInfo.thermalState.rawValue, mission: story ? String(cString: name) : nil, failedScreen: replay == 1,
                         controller: GCController.controllers().contains { $0.extendedGamepad != nil })
        appendLog(String(format: "Health: memory %d MB used, %d MB free · guard stopped streaming growth %llu×, asked to evict %llu× · reads %llu (%.1f MB, avg %.1f ms, slow %llu, errors %llu) · %.0f FPS · thermal %@ · CPU %.2f cores · GPU %.1f ms · streaming %llu waiting (%llu over 10 s), loaded %llu (median %llu ms, 95%% %llu ms), unloaded %llu · at %.0f, %.0f, %.0f",
                         used, free, d[0], d[7], d[1], Double(d[2]) / 1_048_576, avgMS, d[5], d[3], PGRenderedFramesPerSecond(), thermal, cores, gpuMS, stream[0], stream[1], stream[2], stream[3], stream[4], stream[5], position.0, position.1, position.2))
        // Which threads use those cores (GTA-162): the heat question per part of the game, not just in total.
        var threads = [CChar](repeating: 0, count: 600)
        if PGThreadCPU(&threads, threads.count) > 0 { appendLog(String(cString: threads)) }
        logDisplay()
    }

    @objc private func leftApp() {
        // Once per time away: with scenes (GTA-171) a Mac app that quits goes to the background first and then
        // terminates, and a second session end would add an empty session to the play stats.
        guard !leftAppHandled else { return }
        leftAppHandled = true
        RunEnd.playing(false)
        if stableTimer?.isValid != false { GameSettings.shared.markBootInterrupted() }
        playStats.sessionEnded()
    }

    /// The touch-controls layout editor (pre-game, or from Settings).
    private func showLayoutEditor() {
        let editor = ControlsLayoutEditorController()
        editor.modalPresentationStyle = .fullScreen
        editor.onDone = { [weak self] in
            self?.touchControls.updateVisibility()
            self?.appendLog("Controls layout saved (\(ControlsLayout.entries.count) customized controls).")
        }
        (presentedViewController ?? self).present(editor, animated: true)
    }
    @objc private func languageChanged() {
        // The 1.3 home and its new widgets own their own labels.
        home.refreshLanguage()
        touchControls.refreshLanguage()
        refreshModeChoice()
        updateServerStatus()
        launchButton.setNeedsUpdateConfiguration()
        if !engineStarted { controllerLabel.text = AppLanguage.choose("Controller: none connected") }
    }

    private var stoppedPanel: UIView?
    private var stopEvidence: [String] = []
    private weak var stopFixButton: UIButton?
    /// Shown once the engine has stopped: what happened, Send log and Settings, above everything. For a known cause
    /// (StopCause, GTA-178) it says which and what to do, and offers to switch off the mod behind it.
    private func showEngineStopped(title titleText: String? = nil, message: String? = nil) {
        guard stoppedPanel == nil else { return }
        touchControls.reset(publish: false)
        touchControls.isHidden = true
        PGUpdateVirtualPad(PGPadState())
        let modsOn = !ModGuard.startsWithoutMods && ModGuard.anyModsOn
        let cause = titleText == nil ? StopCause.find(stopEvidence, addonsOn: modsOn) : nil
        let suspects = cause.map { ModFiles.mods(for: $0) } ?? []
        if let cause {
            appendLog("Stop cause: \(cause.kind.rawValue)" + (cause.file.isEmpty ? "" : " file \(cause.file)") + (cause.pack.isEmpty ? "" : " pack \(cause.pack)")
                      + (suspects.isEmpty ? "" : " mods " + suspects.map(\.name).joined(separator: ", ")))
        }
        let title = UILabel()
        title.text = titleText ?? cause?.title ?? AppLanguage.choose("The game stopped")
        title.font = Theme.display(22, .heavy)
        title.textColor = .white
        title.numberOfLines = 0
        title.textAlignment = .center
        let info = UILabel()
        info.text = message ?? cause.map { $0.message(mods: suspects.map(\.name)) }
            ?? AppLanguage.choose("Please send the log so this can be fixed, then close the app and open it again to keep playing.")
        info.numberOfLines = 0
        info.textAlignment = .center
        info.font = .preferredFont(forTextStyle: .subheadline)
        info.textColor = UIColor(white: 1, alpha: 0.8)
        var sendStyle = UIButton.Configuration.filled()
        sendStyle.title = AppLanguage.choose("Send log to the developer")
        sendStyle.cornerStyle = .large
        let send = UIButton(configuration: sendStyle, primaryAction: UIAction { [weak self] _ in self?.sendLogAfterStop() })
        var settingsStyle = UIButton.Configuration.gray()
        settingsStyle.title = AppLanguage.choose("Settings")
        settingsStyle.cornerStyle = .large
        settingsStyle.baseForegroundColor = .white	// the dark panel made the default label nearly invisible
        settingsStyle.baseBackgroundColor = UIColor(white: 1, alpha: 0.18)
        let settings = UIButton(configuration: settingsStyle, primaryAction: UIAction { [weak self] _ in self?.showSettings() })
        var buttons = [send, settings]
        // The mod behind it: switched off for the next start (the game is still running its files now).
        if let cause, cause.fromMods || !suspects.isEmpty, modsOn {
            var style = UIButton.Configuration.filled()
            style.baseBackgroundColor = .systemOrange
            style.cornerStyle = .large
            let one = suspects.count == 1 ? suspects.first : nil
            style.title = one.map { AppLanguage.interpolate(AppLanguage.choose("Switch off \"{arg0}\""), [$0.name]) } ?? AppLanguage.choose("Start without mods next time")
            let fix = UIButton(configuration: style)
            fix.addAction(UIAction { [weak self, weak fix] _ in
                if let one { try? ModInstaller.setEnabled(one, false) } else { ModGuard.withoutModsNextStart = true }
                // Done: a plain, readable label (a disabled button's text is too faint on the dark panel).
                var done = UIButton.Configuration.plain()
                done.title = one != nil ? AppLanguage.choose("Switched off: open the app again to play")
                    : AppLanguage.choose("The next start is without mods: open the app again")
                done.baseForegroundColor = .systemOrange
                done.image = UIImage(systemName: "checkmark.circle.fill")
                done.imagePadding = 6
                fix?.configuration = done
                fix?.isUserInteractionEnabled = false
                self?.appendLog(one.map { "Stop panel: \($0.name) switched off for the next start." } ?? "Stop panel: the next start is without mods.")
            }, for: .primaryActionTriggered)
            buttons.insert(fix, at: 0)
            stopFixButton = fix
        }
        let stack = UIStackView(arrangedSubviews: [title, info] + buttons)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let panel = UIView()
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        panel.layer.cornerRadius = 18
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 380),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        stoppedPanel = panel
        appendLog("The engine stopped: showing Send log and Settings.")
        #if targetEnvironment(simulator)
        // Test: --send-log-after-stop opens the Send log screen from the panel.
        if ProcessInfo.processInfo.arguments.contains("--send-log-after-stop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sendLogAfterStop() }
        }
        #endif
    }
    private func sendLogAfterStop() {
        guard presentedViewController == nil else { return }
        let screen = SendLogViewController()
        screen.finished = { [weak self] title, message in
            self?.present(LogUploader.resultAlert(title, message), animated: true)
        }
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
        appendLog("Send log opened after the engine stopped.")
    }

    /// The Mac menu bar's Settings… (⌘,), AppDelegate.buildMenu.
    @objc func openSettingsFromMenu() { showSettings() }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        touchControls.reset()
        controllerPad.reset()
        pauseGame(reason: "Settings opened during play")
        let controller = SettingsHomeViewController(engineRunning: engineStarted, runningMode: bootedMode)
        controller.gameModeChanged = { [weak self] in self?.refreshModeChoice() }
        controller.resolutionChanged = { [weak self] in
            guard let self else { return }
            if SettingsViewController.liveResolution { self.applyLiveResolution() }
            else if self.engineStarted { self.appendLog("Graphics: resolution changed in Settings during play; it applies the next time the game starts (GTA-89).") }
        }
        controller.controlsChanged = { [weak self] in self?.touchControls.updateVisibility(); self?.placeFPSLabel() }
        controller.editLayout = { [weak self] in self?.showLayoutEditor() }
        controller.targetingChanged = { PGSetTargetingMode(Int32(GameSettings.shared.targetingMode)) }
        controller.cheatSelected = { [weak self] cheat in self?.playStoryCheat(cheat) }
        controller.nativeCheatSelected = { [weak self] action in self?.performNativeCheat(action) }
        controller.vehicleSelected = { [weak self] vehicle, enter in self?.spawnVehicle(vehicle, enter: enter) }
        controller.moneyEntered = { [weak self] amount in
            self?.appendLog("Story cheat: set money to \(amount)")
            PGSetPlayerCash(amount)
        }
        let navigation = UINavigationController(rootViewController: controller)
        Theme.styleNavigation(navigation)
        present(navigation, animated: true)
    }
    /// Cheats › Spawn vehicle: the game thread spawns it once play resumes (NativeVehicleSpawn.inc).
    private func spawnVehicle(_ vehicle: SpawnVehicle, enter: Bool) {
        guard PGSpawnVehicle(vehicle.model, enter) else {
            showWhenFree(title: AppLanguage.choose("Spawn vehicle"), message: AppLanguage.choose("A vehicle is already loading. Wait for it to finish."))
            return
        }
        appendLog("Vehicle menu: requested \(vehicle.name) (enter: \(enter)).")
        monitorMenuAction(title: vehicle.title) {
            switch PGGetVehicleSpawnStatus() {
            case PGVehicleSpawnWaiting, PGVehicleSpawnLoading: return nil
            case PGVehicleSpawnSucceeded: return AppLanguage.interpolate(AppLanguage.choose("Vehicle spawned: {arg0}"), [vehicle.title])
            case PGVehicleSpawnUnavailable: return AppLanguage.choose("This vehicle isn't available in your game.")
            case PGVehicleSpawnTimedOut: return AppLanguage.choose("Loading the vehicle took too long. Try again in an open area.")
            case PGVehicleSpawnLowMemory: return AppLanguage.choose("Not enough free memory to spawn it safely. Go somewhere quieter, or restart with a lower graphics preset.")
            case PGVehicleSpawnVehicleLimit: return AppLanguage.choose("Both menu vehicles are in use. Leave one empty, then try again.")
            case PGVehicleSpawnNotReady: return AppLanguage.choose("Return to normal gameplay before spawning a vehicle.")
            default: return AppLanguage.choose("The game couldn't create this vehicle here.")
            }
        }
    }
    /// Cheats › repair, clean, time or weather: the game thread runs it once play resumes (NativeCheats.inc).
    private func performNativeCheat(_ action: NativeCheatAction) {
        guard PGQueueCheat(action.command, action.value) else {
            showWhenFree(title: AppLanguage.choose("Cheats"), message: AppLanguage.choose("A cheat is already pending. Wait for it to finish."))
            return
        }
        appendLog("Cheats: requested \(action.title).")
        let title = AppLanguage.choose(action.title)
        monitorMenuAction(title: title) {
            switch PGGetCheatStatus() {
            case PGCheatWaiting: return nil
            case PGCheatSucceeded: return AppLanguage.interpolate(AppLanguage.choose("Done: {arg0}"), [title])
            case PGCheatNoVehicle: return AppLanguage.choose("Get into a vehicle first.")
            default: return AppLanguage.choose("Return to normal gameplay before using this cheat.")
            }
        }
    }
    /// Leaves the pause menu Settings opened, then shows a note at the top until `result` has an answer
    /// (checked four times a second), and that answer for 5 s.
    private func monitorMenuAction(title: String, result: @escaping () -> String?) {
        touchControls.reset()
        if PGPauseMenuActive() { PGRequestPauseMenu() }
        vehicleSpawnTimer?.invalidate()
        vehicleSpawnNotice?.removeFromSuperview()
        let notice = UIView()
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.backgroundColor = Theme.night.withAlphaComponent(0.85)
        notice.layer.cornerRadius = 12
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Theme.text
        label.font = Theme.body(16, .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = AppLanguage.interpolate(AppLanguage.choose("{arg0}: waiting for the game…"), [title])
        notice.addSubview(label)
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: notice.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -12),
            notice.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            notice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            notice.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -120),
            notice.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        vehicleSpawnNotice = notice
        let started = Date()
        vehicleSpawnTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak notice, weak label] timer in
            // The game answers within 40 s (10 s to resume play, 30 s to load a vehicle); if it never
            // does, the note shouldn't stay up forever.
            let answer = result() ?? (Date().timeIntervalSince(started) > 60
                ? AppLanguage.choose("The game didn't respond. Return to normal gameplay and try again.") : nil)
            guard let message = answer else { return }
            timer.invalidate()
            self?.vehicleSpawnTimer = nil
            label?.text = message
            UIAccessibility.post(notification: .announcement, argument: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak notice] in notice?.removeFromSuperview() }
        }
    }
    /// The engine follows back-buffer size changes while running.
    private func applyLiveResolution() {
        guard engineStarted else { return }
        let settings = GameSettings.shared
        // On a TV the picture takes the TV's shape.
        let surface = tvWindow?.bounds.size ?? view.bounds.size
        let (width, height) = GraphicsConfiguration.size(for: bootedPreset, renderHeight: settings.renderHeight, screen: surface, matchScreenShape: tvWindow != nil || settings.matchScreenShape)
        PGSetBackBufferSize(Int32(width), Int32(height))
        appendLog("Graphics: live resize to \(width)×\(height)")
        #if !targetEnvironment(macCatalyst)
        // Back on the phone (a TV went away): the picture has the phone screen's shape again.
        if tvWindow == nil { phoneGameSize = view.bounds.size; followedSize = phoneGameSize; metalView.layer.contentsGravity = .resize }
        #endif
    }
    @objc private func releaseTouchControls() {
        touchControls.reset(publish: false)
        gyro.setRunning(false, orientation: .landscapeRight)
        lastControllerPoll = nil
        #if targetEnvironment(simulator)
        simulatorKeys.removeAll()
        #endif
        KeyboardMouse.shared.releaseAll()
        PGUpdateVirtualPad(PGPadState())
        pauseGame(reason: "App inactive during play")
    }
    /// Control Center, a notification, a call or another app: the game opens its own pause menu, so
    /// nothing happens while the player is away and it stays paused until they resume (GitHub #11).
    /// Only during normal play: not in a cutscene, the pause menu, with the phone out or during a cheat.
    /// Also when the player opens Settings during play.
    private func pauseGame(reason: String) {
        guard engineStarted, padProof == nil, !PGPauseMenuActive(), PGGameStatus() & (1 | 2 | 4 | 8 | 16) == 0 else { return }
        appendLog("\(reason): opening the pause menu.")
        // Held by the engine itself for its next frames: the engine may not run a frame until the app is back.
        PGRequestPauseMenu()
    }
    private var injectedKey = false, releasedKey = false, injectedMouse = false
    private var touchSprintTesting = false
    private var controllerTriggerPeak: (Float, Float) = (0, 0)
    private var controllerTriggerLoggedAt: CFTimeInterval = 0
    private func injectTestInput(sinceWorld: Double) {
        let arguments = ProcessInfo.processInfo.arguments
        #if targetEnvironment(simulator)
        // --test-touch-sprint <after> <seconds>: Sprint through the touch controls (GTA-46).
        if let i = arguments.firstIndex(of: "--test-touch-sprint"), i + 2 < arguments.count,
           let after = Double(arguments[i + 1]), let hold = Double(arguments[i + 2]) {
            let on = sinceWorld > after && sinceWorld < after + hold
            if on != touchSprintTesting { touchSprintTesting = on; touchControls.testSprint(on); appendLog("Test: touch sprint \(on ? "on" : "off")") }
        }
        #endif
        #if targetEnvironment(simulator)
        // --test-pause-at <seconds>: opens the pause menu the way leaving the app does (Start for 3 engine frames).
        if let i = arguments.firstIndex(of: "--test-pause-at"), i + 1 < arguments.count, let at = Double(arguments[i + 1]),
           !testPauseDone, sinceWorld > at {
            testPauseDone = true; PGRequestPauseMenu(); appendLog("Test: pause menu requested")
        }
        #endif
        if let i = arguments.firstIndex(of: "--inject-key"), i + 3 < arguments.count,
           let key = UInt8(arguments[i + 1], radix: 16), let after = Double(arguments[i + 2]), let hold = Double(arguments[i + 3]) {
            if !injectedKey && sinceWorld > after { injectedKey = true; KeyboardMouse.shared.inject(key: key, down: true); appendLog("Test: key 0x\(arguments[i + 1]) down") }
            if injectedKey && !releasedKey && sinceWorld > after + hold { releasedKey = true; KeyboardMouse.shared.inject(key: key, down: false); appendLog("Test: key 0x\(arguments[i + 1]) up") }
        }
        if let i = arguments.firstIndex(of: "--inject-mouse"), i + 3 < arguments.count,
           let dx = Double(arguments[i + 1]), let dy = Double(arguments[i + 2]), let after = Double(arguments[i + 3]),
           !injectedMouse, sinceWorld > after {
            injectedMouse = true
            KeyboardMouse.shared.inject(dx: dx, dy: dy)
            appendLog("Test: mouse moved \(dx), \(dy)")
        }
    }
    @objc private func pollController() {
        #if targetEnvironment(macCatalyst)
        MacCursor.capture(macPlaying)
        updateMacPauseBar()
        #endif
        guard UIApplication.shared.applicationState == .active else {
            touchControls.reset(publish: false)
            lastControllerPoll = nil
            PGUpdateVirtualPad(PGPadState())
            PGSetMouseFocus(false, false)
            controllerFeedback.update(controller: Self.activeController(), engineStarted: engineStarted, active: false, leftPull: 0, rightPull: 0)
            wasMouseSwipeActive = false
            inputTestLabel.isHidden = true
            return
        }
        let now = CACurrentMediaTime()
        if let link = displayLink, link.targetTimestamp > link.timestamp { displayLinkCalls += 1; displayLinkHz = 1 / (link.targetTimestamp - link.timestamp) }
        if now - lastFPSLabelUpdate >= 0.25 {
            if touchControlsAvailable { fpsLabel.isHidden = !GameSettings.shared.showFPS }
            let fps = PGRenderedFramesPerSecond()
            var text = fps > 0 ? String(format: "%.0f FPS", fps) : "— FPS"
            // With heat and power (GTA-216): CPU watts, busy cores and the thermal state, refreshed once a second.
            if GameSettings.shared.showPower || ProcessInfo.processInfo.environment["PG_PERF_OVERLAY"] == "1" {
                if now - lastPowerSample >= 1 {
                    var watts = 0.0, cores = 0.0, pShare = 0.0
                    if PGPerfOverlaySample(&watts, &cores, &pShare) != 0 {
                        let heat = ["nominal", "fair", "serious", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]
                        powerText = String(format: " · %.1f W · %.1f cores · ", watts, cores) + heat
                    }
                    lastPowerSample = now
                }
                text += powerText
            }
            // Room for the longer text (the counter is 68 points wide for the frame rate alone).
            let width: CGFloat = powerText.isEmpty || text.count < 12 ? (lowMemoryDevice ? 84 : 68) : (lowMemoryDevice ? 250 : 234)
            if let constraint = fpsLabel.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil }), constraint.constant != width { constraint.constant = width }
            if lowMemoryDevice {
                let line = NSMutableAttributedString(attributedString: lowMemoryMark)
                line.append(NSAttributedString(string: text, attributes: [.font: fpsLabel.font as Any, .foregroundColor: UIColor.white]))
                fpsLabel.attributedText = line
            } else {
                fpsLabel.text = text
            }
            lastFPSLabelUpdate = now
        }
        let elapsed = lastControllerPoll.map { now - $0 } ?? (1.0 / 60.0)
        lastControllerPoll = now
        let gameStatus = PGGameStatus()
        // A long respawn or story load looked like a freeze (GTA-50): say it's loading.
        let loading = engineStarted && PGLoadSceneSeconds() >= 3 && gameStatus & 1 != 0 && gameStatus & 16 == 0
        // A script mod starting up over several frames slows the game (Menyoo reads its lists for about 10 s): say which
        // one is loading, so it doesn't look like a hang (GTA-209).
        let busyMod = engineStarted && !loading ? PGAsiBusyModName().map { String(cString: $0) } : nil
        let pillText = busyMod.map { name in
            AppLanguage.interpolate(AppLanguage.choose("Loading {arg0}…"), [name.lowercased().hasSuffix(".asi") ? String(name.dropLast(4)) : name])
        } ?? AppLanguage.choose("Loading…")
        if loadingPill.text != pillText { loadingPill.text = pillText }
        let showPill = loading || busyMod != nil
        if showPill == loadingPill.isHidden {
            loadingPill.isHidden = !showPill
            if loadingPill.superview == nil {
                view.addSubview(loadingPill)
                NSLayoutConstraint.activate([loadingPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                             loadingPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)])
            }
        }
        // Friend Request (GTA-73): the Lifeinvader presentation runs on a black TV. The mission (lester1) first waits
        // for a channel change ("Find Weazel News"), then lets the player call Jay Norris's phone from 77 s to
        // 170 s after the news comes on, which is when Jay holds the phone up on TV; after that the mission fails.
        // On a black TV players can't see either moment, so the note says what to do and when.
        var presentationMs: Int32 = 0, presentationLength: Int32 = 0
        let playing = engineStarted && bootedMode == .story && PGTVPresentation(&presentationMs, &presentationLength)
        let findNews = engineStarted && bootedMode == .story && !playing && lastStoryMission.hasPrefix("lester1") && touchControls.tvCouch
        if playing || findNews {
            if presentationPill.superview == nil {
                view.addSubview(presentationPill)
                NSLayoutConstraint.activate([presentationPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                             presentationPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
                                             presentationPill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6)])
            }
            let second = playing ? Int(presentationMs / 1000) : -2
            if second != presentationSecond {
                presentationSecond = second
                let time = { (ms: Int32) in String(format: "%d:%02d", ms / 60000, ms / 1000 % 60) }
                let callFrom: Int32 = 77_083, callUntil: Int32 = 170_000
                if !playing {
                    presentationPill.text = AppLanguage.choose("Find Weazel News: change the TV channel with the arrows (or move the left stick sideways).")
                } else if presentationMs < callFrom {
                    presentationPill.text = AppLanguage.interpolate(AppLanguage.choose("Lifeinvader presentation {arg0} of {arg1}. The TV stays black (the game files have no TV videos). At {arg2} Jay Norris holds up the phone: then call him."), [time(presentationMs), time(presentationLength), time(callFrom)])
                } else if presentationMs < callUntil {
                    presentationPill.text = AppLanguage.interpolate(AppLanguage.choose("Call now: Jay Norris is holding up the phone. Phone › Contacts › Jay Norris, before {arg0} ({arg1} now)."), [time(callUntil), time(presentationMs)])
                } else {
                    presentationPill.text = AppLanguage.choose("Too late to call: the mission fails. Retry, and call Jay Norris between 1:17 and 2:50.")
                }
            }
            if presentationPill.isHidden { presentationPill.isHidden = false; appendLog(playing ? "TV: Lifeinvader presentation playing (\(presentationLength / 1000) s); showing when to call" : "TV: Friend Request waits for a channel change; showing how") }
        } else if !presentationPill.isHidden {
            presentationPill.isHidden = true; presentationSecond = -1; appendLog("TV: presentation note hidden")
        }
        if gameStatus != lastGameStatus {
            lastGameStatus = gameStatus
            appendLog("Game state: control \(gameStatus & 1 != 0 ? "off" : "on")\(gameStatus & 2 != 0 ? ", phone out" : "")\(gameStatus & 4 != 0 ? ", cutscene" : "")\(gameStatus & 8 != 0 ? ", warning screen" : "")\(gameStatus & 16 != 0 ? ", no player" : "")\(gameStatus & 32 != 0 ? ", paused" : "")")
            if ProcessInfo.processInfo.arguments.contains("--capture-state") { PGCaptureNativeFrame("state-\(gameStatus)-\(Int(now))") }
        }
        if let padProof { PGUpdateVirtualPad(padProof); return }
        // Everything reaches the engine as its own controller, so controller
        // features (assisted aim, analog steering and throttle) apply.
        var state = PGPadState()
        var hasController = false
        // One look-up per tick (the radio wheel below uses the same pad).
        var connectedPad: GCExtendedGamepad?
        if let controller = Self.activeController(), let pad = controller.extendedGamepad {
            state = PGPadState(gamepad: pad)
            hasController = true
            connectedPad = pad
            // The touch Settings button hides while a controller is connected, so holding View / Share (Select)
            // for a second opens the app's Settings; players used to disconnect the controller to get there.
            if engineStarted, pad.buttonOptions?.isPressed == true {
                if let since = controllerSelectSince, since >= 0, now - since > 1, presentedViewController == nil {
                    controllerSelectSince = -1
                    appendLog("Controller: Select held, opening Settings.")
                    showSettings()
                } else if controllerSelectSince == nil { controllerSelectSince = now }
            } else { controllerSelectSince = nil }
            // Diagnostics (GTA-58, "R2 sometimes doesn't accelerate"): the strongest trigger values the
            // controller reported, how often each trigger went down, and which other buttons were held with RT,
            // logged every 10 s while they move.
            controllerTriggerPeak = (max(controllerTriggerPeak.0, pad.leftTrigger.value), max(controllerTriggerPeak.1, pad.rightTrigger.value))
            let triggersDown = (pad.leftTrigger.value > 0.5, pad.rightTrigger.value > 0.5)
            if triggersDown.0 && !controllerTriggersWereDown.0 { controllerTriggerPresses.0 += 1 }
            if triggersDown.1 && !controllerTriggersWereDown.1 { controllerTriggerPresses.1 += 1; controllerButtonsWithRT.formUnion(state.padButtons) }
            controllerTriggersWereDown = triggersDown
            if now - controllerTriggerLoggedAt > 10, controllerTriggerPeak.0 + controllerTriggerPeak.1 > 0 {
                let names: [(PadButtons, String)] = [(.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.l1, "LB"), (.r1, "RB"), (.start, "Menu"), (.select, "View"), (.l3, "LS"), (.r3, "RS"), (.up, "Up"), (.down, "Down"), (.left, "Left"), (.right, "Right")]
                let withRT = names.filter { controllerButtonsWithRT.contains($0.0) }.map(\.1).joined(separator: ",")
                appendLog(String(format: "Controller %@: LT peak %.2f, RT peak %.2f (analog %@), pressed LT %d, RT %d times, held with RT: %@ in the last 10 s, vehicle %u", controller.vendorName ?? "?", controllerTriggerPeak.0, controllerTriggerPeak.1, pad.rightTrigger.isAnalog ? "yes" : "no", controllerTriggerPresses.0, controllerTriggerPresses.1, withRT.isEmpty ? "nothing" : withRT, PGCurrentTouchContext()))
                controllerTriggerPeak = (0, 0); controllerTriggerLoggedAt = now; controllerTriggerPresses = (0, 0); controllerButtonsWithRT = []
            }
            // A digital trigger (0 or 1, e.g. the GameSir X5 Lite's) pulses many times a second when the controller's
            // turbo is on for it, and a pulsing RT hardly accelerates (GTA-58): it stays held 0.12 s after its last
            // pressed reading, so the pulses become one press. Analog triggers are left as they are.
            if !pad.leftTrigger.isAnalog { if triggersDown.0 { digitalTriggerAt.0 = now } else if now - digitalTriggerAt.0 < 0.12 { state.leftTrigger = 1 } }
            if !pad.rightTrigger.isAnalog { if triggersDown.1 { digitalTriggerAt.1 = now } else if now - digitalTriggerAt.1 < 0.12 { state.rightTrigger = 1 } }
            if diagnosticsOverlay?.isHidden != true { controllerLabel.text = AppLanguage.interpolate(AppLanguage.choose("Controller: {arg0}"), [controller.vendorName ?? AppLanguage.choose("Gamepad")]) }
        } else if diagnosticsOverlay?.isHidden != true {
            #if targetEnvironment(macCatalyst)
            controllerLabel.text = AppLanguage.choose("Keyboard and mouse")
            #else
            controllerLabel.text = AppLanguage.choose("Touch controls ready")
            #endif
        }
        // Test: --test-controller acts as if a controller were connected (the controller-only layout, GTA-146), also
        // with the harness's --touch-controls-preview.
        #if targetEnvironment(simulator)
        let testController = ProcessInfo.processInfo.arguments.contains("--test-controller")
        if testController { hasController = true }
        #else
        let testController = false
        #endif
        // The engine's rumble and the adaptive triggers run on their own 100 Hz clock (ControllerFeedback).
        controllerFeedback.update(controller: hasController ? Self.activeController() : nil, engineStarted: engineStarted, active: true,
                                  leftPull: state.leftTrigger, rightPull: state.rightTrigger)
        // With a controller connected the touch controls step aside (Settings › Touch controls).
        // Keyboard and mouse: every frame while the game runs (keys go straight to the game as they change).
        let keyboardMouse = GameSettings.shared.keyboardMouse
        if engineStarted && keyboardMouse { KeyboardMouse.shared.send(focused: true) }
        // Automation: --inject-key <vk> <seconds after WORLD_READY> <hold seconds>, --inject-mouse <dx> <dy> <seconds after>.
        if let ready = worldReadyAt { injectTestInput(sinceWorld: now - ready) }
        let pcControls = keyboardMouse && KeyboardMouse.shared.hasKeyboard && KeyboardMouse.shared.hasMouse
        let previewing = ProcessInfo.processInfo.arguments.contains("--touch-controls-preview")
        let controllerHides = (!previewing || testController) && (hasController || pcControls) && GameSettings.shared.hideTouchWithController
        // Touch scheme Controller buttons (GTA-195): the controller pad plays, the situational layer keeps Settings and Mods.
        let padScheme = GameSettings.shared.touchScheme == .controller
        let padActive = touchControlsAvailable && stoppedPanel == nil && !controllerHides && padScheme
        controllerPad.isHidden = !padActive
        let touchActive = touchControlsAvailable && stoppedPanel == nil && !controllerHides && !padScheme
        // With a controller the touch layer keeps only Settings and Mods (GTA-146); the game reads no touch pad then.
        touchControls.controllerOnly = controllerHides || padScheme
        touchControls.padScheme = padScheme && !controllerHides
        touchControls.isHidden = !(touchControlsAvailable && stoppedPanel == nil)
        // The wheel's, the phone's and the FPS counter's own places follow the buttons on screen (GTA-197).
        let hudContext: HUDTouchContext = controllerHides ? .controller : padScheme ? .pad : .situational
        if hudContext != GameSettings.hudContext {
            GameSettings.hudContext = hudContext
            if engineStarted { GameSettings.shared.applyHUDLayout() }
            placeFPSLabel()
        }
        var vehicle = touchActive ? PGCurrentTouchContext() : 0
        var pauseMenu = PGPauseMenuActive()
        // Debug: --preview-context <vehicle type + 1 | menu> to review a layout.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--preview-context"), i + 1 < arguments.count {
            if arguments[i + 1] == "menu" { pauseMenu = true } else { vehicle = UInt32(arguments[i + 1]) ?? 0 }
        }
        // Debug: --context-after <seconds after WORLD_READY> <vehicle type + 1> simulates entering a vehicle.
        if let i = arguments.firstIndex(of: "--context-after"), i + 2 < arguments.count, let ready = worldReadyAt,
           let after = Double(arguments[i + 1]), now - ready > after { vehicle = UInt32(arguments[i + 2]) ?? vehicle }
        if touchActive {
            // Debug: --preview-prompt shows the Accept/Back prompt layout, --preview-phone the phone dock.
            var status = gameStatus
            if arguments.contains("--preview-prompt") { status |= 1 }
            if arguments.contains("--preview-phone") { status |= 2 }
            // Story mode and Sandbox both switch characters (GTA-199).
            touchControls.characterSwitchEnabled = bootedMode != nil || arguments.contains("--preview-switch")
            touchControls.updateGameState(status)
            touchControls.updateContext(vehicle: vehicle, pauseMenu: pauseMenu)
            var hints = PGReadControlHints(vehicle)
            // Debug: --preview-hints special,detonate,help,taxi shows the situational buttons.
            if let i = arguments.firstIndex(of: "--preview-hints"), i + 1 < arguments.count {
                let wanted = arguments[i + 1]
                if wanted.contains("special") { hints.specialShown = true; hints.specialReady = true; hints.specialFill = 0.7 }
                if wanted.contains("detonate") { hints.canDetonate = true }
                if wanted.contains("help") { hints.helpShown = true; hints.helpContext = true }
                if wanted.contains("taxi") { hints.vehicleModel = 0xC703DB5F; hints.passenger = true; hints.taxiMenu = true }
            }
            touchControls.updateHints(hints)
            // Debug: --preview-mission-inputs shows every mission button.
            let previewMission = arguments.contains("--preview-mission-inputs")
            // The script inputs (INPUT_SCRIPT_*, 222-235) count when a script reads them in any way: Eye in the Sky's
            // scan reads RT with IS_CONTROL_PRESSED, which reads the input itself, so the poll check never saw it and the
            // RT button showed only while the help named it (GTA-163). Other inputs keep the poll check: scripts read
            // the play inputs that way all the time.
            // A script screen that reads the frontend D-pad every frame (the ATM, GTA-202) gets the menu layout too; only
            // the game's own scripts count, as a script mod may check the D-pad every frame with its menu closed (GTA-213).
            touchControls.updateMissionInputs(read: { PGInputGameReadWithin($0, 250) != 0 }) { previewMission || PGInputPolledWithin($0, 700) != 0 || ((222...235).contains($0) && PGInputReadWithin($0, 700) != 0) }
            // Deliberately let the native game decide if relative mouse motion
            // disables assisted targeting. Never force the last-device flag.
            var mouseSwipe = touchControls.experimentalMouseLookActive && !hasController && !pcControls
            #if targetEnvironment(simulator)
            // Test (PG_TEST_MOUSE=<seconds after WORLD_READY>): 20 s of swipe-camera mouse movement.
            if let start = ProcessInfo.processInfo.environment["PG_TEST_MOUSE"].flatMap(Double.init), let ready = worldReadyAt,
               now - ready > start, now - ready < start + 20 {
                mouseSwipe = true; PGSetMouseFocus(true, true); PGMouseInput(6, 0, 0)
                if !testMouseLogged { testMouseLogged = true; appendLog("TEST: mouse moving (swipe camera) for 20 s") }
            } else if testMouseLogged, let start = ProcessInfo.processInfo.environment["PG_TEST_MOUSE"].flatMap(Double.init), let ready = worldReadyAt,
                      now - ready >= start + 20, !testMouseStopped {
                testMouseStopped = true; appendLog("TEST: mouse stopped")
            }
            #endif
            if mouseSwipe { PGSetMouseFocus(true, true) }
            else if wasMouseSwipeActive { PGSetMouseFocus(true, false) }
            wasMouseSwipeActive = mouseSwipe
            #if targetEnvironment(simulator)
            if let ready = worldReadyAt { touchControls.applyTestPresses(sinceWorld: now - ready) }
            #endif
            let touch = touchControls.padState(elapsed: elapsed)
            if ProcessInfo.processInfo.arguments.contains("--trace-touch-controls") {
                let sample = String(format: "Touch pad: buttons=%u move=%.2f,%.2f look=%.2f,%.2f triggers=%.2f,%.2f device=%d", touch.buttons, touch.leftX, touch.leftY, touch.rightX, touch.rightY, touch.leftTrigger, touch.rightTrigger, PGLastInputDevice())
                if sample != lastTouchInputTrace { lastTouchInputTrace = sample; appendLog(sample) }
            }
            state.merge(touch)
        }
        if padActive { state.merge(controllerPad.padState()) }
        #if targetEnvironment(simulator)
        var keys = PGPadState()
        func held(_ key: UIKeyboardHIDUsage) -> Float { simulatorKeys.contains(key) ? 1 : 0 }
        keys.leftX = held(.keyboardD) - held(.keyboardA)
        keys.leftY = held(.keyboardW) - held(.keyboardS)
        keys.rightX = held(.keyboardRightArrow) - held(.keyboardLeftArrow)
        keys.rightY = held(.keyboardUpArrow) - held(.keyboardDownArrow)
        keys.leftTrigger = held(.keyboardZ); keys.rightTrigger = held(.keyboardX)
        let map: [(UIKeyboardHIDUsage, PadButtons)] = [(.keyboardSpacebar, .x), (.keyboardLeftShift, .a), (.keyboardF, .y), (.keyboardR, .b),
            (.keyboardQ, .r1), (.keyboardTab, .l1), (.keyboardV, .select), (.keyboardEscape, .start), (.keyboardE, .l3),
            (.keyboardReturnOrEnter, .a), (.keyboardDeleteOrBackspace, .b), (.keyboardI, .up), (.keyboardK, .down), (.keyboardJ, .left), (.keyboardL, .right)]
        var keyButtons = PadButtons()
        for (key, bit) in map where simulatorKeys.contains(key) { keyButtons.insert(bit) }
        // Test: --test-pause-cycle <seconds> presses Start every period from 20 s after WORLD_READY,
        // opening and closing the pause map over and over.
        if let i = arguments.firstIndex(of: "--test-pause-cycle"), i + 1 < arguments.count, let period = Double(arguments[i + 1]),
           let ready = worldReadyAt, now - ready > 20, (now - ready).truncatingRemainder(dividingBy: period) < 0.15 {
            keyButtons.insert(.start)
        }
        keys.padButtons = keyButtons
        state.merge(keys)
        #endif
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        if now < debugPadUntil { state.merge(debugPad) }
        #endif
        if !touchActive && wasMouseSwipeActive {
            PGSetMouseFocus(true, false)
            wasMouseSwipeActive = false
        }
        if engineStarted && touchActive && GameSettings.shared.cameraTouchMode != .stick {
            let device = PGLastInputDevice()
            let mode = PGTargetingMode()
            let text = "\(device == -4 ? "MOUSE" : (0...3).contains(device) ? "PAD" : "UNKNOWN") \(device) | Aim \(mode)"
            let key = "\(GameSettings.shared.cameraTouchMode.rawValue):\(text):\(touchControls.aiming)"
            if key != lastDeviceDiagnostic && now - lastDeviceLogAt > 0.25 {
                lastDeviceDiagnostic = key
                lastDeviceLogAt = now
                appendLog("Swipe input: \(key)")
            }
        } else {
            inputTestLabel.isHidden = true
            lastDeviceDiagnostic = ""
        }
        // Optional gyro: phone rotation adds to the right stick.
        let settings = GameSettings.shared
        let onFoot = vehicle == 0
        let driving = touchControls.context.driving
        let tiltWanted = touchActive && driving && settings.tiltSteer != .off
        let gyroWanted = touchActive && ((settings.gyroAim != .off && !touchControls.flyingWithRightStick && touchControls.context != .menu) || tiltWanted)
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        gyro.setRunning(gyroWanted, orientation: orientation)
        if tiltWanted, let angle = gyro.steeringAngle() {
            // The neutral angle is however the phone is held on entering.
            if tiltSince == nil { tiltSince = now }
            if tiltNeutral == nil, now - (tiltSince ?? now) > 0.15 { tiltNeutral = angle }
            if let neutral = tiltNeutral {
                var degrees = (angle - neutral) * 180 / .pi
                degrees = abs(degrees) < 1.5 ? 0 : degrees - copysign(1.5, degrees)
                let raw = max(-1, min(1, degrees / settings.tiltFullLock))
                let curved = copysign(pow(abs(raw), 1.4), raw)
                tiltSmoothed += (curved - tiltSmoothed) * min(1, elapsed / 0.06)
                let fadeIn = min(1, (now - (tiltSince ?? now) - 0.15) / 0.3)
                let tilt = Float(tiltSmoothed * max(0, fadeIn))
                if settings.tiltSteer == .full && abs(state.leftX) < 0.05 { state.leftX = tilt }
                else if settings.tiltSteer == .assist { state.leftX = max(-1, min(1, state.leftX + tilt * 0.6)) }
            }
        } else if !driving {
            tiltNeutral = nil; tiltSince = nil; tiltSmoothed = 0
        }
        if gyroWanted && settings.gyroAim != .off {
            let aiming = touchControls.aiming || state.leftTrigger > 0.1
            let active = aiming || (settings.gyroAim == .always && onFoot)
            let rate = gyro.rate(active: active, elapsed: elapsed)
            // About 2 rad/s of phone rotation is a full stick at sensitivity 1.
            let gain = 350 * settings.gyroSensitivity
            let invert: CGFloat = settings.gyroInvertY ? -1 : 1
            state.rightX = max(-1, min(1, state.rightX + TouchControlsView.lookAxis(rate.dx * gain)))
            state.rightY = max(-1, min(1, state.rightY - TouchControlsView.lookAxis(rate.dy * gain * invert)))
        }
        // A controller's right stick picks on the radio wheel (its own inputs have no controller
        // binding in this build; see PGSetRadioWheelDirection). The camera ignores the stick meanwhile.
        if engineStarted, let pad = connectedPad,
           PGReadControlHints(PGCurrentTouchContext()).radioWheelOpen {
            let x = pad.rightThumbstick.xAxis.value, y = pad.rightThumbstick.yAxis.value, length = hypotf(x, y)
            PGSetRadioWheelDirection(length > 0.3 ? x / length : 0, length > 0.3 ? y / length : 0, true)
            state.rightX = 0; state.rightY = 0
            controllerRadioWheel = true
        } else if controllerRadioWheel {
            controllerRadioWheel = false
            PGSetRadioWheelDirection(0, 0, false)
        }
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        debugLastPad = state
        #endif
        PGUpdateVirtualPad(state)
    }
    private var testMouseLogged = false, testMouseStopped = false, testPauseDone = false
    /// When the controller's Select button went down (-1: Settings already opened for this hold).
    private var controllerSelectSince: CFTimeInterval?
    private var controllerRadioWheel = false
    /// Controller trigger diagnostics and the digital-trigger hold (GTA-58).
    private var controllerTriggersWereDown = (false, false), controllerTriggerPresses = (0, 0), controllerButtonsWithRT = PadButtons()
    private var digitalTriggerAt: (CFTimeInterval, CFTimeInterval) = (-1, -1)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue?.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

/// Read from the audio thread: the game's sound is silent while the intro plays.
nonisolated(unsafe) private var introPlaying = false

/// Full-screen intro video; a tap skips it.
final class IntroVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private let player: AVPlayer
    private var ended: NSObjectProtocol?
    var finished: (() -> Void)?

    init(frame: CGRect, url: URL, muted: Bool) {
        player = AVPlayer(url: url)
        player.isMuted = muted
        super.init(frame: frame)
        backgroundColor = .black
        (layer as! AVPlayerLayer).player = player
        (layer as! AVPlayerLayer).videoGravity = .resizeAspect
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(finish)))
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in self?.finish() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { if let ended { NotificationCenter.default.removeObserver(ended) } }

    func play() { player.play() }
    @objc private func finish() {
        guard let finished else { return }
        self.finished = nil
        player.pause()
        finished()
    }
}

/// A label with room around its text (the loading pill).
private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 6)) }
    override var intrinsicContentSize: CGSize { let size = super.intrinsicContentSize; return CGSize(width: size.width + 28, height: size.height + 12) }
}
