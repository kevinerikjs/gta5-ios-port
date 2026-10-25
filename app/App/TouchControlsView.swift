import UIKit

/// What the player is doing; picked automatically from engine state.
enum ControlContext: Equatable {
    case onFoot, car, bike, bicycle, boat, sub, heli, plane, menu

    /// `vehicle` is PGCurrentTouchContext(): 0 on foot, else vehicle type + 1.
    init(vehicle: UInt32, pauseMenu: Bool) {
        if pauseMenu { self = .menu; return }
        switch vehicle {
        case 0: self = .onFoot
        case 2: self = .plane
        case 9, 10, 11: self = .heli
        case 12: self = .bike
        case 13: self = .bicycle
        case 14: self = .boat
        case 16: self = .sub
        default: self = .car
        }
    }
    var driving: Bool { [.car, .bike, .bicycle, .boat, .sub].contains(self) }
    var flying: Bool { self == .heli || self == .plane }
}

enum ControlStyle {
    /// GTA V's HUD blue, the only accent colour in the overlay.
    static let accent = UIColor(red: 0.365, green: 0.714, blue: 0.898, alpha: 1)
    /// SF Symbols for controls that have no generated icon.
    static let fallbackSymbol: [String: String] = [
        "radio": "radio", "next_song": "forward.end.fill", "mods": "puzzlepiece.extension.fill", "look_back": "arrow.uturn.backward", "up": "chevron.up", "down": "chevron.down",
        "left": "chevron.left", "right": "chevron.right", "accept": "checkmark", "back": "arrow.uturn.left",
        "tab_left": "chevron.left.2", "tab_right": "chevron.right.2", "dive": "arrow.down.to.line",
        "surface": "arrow.up.to.line", "crouch": "figure.walk", "pedal": "bicycle",
        "switch_character": "person.2.fill", "special_ability": "bolt.circle.fill", "interact": "hand.point.right.fill",
        "detonate": "burst.fill", "zoom_in": "plus.magnifyingglass", "zoom_out": "minus.magnifyingglass",
        "weapon_prev": "chevron.left", "weapon_next": "chevron.right", "throttle_up": "chevron.up.2",
        "throttle_down": "chevron.down.2", "yaw_left": "rotate.left.fill", "yaw_right": "rotate.right.fill",
        "tow_hook": "car.side.rear.tow.hitch.fill", "tow_arm_up": "arrow.up.to.line", "tow_arm_down": "arrow.down.to.line", "roof": "convertible.side.arrowtriangle.up.arrowtriangle.down.fill",
        "steer_left": "arrowtriangle.left.fill", "steer_right": "arrowtriangle.right.fill",
        "phone_option": "circle.grid.3x3.fill", "taxi_hurry": "hare.fill", "taxi_stop": "stop.fill",
        "prompt_option": "forward.end.fill", "duck": "arrow.down.circle.fill",
        "script_lb": "lb.button.roundedbottom.horizontal.fill", "script_rb": "rb.button.roundedbottom.horizontal.fill",
        "script_lt": "lt.button.roundedtop.horizontal.fill", "script_rt": "rt.button.roundedtop.horizontal.fill",
        "script_y": "y.circle.fill", "script_x": "x.circle.fill", "script_a": "a.circle.fill", "script_b": "b.circle.fill",
        "script_ls": "l.joystick.press.down.fill", "script_rs": "r.joystick.press.down.fill",
        "script_pad_up": "dpad.up.fill", "script_pad_down": "dpad.down.fill", "script_pad_left": "dpad.left.fill"]
    /// A short label drawn like a symbol, for buttons no SF Symbol fits ("LT+RT").
    static func textIcon(_ text: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return UIGraphicsImageRenderer(size: size).image { _ in
            (text as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }.withRenderingMode(.alwaysTemplate)
    }
    /// iOS 16 and 17 have no tow hitch or convertible symbols (they came in iOS 18).
    static let olderSymbol: [String: String] = [
        "tow_hook": "truck.pickup.side.fill", "roof": "car.side.arrowtriangle.up.arrowtriangle.down.fill"]
    /// Model name hashes (joaat) from the game's vehicles.meta: tow trucks, whose hook releases
    /// with INPUT_VEH_GRAPPLING_HOOK, and cars with an animated convertible roof (animConvRoofDictName).
    static let towTrucks: Set<UInt32> = [0xB12314E0 /* towtruck */, 0xE5A2D6C6 /* towtruck2 */]
    /// Vehicles with an arm on the left stick up/down (INPUT_VEH_MOVE_UD): the tow trucks and the dock Handler of
    /// Scouting the Port, whose arm a thumb on the steering stick could raise but hardly lower (GTA-97).
    static let armVehicles: Set<UInt32> = towTrucks.union([0x1A7FCEFA /* handler */])
    /// Cargobobs: the hook (deploy, retract, release) is INPUT_VEH_GRAPPLING_HOOK too, D-pad right (GTA-133: The
    /// Merryweather Heist's minisub pickup had no button for it).
    static let cargobobs: Set<UInt32> = [0xFCFCB68B /* cargobob */, 0x60A7EA10 /* cargobob2 */, 0x53174EEF /* cargobob3 */, 0x78BC1A3C /* cargobob4 */]
    static let taxi: UInt32 = 0xC703DB5F
    /// The player as Chop (a_c_chop), in the missions that switch from Franklin to him.
    static let chop: UInt32 = 0x14EC17EA
    static let convertibles: Set<UInt32> = [
        0xA8E38B01 /* ninef2 */, 0x7B8AB45F /* carbonizzare */, 0x13B57D8A /* cogcabrio */, 0xFAAD85EE /* felon2 */,
        0xB9CB3B69 /* issi2 */, 0x679450AF /* rapidgt2 */, 0x3412AE2D /* sentinel2 */, 0xB8E2AE18 /* zion2 */,
        0x16E478C1 /* surano */, 0x5B42A5C4 /* tornado2 */]
}

/// One on-screen control: a glyph in a circle (or a rounded pedal), no caption.
final class ControlButton: UIView {
    let name: String
    var isPedal = false
    /// A finger already down may slide onto this control (pedals).
    var slideTarget = false
    private let icon = UIImageView()
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let progress = CAShapeLayer()
    private(set) var pressed = false
    var active = false { didSet { if active != oldValue { updateAppearance() } } }

    init(_ name: String, icon iconName: String, label: String) {
        self.name = name
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        for shape in [halo, ring, progress] { shape.fillColor = nil; layer.addSublayer(shape) }
        halo.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        halo.lineWidth = 2
        halo.opacity = 0
        ring.strokeColor = ControlStyle.accent.cgColor
        ring.lineWidth = 2.5
        progress.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        progress.lineWidth = 3
        progress.lineCap = .round
        progress.strokeEnd = 0
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        setIcon(iconName)
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIcon(_ iconName: String) {
        // Mod buttons (GTA-180) use SF Symbols from their icon library.
        if iconName.hasPrefix("sf:") {
            icon.image = (UIImage(systemName: String(iconName.dropFirst(3)), withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
                ?? UIImage(systemName: "circle", withConfiguration: UIImage.SymbolConfiguration(weight: .bold)))?.withRenderingMode(.alwaysTemplate)
            return
        }
        let image = iconName.hasPrefix("text:") ? ControlStyle.textIcon(String(iconName.dropFirst(5))) : UIImage(named: "icon_" + iconName)
            ?? UIImage(systemName: ControlStyle.fallbackSymbol[iconName] ?? "circle", withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
            ?? UIImage(systemName: ControlStyle.olderSymbol[iconName] ?? "circle", withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        icon.image = image?.withRenderingMode(.alwaysTemplate)
    }

    private var cornerRadius: CGFloat { isPedal ? 18 : bounds.width / 2 }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = cornerRadius
        let side = min(bounds.width, bounds.height) * 0.56
        icon.bounds.size = CGSize(width: side, height: side)
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        halo.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -5, dy: -5), cornerRadius: cornerRadius + 5).cgPath
        ring.path = path
        progress.path = path
        layer.shadowPath = path
    }

    private func updateAppearance() {
        let base = UIColor.black.withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 0.7 : 0.3)
        backgroundColor = pressed ? UIColor.white.withAlphaComponent(0.85) : base
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(pressed ? 0.9 : 0.28).cgColor
        icon.tintColor = pressed ? UIColor.black.withAlphaComponent(0.9) : UIColor.white.withAlphaComponent(0.92)
        ring.opacity = active && !pressed ? 1 : 0
        accessibilityValue = pressed ? AppLanguage.choose("Held") : active ? AppLanguage.choose("On") : nil
    }

    func setPressed(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        updateAppearance()
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduce ? 0 : 0.12, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = value && !reduce ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
        }
        if value {
            halo.removeAllAnimations(); halo.opacity = 1
        } else {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.2
            halo.add(fade, forKey: "fade"); halo.opacity = 0
        }
    }

    /// 0...1 ring around the edge, e.g. hold-to-exit in the air.
    func setProgress(_ value: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progress.strokeEnd = max(0, min(1, value))
        CATransaction.commit()
    }

    func contains(point: CGPoint, slop: CGFloat) -> Bool {
        frame.insetBy(dx: -slop, dy: -slop).contains(point)
    }
}

/// Ring and knob drawn where a thumb lands; hidden otherwise.
final class FloatingStick: UIView {
    private let base = UIView()
    private let knob = UIView()
    private let sprintHalo = UIView()
    var baseDiameter: CGFloat = 120
    var travel: CGFloat = 48
    private(set) var origin = CGPoint.zero
    private(set) var value = CGPoint.zero
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// Automation: a held stick without a finger (--test-touch-sprint).
    func testHold(_ point: CGPoint?) { value = point ?? .zero }
    #endif
    private var engaged = false
    var idleOrigin: CGPoint? { didSet { if !engaged { showIdle() } } }
    private func showIdle() {
        if let idleOrigin { origin = idleOrigin; layoutParts(); alpha = 0.55 }
        else { alpha = 0 }
    }
    var sprinting = false { didSet { if sprinting != oldValue { sprintHalo.alpha = sprinting ? 1 : 0 } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for view in [sprintHalo, base, knob] { addSubview(view) }
        base.layer.borderWidth = 2
        base.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        base.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        sprintHalo.layer.borderWidth = 3
        sprintHalo.layer.borderColor = ControlStyle.accent.withAlphaComponent(0.85).cgColor
        sprintHalo.alpha = 0
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.25
        knob.layer.shadowRadius = 6
        alpha = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func begin(at point: CGPoint) {
        engaged = true
        origin = point
        value = .zero
        layoutParts()
        UIView.animate(withDuration: 0.08) { self.alpha = 1 }
    }
    /// The base stays where the thumb landed until it lifts; dragging past
    /// the edge holds full deflection in that direction.
    func move(to point: CGPoint, horizontalOnly: Bool = false) {
        let dx = point.x - origin.x, dy = horizontalOnly ? 0 : point.y - origin.y
        let length = max(1, hypot(dx, dy) / travel)
        value = CGPoint(x: dx / travel / length, y: -dy / travel / length)
        layoutParts()
    }
    func end() {
        engaged = false
        value = .zero
        sprinting = false
        UIView.animate(withDuration: 0.15) { self.showIdle() }
    }
    private func layoutParts() {
        base.bounds.size = CGSize(width: baseDiameter, height: baseDiameter)
        base.layer.cornerRadius = baseDiameter / 2
        base.center = origin
        sprintHalo.bounds.size = CGSize(width: baseDiameter + 12, height: baseDiameter + 12)
        sprintHalo.layer.cornerRadius = (baseDiameter + 12) / 2
        sprintHalo.center = origin
        let knobSize = baseDiameter * 0.43
        knob.bounds.size = CGSize(width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        knob.center = CGPoint(x: origin.x + value.x * travel, y: origin.y - value.y * travel)
    }
}

/// The touch overlay. Every finger gets one role when it lands (a button, the
/// move stick, the look pad, ...), and the result is reported as a game
/// controller so the engine's own controller handling (assisted aim, analog
/// driving) applies. The layout follows the player's state automatically;
/// there is no manual mode switch.
final class TouchControlsView: UIView {
    var inputChanged: (() -> Void)?
    /// In the layout editor: controls are shown but not played, and hidden controls stay visible (dimmed).
    var editing = false
    /// The control selected in the layout editor (drawn with a highlight).
    weak var highlighted: ControlButton? { didSet { updateHighlight() } }
    var openSettings: (() -> Void)?
    /// A line for the log when the game state behind the situational buttons changes.
    var hintsChanged: ((String) -> Void)?
    private(set) var context = ControlContext.onFoot

    private enum Role {
        case button(ControlButton)
        case moveStick, look, steer, planeStick
        /// Radio: a tap is the next station; held, the wheel opens and the same finger picks one.
        case radioWheel(start: CGPoint, current: CGPoint, since: CFTimeInterval)
        case weaponWheel(start: CGPoint, current: CGPoint)
        /// Character switch: D-pad down held, the same finger points at Michael, Franklin or Trevor.
        case characterWheel(start: CGPoint, current: CGPoint)
        case fireLook(ControlButton)
    }
    private var roles: [ObjectIdentifier: Role] = [:]

    private let moveStick = FloatingStick()
    private let rightStick = FloatingStick()
    /// Airplanes retain throttle when the right thumb lifts; rudder recentres.
    private var planeThrottle: CGFloat = 0
    private var planeStickEnabled: Bool {
        context == .plane && GameSettings.shared.airplaneRightStick && !phoneDock && !promptActive && !editing
    }
    private let lookStick = FloatingStick()
    /// Where a finger pressed Aim/Fire; dragging from there works as a stick.
    private var dragOrigins: [ObjectIdentifier: (start: CGPoint, current: CGPoint)] = [:]
    // Each finger keeps its original role from touchesBegan. Only a look-role
    // finger, or a right-hand Aim/Fire drag, is allowed to queue camera travel.
    private var pendingCameraTravel = CGPoint.zero
    private var fractionalMousePixels = CGPoint.zero
    private var lastCameraMode: GameSettings.CameraTouchMode = .stick
    private var cameraSwipeAvailable: Bool {
        context != .menu && !phoneDock && !gamePhoneOut && !promptActive && !context.flying && !hints.phoneBrowser && !helpAsksRightStick
    }
    private var swipeCameraEnabled: Bool {
        GameSettings.shared.cameraTouchMode != .stick && cameraSwipeAvailable
    }
    private func isSelectionWheel(_ role: Role) -> Bool {
        switch role {
        case .weaponWheel, .characterWheel, .radioWheel: return true
        default: return false
        }
    }
    /// Only the experimental mouse path needs pointer focus/lock.
    var experimentalMouseLookActive: Bool {
        swipeCameraEnabled && GameSettings.shared.cameraTouchMode == .swipeMouse && !has(isSelectionWheel)
    }
    private func clearCameraTravel() {
        pendingCameraTravel = .zero
        fractionalMousePixels = .zero
        PGClearCameraSwipe()
    }
    private func trackCameraSwipe(from previous: CGPoint, to point: CGPoint) {
        guard swipeCameraEnabled, !has(isSelectionWheel) else { return }
        pendingCameraTravel.x += point.x - previous.x
        pendingCameraTravel.y += point.y - previous.y
    }
    /// Flush only after the gesture roles have been reconciled, before sending
    /// the pad. The mouse path feeds native mouse deltas but does not replace
    /// the virtual pad, so we can observe whether the game still grants aim assist.
    private func flushCameraTravel() {
        let mode = GameSettings.shared.cameraTouchMode
        if mode != lastCameraMode { clearCameraTravel(); lastCameraMode = mode }
        guard swipeCameraEnabled, !has(isSelectionWheel) else {
            clearCameraTravel()
            return
        }
        let settings = GameSettings.shared
        let gain = CGFloat(mode == .swipeMouse
            ? (aiming ? settings.mouseAimSensitivity : settings.mouseLookSensitivity)
            : (aiming ? settings.swipeAimSensitivity : settings.swipeLookSensitivity))
        let raw = CGPoint(x: pendingCameraTravel.x * gain, y: pendingCameraTravel.y * gain)
        pendingCameraTravel = .zero
        guard raw != .zero else { return }
        switch mode {
        case .stick: break
        case .swipePad:
            // Existing proven engine-thread bridge expects rightY positive up.
            PGQueueCameraSwipe(Float(raw.x), Float(-raw.y))
        case .swipeMouse:
            // UIKit is Y-down, matching the engine's relative mouse pixels.
            // Preserve subpixel movement so very slow aiming is not lost.
            // Drop rather than defer an abnormally large single-frame jump:
            // deferred overflow would look like camera glide after finger-up.
            let total = CGPoint(x: max(-1600, min(1600, raw.x + fractionalMousePixels.x)),
                                y: max(-1600, min(1600, raw.y + fractionalMousePixels.y)))
            let dx = Int32(total.x.rounded(.towardZero))
            let dy = Int32(total.y.rounded(.towardZero))
            fractionalMousePixels = CGPoint(x: total.x - CGFloat(dx), y: total.y - CGFloat(dy))
            if dx != 0 || dy != 0 { PGMouseInput(dx, dy, mouseButtons) }
        }
    }

    private var sprintSince: CFTimeInterval?
    private var aimToggled = false
    /// Sprint button: a tap keeps sprinting while the move stick is held; letting go of it ends it.
    private var sprintLatched = false { didSet { sprint.active = sprintLatched } }
    private var lastFireTime: CFTimeInterval = 0
    private var fireStartedAt: CFTimeInterval?
    /// Buttons sent for a set time (special ability, radio taps), so the game sees every tap.
    private var pulses: [(buttons: PadButtons, until: CFTimeInterval)] = []
    /// When each pad bit was last pressed: every press lasts at least `minimumPress`.
    private var pressedAt: [UInt32: CFTimeInterval] = [:]
    private var lastHeld = PadButtons()
    private var radioDirection: (Float, Float)?
    private static let minimumPress: CFTimeInterval = 0.07
    /// From the engine (PGReadControlHints): which situational buttons apply right now.
    private var hints = PGControlHints()
    private var exitHoldStart: CFTimeInterval?
    private var phoneDock = false
    private var dockShowsLetters = false
    private var lastDockInput: CFTimeInterval = 0
    /// Game state (PGGameStatus): the phone is out on screen, and a full-screen prompt waits for
    /// Accept/Back (player control off outside cutscenes, e.g. Mission failed, or a warning screen).
    private var gamePhoneOut = false
    private var phoneRequestedAt: CFTimeInterval?
    /// This press of Phone opened the dock for a call that came in while driving (it must not hang up).
    private var phoneOpensDock = false
    private var promptSince: CFTimeInterval?
    /// The game is paused (PGGameStatus bit 32): the pause menu, or a screen like Mission failed.
    private var gamePaused = false
    private var promptActive = false
    /// Story mode only: the character switch button.
    var characterSwitchEnabled = false { didSet { if characterSwitchEnabled != oldValue { updateVisibility() } } }
    private var pedalClock: Double = 0
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// Automation (--test-touch-sprint): the move stick held forward with Sprint latched, through the
    /// same code a finger and a tap on Sprint use.
    func testSprint(_ on: Bool) { moveStick.testHold(on ? CGPoint(x: 0, y: 1) : nil); sprintLatched = on }
    #endif
    private var sprintClock: Double = 0
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    // On foot
    private let fire = ControlButton("fire", icon: "fire", label: AppLanguage.choose("Fire"))
    private let aim = ControlButton("aim", icon: "aim", label: AppLanguage.choose("Aim"))
    private let leftFire = ControlButton("leftFire", icon: "fire", label: AppLanguage.choose("Fire, left hand"))
    private let jump = ControlButton("jump", icon: "jump", label: AppLanguage.choose("Jump"))
    private let sprint = ControlButton("sprint", icon: "sprint", label: AppLanguage.choose("Sprint"))
    private let enter = ControlButton("enter", icon: "enter_exit", label: AppLanguage.choose("Enter vehicle"))
    private let weapons = ControlButton("weapons", icon: "weapons", label: AppLanguage.choose("Weapon wheel"))
    private let reload = ControlButton("reload", icon: "reload", label: AppLanguage.choose("Reload"))
    private let cover = ControlButton("cover", icon: "cover", label: AppLanguage.choose("Take cover"))
    private let crouch = ControlButton("crouch", icon: "crouch", label: AppLanguage.choose("Stealth"))
    private let switcher = ControlButton("switchCharacter", icon: "switch_character", label: AppLanguage.choose("Switch character"))
    private let special = ControlButton("special", icon: "special_ability", label: AppLanguage.choose("Special ability"))
    private let interact = ControlButton("interact", icon: "interact", label: AppLanguage.choose("Interact"))
    private let detonate = ControlButton("detonate", icon: "detonate", label: AppLanguage.choose("Detonate sticky bombs"))
    private let zoomIn = ControlButton("zoomIn", icon: "zoom_in", label: AppLanguage.choose("Zoom in"))
    private let zoomOut = ControlButton("zoomOut", icon: "zoom_out", label: AppLanguage.choose("Zoom out"))
    private let weaponPrev = ControlButton("weaponPrev", icon: "weapon_prev", label: AppLanguage.choose("Previous weapon in this slot"))
    private let weaponNext = ControlButton("weaponNext", icon: "weapon_next", label: AppLanguage.choose("Next weapon in this slot"))
    // Vehicles
    private let gas = ControlButton("gas", icon: "gas", label: AppLanguage.choose("Gas"))
    private let brake = ControlButton("brake", icon: "brake", label: AppLanguage.choose("Brake and reverse"))
    private let handbrake = ControlButton("handbrake", icon: "handbrake", label: AppLanguage.choose("Handbrake"))
    /// Bicycles jump (bunny hop) with INPUT_VEH_JUMP, R1 on the pad; hold it longer for a higher hop (GTA-150).
    private let bikeJump = ControlButton("bikeJump", icon: "jump", label: AppLanguage.choose("Jump"))
    // Settings › Steering buttons: left/right buttons instead of the steering stick.
    private let steerLeft = ControlButton("steer_left", icon: "steer_left", label: AppLanguage.choose("Steer left"))
    private let steerRight = ControlButton("steer_right", icon: "steer_right", label: AppLanguage.choose("Steer right"))
    private let driveBy = ControlButton("driveBy", icon: "fire", label: AppLanguage.choose("Aim and shoot from vehicle"))
    /// Aim out of the vehicle without shooting (LB), and duck down in the seat (A), GitHub #15.
    private let driveAim = ControlButton("driveAim", icon: "aim", label: AppLanguage.choose("Aim from the vehicle"))
    private let duck = ControlButton("duck", icon: "duck", label: AppLanguage.choose("Duck"))
    private let horn = ControlButton("horn", icon: "horn", label: AppLanguage.choose("Horn"))
    private let lookBack = ControlButton("lookBack", icon: "look_back", label: AppLanguage.choose("Look behind"))
    private let vehicleWeapon = ControlButton("vehicleWeapon", icon: "vehicle_weapon", label: AppLanguage.choose("Next vehicle weapon"))
    private let towHook = ControlButton("towHook", icon: "tow_hook", label: AppLanguage.choose("Release tow hook"))
    private let roof = ControlButton("roof", icon: "roof", label: AppLanguage.choose("Raise or lower the roof"))
    /// Unhitches a trailer: the game's input is the headlights held, which nobody guesses on touch (GTA-76).
    private let detachTrailer = ControlButton("detachTrailer", icon: "tow_hook", label: AppLanguage.choose("Detach trailer"))
    /// The next Self Radio song (GTA-5): on PC, a key in the radio wheel; shown while a Self Radio song plays.
    private let nextSong = ControlButton("nextSong", icon: "next_song", label: AppLanguage.choose("Next song"))
    private var nextSongWasPressed = false
    private var detachTrailerWasPressed = false
    private let towArmUp = ControlButton("towArmUp", icon: "tow_arm_up", label: AppLanguage.choose("Raise tow arm"))
    private let towArmDown = ControlButton("towArmDown", icon: "tow_arm_down", label: AppLanguage.choose("Lower tow arm"))
    private let dive = ControlButton("dive", icon: "dive", label: AppLanguage.choose("Dive"))
    private let surface = ControlButton("surface", icon: "surface", label: AppLanguage.choose("Surface"))
    // Aircraft
    private let airFire = ControlButton("airFire", icon: "special", label: AppLanguage.choose("Fire aircraft weapon"))
    private let gear = ControlButton("gear", icon: "landing_gear", label: AppLanguage.choose("Landing gear"))
    private let throttleUp = ControlButton("throttleUp", icon: "throttle_up", label: AppLanguage.choose("Throttle up, climb"))
    private let throttleDown = ControlButton("throttleDown", icon: "throttle_down", label: AppLanguage.choose("Throttle down, descend"))
    private let yawLeft = ControlButton("yawLeft", icon: "yaw_left", label: AppLanguage.choose("Rudder left"))
    private let yawRight = ControlButton("yawRight", icon: "yaw_right", label: AppLanguage.choose("Rudder right"))
    // Utility bar
    private let camera = ControlButton("camera", icon: "camera", label: AppLanguage.choose("Change camera"))
    private let phone = ControlButton("phone", icon: "phone", label: AppLanguage.choose("Phone"))
    private let pause = ControlButton("pause", icon: "pause", label: AppLanguage.choose("Pause menu"))
    private let settings = ControlButton("settings", icon: "settings", label: AppLanguage.choose("Settings"))
    /// Script mods (GTA-69): shown while one runs; opens the mod tray (ModKeysView).
    private let mods = ControlButton("mods", icon: "mods", label: AppLanguage.choose("Mods"))
    var modsActive = false { didSet { if modsActive != oldValue { updateVisibility(); setNeedsLayout() } } }
    /// A controller (or keyboard and mouse) drives the game and Settings › "Hide touch controls with a controller" is
    /// on: only Settings shows, plus Mods with script mods loaded, in their places from the player's layout (GTA-146).
    /// Touches anywhere else go past the controls, as they did when the whole layer was hidden.
    /// The Controller buttons touch scheme (GTA-195) is on: this view then shows only Settings, Mods and the player's
    /// own mod buttons, placed and saved in the scheme's layout group (Kevin, 2026-10-25).
    var padScheme = false { didSet { if padScheme != oldValue { updateVisibility(); setNeedsLayout() } } }
    var controllerOnly = false {
        didSet { if controllerOnly != oldValue { reset(publish: false); updateVisibility(); setNeedsLayout() } }
    }
    var openMods: (() -> Void)?
    /// Where the Mods control is, for the tray that opens from it.
    var modsButtonFrame: CGRect? { mods.isHidden || mods.superview == nil ? nil : mods.frame }
    private let lights = ControlButton("lights", icon: "lights", label: AppLanguage.choose("Headlights"))
    private let radio = ControlButton("radio", icon: "radio", label: AppLanguage.choose("Radio"))
    // Menu and phone dock
    private let up = ControlButton("up", icon: "up", label: AppLanguage.choose("Up"))
    private let down = ControlButton("down", icon: "down", label: AppLanguage.choose("Down"))
    private let left = ControlButton("left", icon: "left", label: AppLanguage.choose("Left"))
    private let right = ControlButton("right", icon: "right", label: AppLanguage.choose("Right"))
    private let accept = ControlButton("accept", icon: "accept", label: AppLanguage.choose("Select"))
    private let back = ControlButton("back", icon: "back", label: AppLanguage.choose("Back"))
    // The phone's X (Xbox) / Square: keypad for a custom number, and the phone's other options.
    private let phoneOption = ControlButton("phone_option", icon: "phone_option", label: AppLanguage.choose("Phone options"))
    // Taxi ride: X hurries the driver, B stops the taxi.
    private let taxiHurry = ControlButton("taxi_hurry", icon: "taxi_hurry", label: AppLanguage.choose("Hurry up"))
    private let taxiStop = ControlButton("taxi_stop", icon: "taxi_stop", label: AppLanguage.choose("Stop the taxi"))
    /// X on full-screen prompts: Skip Mission after failing, and other screens' third option.
    private let promptOption = ControlButton("prompt_option", icon: "prompt_option", label: AppLanguage.choose("Skip mission or other option (X)"))
    /// Yoga: a tap holds LT and RT together until tapped again, so both thumbs stay on the sticks.
    /// A mission that asks for LT and RT together (e.g. the yoga poses: both sticks plus both triggers,
    /// four fingers): one button that a tap latches on and a second tap releases.
    private let bothTriggers = ControlButton("script_ltrt", icon: "script_ltrt", label: AppLanguage.choose("LT and RT together (tap to hold, tap again to let go)"))
    private var bothTriggersHeld = false, bothTriggersWasPressed = false
    /// Mission buttons (GTA-51): a script asks for one of its own inputs (INPUT_SCRIPT_*, engine ids
    /// 222-231) that no button on screen sends, e.g. "Press RT to flip the chair" in By the Book. The
    /// button shows while the script keeps polling it (the engine reports polls, PGInputPolledWithin).
    /// `also`: other inputs the same pad button sends that ask for it too.
    private struct MissionButton {
        let input: Int32; let button: ControlButton; let pad: PadButtons?; let trigger: Int; var menuInput: Int32? = nil; var helpOnly = false; var also: [Int32] = []
        var inputs: [Int32] { [input] + (menuInput.map { [$0] } ?? []) + also }
    }
    private lazy var missionButtons: [MissionButton] = [
        MissionButton(input: 226, button: ControlButton("script_lb", icon: "script_lb", label: AppLanguage.choose("LB")), pad: .l1, trigger: 0, menuInput: 205),
        MissionButton(input: 228, button: ControlButton("script_lt", icon: "script_lt", label: AppLanguage.choose("LT")), pad: nil, trigger: 1, menuInput: 207),
        MissionButton(input: 229, button: ControlButton("script_rt", icon: "script_rt", label: AppLanguage.choose("RT")), pad: nil, trigger: 2, menuInput: 208),
        MissionButton(input: 227, button: ControlButton("script_rb", icon: "script_rb", label: AppLanguage.choose("RB")), pad: .r1, trigger: 0, menuInput: 206),
        MissionButton(input: 224, button: ControlButton("script_x", icon: "script_x", label: AppLanguage.choose("X")), pad: .x, trigger: 0),
        // Y is also INPUT_VEH_EXIT (75), which scripts read as a disabled control while player control is off, when the
        // prompt layout has no Enter/Exit button: Monkey Business's "Press ~input_veh_exit~ to dive into the sea." (fbi5A,
        // GTA-189), and the stash car in Grass Roots: The Drag, whose ignition fails until the player gets out (barry3c,
        // GTA-191). The help naming it counts too (PGControlHints.helpExit).
        MissionButton(input: 222, button: ControlButton("script_y", icon: "script_y", label: AppLanguage.choose("Y")), pad: .y, trigger: 0, menuInput: 204, also: [75]),
        MissionButton(input: 223, button: ControlButton("script_a", icon: "script_a", label: AppLanguage.choose("A")), pad: .a, trigger: 0),
        MissionButton(input: 225, button: ControlButton("script_b", icon: "script_b", label: AppLanguage.choose("B")), pad: .b, trigger: 0),
        MissionButton(input: 230, button: ControlButton("script_ls", icon: "script_ls", label: AppLanguage.choose("Left stick click")), pad: .l3, trigger: 0),
        MissionButton(input: 231, button: ControlButton("script_rs", icon: "script_rs", label: AppLanguage.choose("Right stick click")), pad: .r3, trigger: 0),
        // The script D-pad, only while the help names it (other scripts poll it in normal play): the elk call in
        // Hunting with Cletus is "~INPUT_SCRIPT_PAD_LEFT~ to call" (hunting2 reads IS_CONTROL_JUST_RELEASED(2, 234)), and
        // on foot no button sent D-pad left (GTA-149). D-pad right is the interact button (helpContext).
        MissionButton(input: 232, button: ControlButton("script_pad_up", icon: "script_pad_up", label: AppLanguage.choose("Up")), pad: .up, trigger: 0, helpOnly: true),
        MissionButton(input: 233, button: ControlButton("script_pad_down", icon: "script_pad_down", label: AppLanguage.choose("Down")), pad: .down, trigger: 0, helpOnly: true),
        MissionButton(input: 234, button: ControlButton("script_pad_left", icon: "script_pad_left", label: AppLanguage.choose("Left")), pad: .left, trigger: 0, helpOnly: true)]
    private var polledMission: Set<Int32> = []
    /// A script polls the frontend D-pad up and down (INPUT_FRONTEND_UP/DOWN, 188/187): a shop or script menu is
    /// open (the barber reads both). Down alone isn't a menu: after swipe-camera mouse movement a game script reads
    /// it every frame on foot, and the layout used to switch to the menu one (GTA-86).
    /// A script screen reads the frontend D-pad up and down every frame with IS_CONTROL_JUST_PRESSED and the like, which
    /// the poll check doesn't see, while player control stays on: the ATM (atm_trigger, "Exit (B)") does once its screen
    /// takes input, about 4 s after Interact. The play layout had no Back, so a touch-only player couldn't leave the ATM
    /// (GTA-202). Its frontend Accept and Back (201/202) don't tell: scripts poll those all through normal play. Read
    /// without a break for 0.6 s, so a script that checks the D-pad once can't swap the layout; the phone keeps its dock.
    /// Only the game's own scripts' reads count: a script mod may check the D-pad every frame with its menu closed, and
    /// the play controls turned into the menu ones while driving (GTA-213).
    private var frontendScreen = false
    private var frontendSince: CFTimeInterval?
    private var scriptMenu: Bool { (polledMission.isSuperset(of: [187, 188]) || frontendScreen) && context != .menu && !phoneDock }
    private var lastMissionLog = ""
    /// Inputs the help message on screen names (PGControlHints.helpInputs, bit n is input 218 + n): a mission asks for
    /// a button in its help ("Hold RT to grip a tooth" in By the Book) even when it reads the button in a way the poll
    /// check misses, so the help counts as asking (GTA-94).
    /// A help that names INPUT_VEH_EXIT or INPUT_ENTER asks for Y (75, GTA-189).
    private var helpAsked: Set<Int32> {
        guard hints.helpShown else { return [] }
        var asked = Set((0..<18).filter { hints.helpInputs & (1 << UInt32($0)) != 0 }.map { Int32(218 + $0) })
        if hints.helpExit { asked.insert(75) }
        return asked
    }
    /// The help asks for the right stick ("Rotate R to pull it out"): the right side is a stick then, also with the
    /// swipe camera, whose mouse movement the mission doesn't read as the stick (GTA-94).
    private var helpAsksRightStick: Bool { !helpAsked.isDisjoint(with: [220, 221]) }
    /// On a safehouse couch the TV help says "Use the left stick to change the channel / the volume", and on
    /// touch the stick is an invisible area: arrows that move the left stick show instead (Friend Request waits
    /// for a channel change before the Lifeinvader presentation starts, GTA-73).
    var tvCouch: Bool { context == .onFoot && !promptActive && !scriptMenu && !taxiRide && !helpAsked.isDisjoint(with: [218, 219]) }
    /// Mission triggers latched on (see padState): asked for together with the right stick.
    private var latchedTriggers: Set<Int32> = [], triggerWasPressed: Set<Int32> = []
    private var rightStickWasAsked = false
    /// When each mission button's inputs were last asked for. A mission button stays `missionButtonHold` seconds after
    /// that, and as long as a finger holds it: Eye in the Sky reads RT only while the camera is on a target, so the scan
    /// button came and went with every small camera movement and RT couldn't be held through a scan (GTA-163).
    private var missionAskedAt: [Int32: CFTimeInterval] = [:]
    private static let missionButtonHold: CFTimeInterval = 4
    /// The mission buttons' inputs asked for now or within missionButtonHold, and those of mission buttons held down.
    private var recentMission: Set<Int32> = []
    /// Called every frame with the engine's poll check (PGInputPolledWithin) and its check for inputs scripts read in any
    /// way just now (PGInputReadWithin, a short window).
    func updateMissionInputs(now: CFTimeInterval = CACurrentMediaTime(), read: (Int32) -> Bool = { _ in false }, _ polled: (Int32) -> Bool) {
        let missionInputs = Set(missionButtons.flatMap(\.inputs))
        let next = Set((Array(missionInputs) + [218, 219, 220, 221, 187, 188, 189, 190, 19, 39]).filter(polled)).union(helpAsked)
        let frontendRead = read(187) && read(188) && !gamePhoneOut
        frontendSince = frontendRead ? (frontendSince ?? now) : nil
        let frontend = frontendRead && now - (frontendSince ?? now) >= 0.6
        if helpAsksRightStick != rightStickWasAsked {
            rightStickWasAsked = helpAsksRightStick
            GameFolder.log("Touch layout: the right side is \(rightStickWasAsked ? "the right stick (the help asks for it)" : "the camera again")")
        }
        // Mission buttons show only while the game waits for the player (see shownMissionButtons); a wait that ends
        // forgets what it asked for, so the next one starts without its buttons.
        if context == .menu || phoneDock || !(promptActive || hints.helpShown || scriptMenu) { missionAskedAt.removeAll() }
        else { for input in next.intersection(missionInputs) { missionAskedAt[input] = now } }
        var recent = Set(missionAskedAt.filter { now - $0.value < Self.missionButtonHold }.keys)
        for mission in missionButtons where mission.button.pressed { recent.insert(mission.input) }
        if next != polledMission || recent != recentMission || frontend != frontendScreen {
            let menuWas = scriptMenu
            polledMission = next; recentMission = recent; frontendScreen = frontend; updateVisibility(); setNeedsLayout()
            if scriptMenu != menuWas { GameFolder.log("Touch layout: script menu \(scriptMenu ? "on" : "off") (inputs \(next.sorted().map(String.init).joined(separator: ","))\(frontend ? "; a script screen reads the frontend D-pad" : ""))") }
        }
    }
    /// The mission buttons to show now: polled, and not already covered by a button on screen.
    private func shownMissionButtons(besides list: [ControlButton]) -> [ControlButton] {
        // Only while the game waits for the player: the prompt layout (control off outside cutscenes) or
        // a help message on screen. Scripts also poll inputs they don't ask for, and those must not
        // bring up buttons in normal play.
        if context == .menu || phoneDock || !(promptActive || hints.helpShown || scriptMenu) { return [] }
        var covered: Set<Int32> = []
        if list.contains(where: { $0 === accept }) { covered.insert(223) }
        if list.contains(where: { $0 === back }) { covered.insert(225) }
        if list.contains(where: { $0 === promptOption }) { covered.insert(224) }
        if list.contains(where: { $0 === up }) { covered.formUnion([232, 233, 234]) }		// the D-pad is on screen
        if list.contains(where: { $0 === enter }) { covered.insert(75) }		// Enter/Exit sends Y
        let both = polledMission.isSuperset(of: [228, 229]) || polledMission.isSuperset(of: [207, 208])
        if both { covered.formUnion([228, 229]) }
        let help = helpAsked
        let asked = { (m: MissionButton) in m.helpOnly ? help.contains(m.input) : m.inputs.contains { self.recentMission.contains($0) && !covered.contains($0) } }
        return (both ? [bothTriggers] : []) + missionButtons.filter { asked($0) && !covered.contains($0.input) }.map(\.button)
    }
    private let tabLeft = ControlButton("tabLeft", icon: "tab_left", label: AppLanguage.choose("Previous tab"))
    private let tabRight = ControlButton("tabRight", icon: "tab_right", label: AppLanguage.choose("Next tab"))

    private var allButtons: [ControlButton] {
        missionButtons.map(\.button) + [fire, aim, leftFire, jump, sprint, enter, weapons, reload, cover, crouch, switcher, special, interact, detonate, zoomIn, zoomOut,
         weaponPrev, weaponNext, gas, brake, handbrake, bikeJump, steerLeft, steerRight, driveBy, driveAim, duck, horn, lookBack,
         vehicleWeapon, towHook, towArmUp, towArmDown, roof, detachTrailer, dive, surface, airFire, gear, throttleUp, throttleDown, yawLeft, yawRight, camera, phone, pause, settings, mods, lights, radio, nextSong,
         up, down, left, right, accept, back, phoneOption, taxiHurry, taxiStop, tabLeft, tabRight, promptOption, bothTriggers] + modButtons.map(\.button)
    }

    // MARK: Mod buttons (GTA-180)

    /// The player's on-screen buttons for script mods' keys (Settings › Mods › a script mod): each holds its keys down
    /// while touched. Shown while script mods run, always, in any vehicle or in one vehicle model.
    private var modButtons: [(button: ControlButton, spec: ModButton)] = []
    private var modButtonsObserver: NSObjectProtocol?
    private func reloadModButtons() {
        for (button, _) in modButtons { button.removeFromSuperview() }
        modButtons = ModButton.all.map { spec in
            let button = ControlButton("mod." + spec.id, icon: spec.icon, label: spec.label)
            button.alpha = 0
            addSubview(button)
            return (button, spec)
        }
        updateVisibility()
    }
    private func modButtonShows(_ spec: ModButton) -> Bool {
        switch spec.show {
        case .always: return true
        case .vehicle: return context != .onFoot
        case .model: return context != .onFoot && (editing || hints.vehicleModel == spec.model)
        }
    }
    /// Presses or releases a mod button's keys (as the mod sees them: a key another one answers is pressed as that one).
    private func setModKeys(_ button: ControlButton, _ down: Bool) {
        guard let spec = modButtons.first(where: { $0.button === button })?.spec else { return }
        for key in down ? spec.keys : spec.keys.reversed() { PGAsiSetKey(Int32(ModKeyRemap.pressed(mod: spec.mod, modKey: key)), down) }
    }
    /// Refresh accessibility names for the active language without recreating controls.
    func refreshLanguage() {
        let labels: [String: String] = [
            "fire": AppLanguage.choose("Fire"),
            "aim": AppLanguage.choose("Aim"),
            "leftFire": AppLanguage.choose("Fire, left hand"),
            "jump": AppLanguage.choose("Jump"),
            "sprint": AppLanguage.choose("Sprint"),
            "enter": AppLanguage.choose("Enter vehicle"),
            "weapons": AppLanguage.choose("Weapon wheel"),
            "reload": AppLanguage.choose("Reload"),
            "cover": AppLanguage.choose("Take cover"),
            "crouch": AppLanguage.choose("Stealth"),
            "switchCharacter": AppLanguage.choose("Switch character"),
            "gas": AppLanguage.choose("Gas"),
            "brake": AppLanguage.choose("Brake and reverse"),
            "handbrake": AppLanguage.choose("Handbrake"),
            "driveBy": AppLanguage.choose("Aim and shoot from vehicle"),
            "horn": AppLanguage.choose("Horn"),
            "lookBack": AppLanguage.choose("Look behind"),
            "vehicleWeapon": AppLanguage.choose("Next vehicle weapon"),
            "towHook": AppLanguage.choose("Release tow hook"),
            "roof": AppLanguage.choose("Raise or lower the roof"),
            "detachTrailer": AppLanguage.choose("Detach trailer"),
            "nextSong": AppLanguage.choose("Next song"),
            "towArmUp": AppLanguage.choose("Raise tow arm"),
            "towArmDown": AppLanguage.choose("Lower tow arm"),
            "dive": AppLanguage.choose("Dive"),
            "surface": AppLanguage.choose("Surface"),
            "airFire": AppLanguage.choose("Fire aircraft weapon"),
            "gear": AppLanguage.choose("Landing gear"),
            "yawRight": AppLanguage.choose("Rudder right"),
            "yawLeft": AppLanguage.choose("Rudder left"),
            "throttleDown": AppLanguage.choose("Throttle down, descend"),
            "throttleUp": AppLanguage.choose("Throttle up, climb"),
            "weaponNext": AppLanguage.choose("Next weapon in this slot"),
            "weaponPrev": AppLanguage.choose("Previous weapon in this slot"),
            "zoomOut": AppLanguage.choose("Zoom out"),
            "zoomIn": AppLanguage.choose("Zoom in"),
            "special": AppLanguage.choose("Special ability"),
            "camera": AppLanguage.choose("Change camera"),
            "phone": AppLanguage.choose("Phone"),
            "pause": AppLanguage.choose("Pause menu"),
            "settings": AppLanguage.choose("Settings"),
            "mods": AppLanguage.choose("Mods"),
            "lights": AppLanguage.choose("Headlights"),
            "radio": AppLanguage.choose("Radio"),
            "up": AppLanguage.choose("Up"),
            "down": AppLanguage.choose("Down"),
            "left": AppLanguage.choose("Left"),
            "right": AppLanguage.choose("Right"),
            "accept": AppLanguage.choose("Select"),
            "back": AppLanguage.choose("Back"),
            "tabLeft": AppLanguage.choose("Previous tab"),
            "tabRight": AppLanguage.choose("Next tab"),
            "steer_left": AppLanguage.choose("Steer left"),
            "steer_right": AppLanguage.choose("Steer right"),
            "phone_option": AppLanguage.choose("Phone options"),
            "taxi_hurry": AppLanguage.choose("Hurry up"),
            "taxi_stop": AppLanguage.choose("Stop the taxi"),
            "prompt_option": AppLanguage.choose("Skip mission or other option (X)"),
            "driveAim": AppLanguage.choose("Aim from the vehicle"),
            "duck": AppLanguage.choose("Duck"),
            "script_ltrt": AppLanguage.choose("LT and RT together (tap to hold, tap again to let go)"),
        ]
        for button in allButtons { if let label = labels[button.name] { button.accessibilityLabel = label } }
        updateVisibility()
    }

    private var visible: [ControlButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addSubview(moveStick)
        addSubview(rightStick)
        addSubview(lookStick)
        for button in allButtons { button.alpha = 0; addSubview(button) }
        for pedal in [gas, brake, dive, surface, throttleUp, throttleDown] { pedal.isPedal = true }
        for button in [gas, brake, handbrake, dive, surface, throttleUp, throttleDown] { button.slideTarget = true }
        reloadModButtons()
        modButtonsObserver = NotificationCenter.default.addObserver(forName: ModButton.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reset(); self?.reloadModButtons()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Context

    func updateContext(vehicle: UInt32, pauseMenu: Bool) {
        let next = ControlContext(vehicle: vehicle, pauseMenu: pauseMenu)
        guard next != context else { return }
        // A held action must not turn into a different action on entry/exit,
        // but a thumb on the move stick keeps steering the new vehicle.
        let carryStick = !next.flying && next != .menu && (next.driving != context.driving)
        reset(publish: false, keepStickFinger: carryStick)
        context = next
        if next == .menu || !gamePhoneOut { phoneDock = false }
        updateVisibility()
        setNeedsLayout()
    }

    private func computeVisible() -> [ControlButton] {
        if padScheme && editing { return modButtons.filter { modButtonShows($0.spec) }.map(\.button) }
        if controllerOnly && !editing {
            let ownMods = padScheme && modsActive && context != .menu ? modButtons.filter { modButtonShows($0.spec) }.map(\.button) : []
            return (modsActive ? [settings, mods] : [settings]) + ownMods
        }
        var list = baseVisible()
        if (modsActive || editing) && list.contains(settings) { list.append(mods) }
        if !editing { list += shownMissionButtons(besides: list) }
        let playing = !phoneDock && !promptActive && context != .menu
        // A prompt that waits for a character switch gets the switch button (a tap is the game's quick switch). In
        // Chop the camera moves to Chop with player control off ("SWITCH back to Franklin to search boxcars"), so the
        // prompt layout showed and nothing said that D-pad down goes back (report 956). The game reads INPUT_CHARACTER_WHEEL
        // (19) then; on Mission failed it does too, but that pauses the game. Playing as Chop counts as well (GTA-81).
        let switchAsked = promptActive && !phoneDock &&
            (hints.pedModel == ControlStyle.chop || (polledMission.contains(19) && !gamePaused))
        if characterSwitchEnabled, playing || switchAsked, context != .menu { list.append(switcher) }
        if (modsActive && playing) || (editing && context != .menu) { list += modButtons.filter { modButtonShows($0.spec) }.map(\.button) }
        // In the layout editor every situational button shows, so it can be placed.
        if editing && !context.flying {
            list += context == .onFoot ? [special, interact, detonate, zoomIn, zoomOut, weaponPrev, weaponNext, leftFire] : [special, interact, detonate, towHook, towArmUp, towArmDown, roof]
            return list
        }
        // Situational buttons, shown only while they do something (engine state, PGReadControlHints).
        if playing && !context.flying {
            if hints.specialShown && !aimActive { list.append(special) }
            if hints.canDetonate || hints.helpDetonate { list.append(detonate) }
            // "Press D-pad right to ..." prompts come in vehicles too (Los Santos Customs, garages).
            if asksInteract && !aimActive { list.append(interact) }
            if context == .onFoot && aimActive { list += [zoomIn, zoomOut] }
            if context == .onFoot && has(isWeaponWheel) { list += [weaponPrev, weaponNext] }
            // The hook and the roof are D-pad right like the headlights, so they get their own buttons.
            if context == .car && ControlStyle.towTrucks.contains(hints.vehicleModel) { list.append(towHook) }
            if context == .car && ControlStyle.armVehicles.contains(hints.vehicleModel) { list += [towArmUp, towArmDown] }
            if context == .car && ControlStyle.convertibles.contains(hints.vehicleModel) { list.append(roof) }
            if context == .car && hints.trailerAttached { list.append(detachTrailer) }
        }
        // In aircraft too: Eye in the Sky's "Press ~INPUT_SCRIPT_PAD_RIGHT~ to toggle the thermal vision mode" comes with
        // player control on in the police helicopter, whose layout had no Interact, and the mission waits for thermal
        // vision before it goes on (GTA-163).
        if playing && context.flying && asksInteract { list.append(interact) }
        if playing && context == .heli && ControlStyle.cargobobs.contains(hints.vehicleModel) { list.append(towHook) }
        if playing && context.driving && hints.selfRadioPlaying { list.append(nextSong) }
        return list
    }

    /// Engine state for the situational buttons; called every frame.
    func updateHints(_ next: PGControlHints) {
        let changed = next.helpShown != hints.helpShown || next.specialShown != hints.specialShown || next.canDetonate != hints.canDetonate || next.helpContext != hints.helpContext
            || next.contextPrompt != hints.contextPrompt || next.helpDetonate != hints.helpDetonate
            || next.vehicleModel != hints.vehicleModel || next.passenger != hints.passenger || next.taxiMenu != hints.taxiMenu || next.phoneBrowser != hints.phoneBrowser
            || next.pedModel != hints.pedModel || next.trailerAttached != hints.trailerAttached || next.selfRadioPlaying != hints.selfRadioPlaying
        if changed || next.specialReady != hints.specialReady || next.specialActive != hints.specialActive || next.radioWheelOpen != hints.radioWheelOpen {
            hintsChanged?("Control hints: special \(next.specialShown ? (next.specialActive ? "active" : next.specialReady ? "ready" : "charging") : "none") \(Int(next.specialFill * 100))%, detonate \(next.canDetonate), help \(next.helpShown ? (next.helpContext ? "asks for interact" : "shown") : "none")\(next.contextPrompt ? ", context prompt waiting" : ""), radio wheel \(next.radioWheelOpen ? "open" : "closed"), vehicle model 0x\(String(next.vehicleModel, radix: 16))")
        }
        hints = next
        special.active = next.specialActive
        special.setProgress(next.specialActive ? 0 : CGFloat(next.specialFill))
        if changed { updateVisibility() }
    }
    /// The game waits for the context input (D-pad right, the interact button): a help names it, or a script's context
    /// prompt is registered whose help text the game files don't have, such as the car garage's exit (GTA-104).
    private var asksInteract: Bool { hints.helpContext || hints.contextPrompt }
    /// A taxi ride with the destination menu (the taxiservice script runs, the player is a passenger).
    private var taxiRide: Bool { hints.passenger && hints.taxiMenu && hints.vehicleModel == ControlStyle.taxi }
    private func baseVisible() -> [ControlButton] {
        let utility: [ControlButton] = context.driving ? [radio, lights, camera, phone, pause, settings] : [camera, phone, pause, settings]
        let steering: [ControlButton] = GameSettings.shared.steeringButtons ? [steerLeft, steerRight] : []
        if context == .menu { return [pause, settings, up, down, left, right, accept, back, tabLeft, tabRight] }
        if phoneDock { return [camera, phone, pause, settings, up, down, left, right, accept, back, phoneOption] }
        // A prompt (Mission failed, warning screens) waits for Accept/Back; play controls do nothing then.
        // Shop menus that lock player control also need the D-pad to move through the items.
        // A prompt that reads the left stick (INPUT_SCRIPT_LEFT_AXIS_X/Y, e.g. the yoga poses) keeps the left
        // side free for the stick: the D-pad sits where the thumb goes.
        // A script menu (shops: barber, clothes, Ammu-Nation, Los Santos Customs) reads the frontend D-pad
        // inputs while player control stays on: it gets the menu layout too, or it can't be used (GTA-43).
        if (promptActive || scriptMenu) && !editing {
            // A prompt that reads either stick (the yoga poses read both, GTA-37): no D-pad under the left
            // thumb; an empty spot on the left is the left stick and on the right the right stick.
            // A shop menu (barber, Los Santos Customs) reads the sticks too, but it moves with the frontend D-pad:
            // it keeps the arrows, or it can't be scrolled on touch (GTA-75).
            // A help that names the script D-pad keeps the arrows though the script reads a stick as well (By the
            // Book's tool cart: "Use the left stick/D-pad and A to pick a torture weapon"); the stick still works on the
            // empty part of the left side.
            // A camera that zooms with INPUT_SNIPER_ZOOM (39) reads the left stick up/down on a controller (standard.meta): the
            // helicopter camera in Eye in the Sky ("Zoom in and out with …", GTA-163) gets the stick, not the D-pad, whose
            // secondary zoom it doesn't read.
            let stick = !polledMission.isDisjoint(with: [218, 219, 220, 221, 39]) && !scriptMenu && helpAsked.isDisjoint(with: [232, 233, 234, 235])
            // A prompt that asks for INPUT_CONTEXT gets the interact button: D-pad right sends it too, but nothing
            // says so, and without the D-pad there was no way at all, e.g. standing up from a safehouse couch where the
            // stick changes the TV channel (GTA-82), or drinking more whiskey at Trevor's (log 602).
            let contextButton: [ControlButton] = asksInteract ? [interact] : []
            return [camera, pause, settings] + (stick ? [] : [up, down, left, right]) + contextButton + [accept, back, promptOption]
        }
        if tvCouch && !editing {
            return [camera, phone, pause, settings, up, down, left, right] + (asksInteract ? [interact] : [])
        }
        // A taxi ride: the destination menu takes D-pad left/right to change and A to choose.
        if taxiRide && !editing {
            return [camera, phone, pause, settings, radio, left, right, accept, taxiHurry, taxiStop, enter, lookBack]
        }
        switch context {
        case .onFoot:
            return aimActive ? utility + [fire, aim, enter, weapons, reload, cover, leftFire]
                             : utility + [fire, aim, jump, enter, weapons, reload, cover, crouch] + (GameSettings.shared.sprintButton ? [sprint] : [])
        case .car, .boat:
            return utility + [gas, brake, handbrake, enter, driveBy, driveAim, duck, horn, lookBack, vehicleWeapon] + steering
        case .bike:
            return utility + [gas, brake, handbrake, enter, driveBy, driveAim, duck, horn, lookBack] + steering
        case .bicycle:
            return [camera, phone, pause, settings, radio, gas, brake, handbrake, bikeJump, enter, lookBack] + steering
        case .sub:
            return utility + [gas, brake, enter, dive, surface, lookBack] + steering
        // Aircraft weapons are switched by PGNextAircraftWeapon, separately from the radio.
        case .heli:
            return utility + [airFire, vehicleWeapon, enter, throttleUp, throttleDown, yawLeft, yawRight]
        case .plane:
            if planeStickEnabled { return utility + [airFire, vehicleWeapon, gear, enter] }
            return utility + [airFire, vehicleWeapon, gear, enter, throttleUp, throttleDown, yawLeft, yawRight]
        case .menu:
            return []
        }
    }

    /// Game state from the engine (PGGameStatus bits: 1 control off, 2 phone out, 4 cutscene,
    /// 8 warning screen, 16 no player).
    func updateGameState(_ status: UInt32, now: CFTimeInterval = CACurrentMediaTime()) {
        if (status & 32 != 0) != gamePaused { gamePaused = status & 32 != 0; updateVisibility() }
        let phoneOut = status & 2 != 0
        if phoneOut != gamePhoneOut {
            gamePhoneOut = phoneOut
            // A phone the player didn't open (an incoming call) leaves the play controls in place, so the
            // player keeps driving, flying or walking through the call; the Phone button then opens the dock.
            // On foot it used to open the dock by itself, which left no move stick until the call ended (GTA-80).
            let dockWas = phoneDock
            if phoneOut { phoneRequestedAt = nil; lastDockInput = now }
            else if phoneDock { phoneDock = false }
            if context != .menu && phoneDock != dockWas { reset(publish: false) }
            GameFolder.log("Touch layout: phone \(phoneOut ? "out" : "away"), dock \(phoneDock ? "open" : "closed")")
            updateVisibility()
        }
        // Accept/Back prompt: player control off outside cutscenes, a warning screen, or the game paused outside
        // the pause menu (Mission failed: Retry/Exit, with control still on). Held for a moment so brief control
        // locks don't flicker.
        let paused = status & 32 != 0 && context != .menu
        let wanted = status & 16 == 0 && ((status & 1 != 0 && status & 4 == 0) || status & 8 != 0 || paused)
        if wanted { if promptSince == nil { promptSince = now } } else { promptSince = nil }
        let show = wanted && now - (promptSince ?? now) > 0.6
        if show != promptActive {
            promptActive = show
            hintsChanged?("Touch layout: " + (show ? "prompt (Accept/Back)" : "play"))
            reset(publish: false)
            updateVisibility()
            promptInputsLogged = nil
            promptInputsLate = false
        }
        // Diagnostics: a prompt that stays up 3 s logs every input scripts read, so a screen whose buttons do
        // nothing (the street race result screen's Retry/Continue) shows in the log what it waits for. Screens
        // that animate in read more once they settle, so at 10 s the list is logged again if it changed.
        if promptActive, let since = promptSince, now - since > (promptInputsLogged == nil ? 3 : 10), !promptInputsLate {
            let read = (0..<360).filter { PGInputReadWithin(Int32($0), 1500) != 0 }.map(String.init).joined(separator: ",")
            if read != promptInputsLogged { GameFolder.log("Prompt: scripts read inputs \(read.isEmpty ? "none" : read)") }
            if promptInputsLogged != nil { promptInputsLate = true }
            promptInputsLogged = read
        }
    }
    private var promptInputsLogged: String?
    private var promptInputsLate = false
    private var promptButtonsDown: [String] = []
    var showingPrompt: Bool { promptActive }

    /// The saved-layout group for the current controls: on foot, or any vehicle.
    var layoutGroup: String { padScheme ? ControllerPadView.layoutGroup : context == .onFoot ? "foot" : "vehicle" }
    private func hiddenByPlayer(_ button: ControlButton) -> Bool {
        context != .menu && !phoneDock && (ControlsLayout.entry(group: layoutGroup, name: button.name)?.hidden ?? false)
    }

    func updateVisibility() {
        if !planeStickEnabled {
            rightStick.end()
            planeThrottle = 0
            roles = roles.filter { if case .planeStick = $0.value { return false }; return true }
        }
        visible = computeVisible().filter { editing || !hiddenByPlayer($0) }
        // With the phone out, the game's own hints name pad buttons ("Take Photo A", "Exit B", "Send X"): the dock's
        // buttons show those letters then, so players find the camera's shutter and send (TG reports 1061, 1128).
        let letters = phoneDock && gamePhoneOut
        if letters != dockShowsLetters {
            dockShowsLetters = letters
            accept.setIcon(letters ? "script_a" : "accept"); back.setIcon(letters ? "script_b" : "back"); phoneOption.setIcon(letters ? "script_x" : "phone_option")
        }
        let mission = missionButtons.filter { b in visible.contains(where: { $0 === b.button }) }.map(\.button.name).joined(separator: ", ")
        if mission != lastMissionLog { lastMissionLog = mission; hintsChanged?("Mission buttons: " + (mission.isEmpty ? "none" : mission)) }
        let shown = Set(visible.map(ObjectIdentifier.init))
        let opacity = CGFloat(GameSettings.shared.controlOpacity)
        for button in allButtons {
            let isShown = shown.contains(ObjectIdentifier(button))
            var target: CGFloat = isShown ? (button === fire || button === gas ? min(1, opacity + 0.1) : opacity) : 0
            if editing, isShown, hiddenByPlayer(button) { target = 0.3 }
            if abs(button.alpha - target) > 0.01 {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) { button.alpha = target }
            }
            button.isAccessibilityElement = isShown
        }
        weapons.setIcon("weapons")
        enter.accessibilityLabel = context == .onFoot ? AppLanguage.choose("Enter vehicle") : context.flying ? AppLanguage.choose("Hold to exit aircraft") : AppLanguage.choose("Exit vehicle")
        gas.setIcon(context == .bicycle ? "pedal" : "gas")
        setNeedsLayout()
    }

    private var aimActive: Bool { aimToggled }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return }
        let thumbs = Self.thumbArea(safe, phone: phoneScreen)
        let scale = max(0.8, min(1.25, min(thumbs.width / 832, thumbs.height / 407))) * CGFloat(GameSettings.shared.controlScale)
        /// A point in the whole safe area: the top bar, the menu tabs and the player's own layout.
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: safe.minX + fx * safe.width, y: safe.minY + fy * safe.height) }
        /// A point where the thumbs reach (thumbArea): the default places of the play controls.
        func thumb(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: thumbs.minX + fx * thumbs.width, y: thumbs.minY + fy * thumbs.height) }
        func place(_ button: ControlButton, _ fx: CGFloat, _ fy: CGFloat, _ size: CGFloat, whole: Bool = false) {
            let d = max(44, size * scale)
            button.bounds.size = CGSize(width: d, height: d)
            button.center = whole ? point(fx, fy) : thumb(fx, fy)
        }
        func pedal(_ button: ControlButton, _ fx: CGFloat, _ fy: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            button.bounds.size = CGSize(width: w * scale, height: h * scale)
            button.center = thumb(fx, fy)
        }
        moveStick.frame = bounds
        rightStick.frame = bounds
        lookStick.frame = bounds
        lookStick.baseDiameter = 120 * scale; lookStick.travel = 48 * scale
        moveStick.baseDiameter = 120 * scale; moveStick.travel = 48 * scale
        rightStick.baseDiameter = 128 * scale; rightStick.travel = 52 * scale
        rightStick.idleOrigin = planeStickEnabled ? thumb(0.80, 0.60) : nil

        // Utility bar, top centre: rare actions in the hard-to-reach zone.
        let order = [radio, nextSong, lights, camera, phone, pause, settings, mods]
        // With only Settings and Mods showing (GTA-146) they keep their places from the on-foot bar.
        let inBar = controllerOnly && !editing ? [camera, phone, pause, settings] + (modsActive ? [mods] : []) : visible
        let bar = order.filter { inBar.contains($0) }
        for (i, button) in bar.enumerated() {
            let offset = (CGFloat(i) - CGFloat(bar.count - 1) / 2) * 54 * scale / safe.width
            place(button, 0.5 + offset, 0.08, 40, whole: true)
        }

        // On foot: the primary action sits under the resting right thumb.
        place(fire, 0.885, 0.70, 78)
        place(aim, 0.735, 0.76, 62)
        place(jump, 0.80, 0.43, 56)
        place(sprint, 0.70, 0.30, 50)
        place(enter, 0.955, 0.42, 54)
        place(weapons, 0.955, 0.17, 50)
        place(reload, 0.69, 0.50, 50)
        place(cover, 0.60, 0.82, 52)
        place(crouch, 0.58, 0.60, 44)
        place(leftFire, 0.10, 0.36, 58)
        place(switcher, 0.955, 0.295, 46)
        place(special, 0.86, 0.24, 48)
        place(interact, 0.60, 0.38, 52)
        place(detonate, 0.52, 0.68, 48)
        place(zoomIn, 0.66, 0.24, 44)
        place(zoomOut, 0.74, 0.24, 44)
        // In the middle of the weapon wheel, which the game draws at the centre of the screen.
        let centreX = (bounds.midX - safe.minX) / safe.width, centreY = (bounds.midY - safe.minY) / safe.height
        let gap = 34 * scale / safe.width
        place(weaponPrev, centreX - gap, centreY, 50, whole: true)
        place(weaponNext, centreX + gap, centreY, 50, whole: true)

        // Ground vehicles: analog steering on the left, pedals on the right.
        pedal(gas, 0.905, 0.72, 74, 108)
        pedal(brake, 0.775, 0.80, 74, 78)
        place(handbrake, 0.79, 0.52, 56)
        place(steerLeft, 0.08, 0.76, 80)
        place(steerRight, 0.215, 0.76, 80)
        place(driveBy, 0.655, 0.50, 58)
        place(bikeJump, 0.655, 0.50, 58)		// bicycles have no drive-by: the same spot
        place(driveAim, 0.655, 0.71, 50)
        place(duck, 0.555, 0.50, 46)
        place(horn, 0.06, 0.36, 46)
        place(lookBack, 0.155, 0.36, 44)
        place(vehicleWeapon, 0.955, 0.17, 48)
        place(towHook, 0.655, 0.27, 50)
        place(roof, 0.575, 0.27, 50)
        place(detachTrailer, 0.655, 0.27, 50)
        place(towArmUp, 0.575, 0.27, 46)
        place(towArmDown, 0.495, 0.27, 46)
        pedal(surface, 0.655, 0.64, 62, 66)
        pedal(dive, 0.655, 0.84, 62, 66)

        // Aircraft: the left stick flies; the right thumb works throttle pedals and the rudder, and
        // anywhere else on the right looks around.
        place(airFire, 0.80, 0.30, 62)
        place(gear, 0.655, 0.24, 46)
        pedal(throttleUp, 0.905, 0.56, 74, 96)
        pedal(throttleDown, 0.905, 0.85, 74, 64)
        place(yawLeft, 0.655, 0.86, 54)
        place(yawRight, 0.775, 0.86, 54)

        // Menus and the phone: a D-pad on the left, accept/back on the right.
        let stepX = 58 * scale / thumbs.width, stepY = 58 * scale / thumbs.height
        place(up, 0.12, 0.70 - stepY, 52)
        place(down, 0.12, 0.70 + stepY, 52)
        place(left, 0.12 - stepX, 0.70, 52)
        place(right, 0.12 + stepX, 0.70, 52)
        place(accept, 0.905, 0.70, 68)
        place(back, 0.765, 0.84, 56)
        place(phoneOption, 0.765, 0.56, 56)
        place(taxiHurry, 0.765, 0.52, 58)
        place(taxiStop, 0.765, 0.84, 58)
        place(promptOption, 0.765, 0.56, 56)
        // Mission buttons: a row under the top bar, centred, in the order they are listed.
        let mission = ([bothTriggers] + missionButtons.map(\.button)).filter { visible.contains($0) }
        let missionStep = 60 * scale / safe.width
        for (index, button) in mission.enumerated() {
            place(button, 0.5 + (CGFloat(index) - CGFloat(mission.count - 1) / 2) * missionStep, 0.27, 52)
        }
        place(tabLeft, 0.05, 0.12, 46, whole: true)
        place(tabRight, 0.95, 0.12, 46, whole: true)
        // Mod buttons: columns left of centre, clear of the sticks, until the player moves them. With the Controller
        // buttons scheme: rows right of centre, between RB and the right stick, clear of its buttons.
        for (index, button) in modButtons.map(\.button).filter({ visible.contains($0) }).enumerated() {
            if padScheme { place(button, 0.56 + CGFloat(index % 4) * 0.07, 0.26 + CGFloat(index / 4) * 0.12, 46) }
            else { place(button, 0.30 + CGFloat(index / 4) * 0.075, 0.24 + CGFloat(index % 4) * 0.14, 46) }
        }

        // The player's own layout (Edit controls layout): moved and resized controls. Hit areas
        // follow, since touches test each control's frame.
        if context != .menu && !phoneDock {
            for button in visible {
                guard let entry = ControlsLayout.entry(group: layoutGroup, name: button.name) else { continue }
                let size = button.bounds.size
                button.bounds.size = CGSize(width: max(36, size.width * entry.scale), height: max(36, size.height * entry.scale))
                button.center = point(entry.x, entry.y)
            }
        }
        updateHighlight()
    }

    /// Where the play controls' default places go: the whole safe area, except on a phone screen taller than the
    /// iPhone Duo's outer screen (its inner screen, 951×669 points, GTA-185). There they keep the outer screen's 466
    /// points at the bottom, so the thumbs reach them as on a phone; the top bar and the menu tabs stay at the top.
    static func thumbArea(_ safe: CGRect, phone: Bool) -> CGRect {
        let reach: CGFloat = 466
        guard phone, safe.height > reach + 20 else { return safe }
        return CGRect(x: safe.minX, y: safe.maxY - reach, width: safe.width, height: reach)
    }
    private var phoneScreen: Bool {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-window") { return true }   // the Duo's sizes on a bigger simulator
        #endif
        return traitCollection.userInterfaceIdiom == .phone
    }

    // MARK: Layout editor support

    private let highlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.systemYellow.cgColor
        layer.lineWidth = 3
        layer.lineDashPattern = [6, 4]
        return layer
    }()
    private func updateHighlight() {
        if highlightLayer.superlayer == nil { layer.addSublayer(highlightLayer) }
        guard let button = highlighted, visible.contains(where: { $0 === button }) else { highlightLayer.path = nil; return }
        let frame = button.frame.insetBy(dx: -6, dy: -6)
        highlightLayer.path = UIBezierPath(roundedRect: frame, cornerRadius: button.isPedal ? 22 : frame.width / 2).cgPath
    }
    /// The visible control under a point (layout editor).
    func editableButton(at point: CGPoint) -> ControlButton? { button(at: point) }
    func button(named name: String) -> ControlButton? { allButtons.first { $0.name == name } }
    /// A point as a fraction of the safe area (what the saved layout stores).
    func normalized(_ point: CGPoint) -> CGPoint {
        let safe = bounds.inset(by: safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - safe.minX) / safe.width, y: (point.y - safe.minY) / safe.height)
    }
    func clampedToSafeArea(_ point: CGPoint) -> CGPoint {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 24, dy: 24)
        return CGPoint(x: min(max(point.x, safe.minX), safe.maxX), y: min(max(point.y, safe.minY), safe.maxY))
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isHidden { return nil }
        // Controller only: just the shown buttons take touches (GTA-146).
        return controllerOnly && !editing && button(at: point) == nil ? nil : self
    }

    // MARK: Touches

    private func button(at point: CGPoint, slidingOnly: Bool = false) -> ControlButton? {
        // Nearest centre wins where the enlarged hit areas overlap.
        visible.filter { (!slidingOnly || $0.slideTarget) && $0.contains(point: point, slop: $0 === fire || $0.isPedal ? 10 : 4) }
            .min { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) }
    }

    private func has(_ check: (Role) -> Bool) -> Bool { roles.values.contains(where: check) }
    private func isStick(_ role: Role) -> Bool { if case .moveStick = role { return true }; if case .steer = role { return true }; return false }
    private func isWeaponWheel(_ role: Role) -> Bool { if case .weaponWheel = role { return true }; return false }
    private func isLook(_ role: Role) -> Bool { if case .look = role { return true }; return false }
    private func isPlaneStick(_ role: Role) -> Bool { if case .planeStick = role { return true }; return false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { return }
        for touch in touches { beginTouch(ObjectIdentifier(touch), at: touch.location(in: self)) }
        publish()
    }

    // A finger by its identity, so the debug channel's synthetic fingers (debugTouch) take the same path.
    private func beginTouch(_ id: ObjectIdentifier, at point: CGPoint) {
        // A quick tap on the game's minimap (wherever Settings put it) opens the full-screen map; a drag
        // that starts there still moves the stick.
        if context != .menu, !phoneDock, button(at: point) == nil,
           MinimapGeometry.rect(Self.minimapLayout, in: bounds).insetBy(dx: -8, dy: -8).contains(point) {
            mapTaps[id] = (CACurrentMediaTime(), point)
        }
        let safe = bounds.inset(by: safeAreaInsets)
        let leftZone = point.x < safe.minX + safe.width * 0.45
        if let button = button(at: point) {
            press(button, id: id, at: point)
        } else if context == .menu, leftZone {
            // Pause menu: the left side is the controller's left stick, which moves the map
            // cursor so any spot can get a waypoint.
            if !has(isStick) { roles[id] = .moveStick; moveStick.begin(at: point) }
        } else if context == .menu || phoneDock {
            if !has(isLook) { roles[id] = .look; lookStick.begin(at: point) }
        } else if planeStickEnabled && !leftZone {
            if !has(isPlaneStick) { roles[id] = .planeStick; rightStick.begin(at: point) }
        } else if context.flying, leftZone {
            if !has(isStick) { roles[id] = .moveStick; moveStick.begin(at: point) }
        } else if leftZone, context.driving, GameSettings.shared.steeringButtons {
            // Steering buttons replace the steering stick; the rest of the left side does nothing.
        } else if leftZone {
            // In swipe modes the entire left side is reserved for movement;
            // even a second left finger must not become a camera gesture.
            if point.y > safe.minY + safe.height * 0.2, !has(isStick) {
                roles[id] = context.driving ? .steer : .moveStick
                moveStick.begin(at: point)
            }
        } else if !has(isLook) {
            roles[id] = .look
            if !swipeCameraEnabled { lookStick.begin(at: point) }
        }
    }

    private func press(_ button: ControlButton, id: ObjectIdentifier, at point: CGPoint) {
        let now = CACurrentMediaTime()
        haptics.impactOccurred(intensity: 0.6)
        button.setPressed(true)
        roles[id] = .button(button)
        setModKeys(button, true)
        defer { if case .fireLook = roles[id] { dragOrigins[id] = (point, point) } }
        switch button {
        case weapons:
            clearCameraTravel()
            roles[id] = .weaponWheel(start: point, current: point)
            updateVisibility()
        case radio where context.driving:
            clearCameraTravel()
            roles[id] = .radioWheel(start: point, current: point, since: now)
        case special:
            // L3 + R3 together, fresh presses within the game's 100 ms window; again to stop.
            pulse([.l3, .r3], for: 0.13)
        case switcher:
            clearCameraTravel()
            roles[id] = .characterWheel(start: point, current: point)
        case fire, driveBy:
            roles[id] = .fireLook(button)
            fireStartedAt = now
            lastFireTime = now
        case leftFire:
            roles[id] = .fireLook(button)
            lastFireTime = now
        case sprint:
            sprintLatched.toggle()
        case aim:
            // Aim is a toggle, so the same thumb is free for Fire. Keeping
            // the thumb down and dragging aims, like dragging from Fire.
            aimToggled.toggle()
            aim.active = aimToggled
            roles[id] = .fireLook(button)
            updateVisibility()
        case enter where context.flying:
            exitHoldStart = now
        case phone:
            if gamePhoneOut && !phoneDock {
                // A phone the player didn't open (a call): the dock (answer, hang up) opens on request.
                phoneDock = true
                phoneOpensDock = true
            } else if gamePhoneOut {
                // The phone is out: this button now puts it away (Back), the dock follows the game.
                phoneRequestedAt = nil
            } else {
                // Every tap asks the game for the phone (D-pad up) until it comes out: missions often
                // ignore the first press, and a second tap used to close the dock instead of asking again,
                // so players had to spam the button at the bomb detonation step (GTA-54). Without a
                // phone the dock closes by itself after a moment.
                phoneDock = true
                phoneRequestedAt = now
            }
            lastDockInput = now
            updateVisibility()
        case settings:
            DispatchQueue.main.async { self.openSettings?() }
        case mods:
            DispatchQueue.main.async { self.openMods?() }
        case vehicleWeapon where context.flying:
            // INPUT_VEH_FLY_SELECT_NEXT_WEAPON shares D-pad left with the radio (a tap changes the
            // station), so the weapon is switched directly instead.
            PGNextAircraftWeapon()
        case roof:
            // INPUT_VEH_ROOF is D-pad right held (a short press is the headlights).
            pulse(.right, for: 0.8)
        case up, down, left, right, accept, back:
            lastDockInput = now
        default:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { moveTouch(ObjectIdentifier(touch), to: touch.location(in: self), previous: touch.previousLocation(in: self)) }
        publish()
    }

    private func moveTouch(_ id: ObjectIdentifier, to point: CGPoint, previous: CGPoint) {
        if let tap = mapTaps[id], hypot(point.x - tap.at.x, point.y - tap.at.y) > 12 { mapTaps[id] = nil }
        guard let role = roles[id] else { return }
        switch role {
        case .moveStick:
            moveStick.move(to: point)
        case .steer:
            // Up/down tilts a car in the air and leans a bike.
            moveStick.move(to: point)
        case .radioWheel(let start, _, let since):
            roles[id] = .radioWheel(start: start, current: point, since: since)
        case .planeStick:
            rightStick.move(to: point)
            planeThrottle = max(-1, min(1, planeThrottle - (point.y - previous.y) / (rightStick.travel * 2)))
        case .look:
            if swipeCameraEnabled {
                trackCameraSwipe(from: previous, to: point)
            } else {
                lookStick.move(to: point)
            }
        case .fireLook(let button):
            if button !== leftFire { trackCameraSwipe(from: previous, to: point) }
            if let origin = dragOrigins[id] { dragOrigins[id] = (origin.start, point) }
        case .weaponWheel(let start, _):
            roles[id] = .weaponWheel(start: start, current: point)
        case .characterWheel(let start, _):
            roles[id] = .characterWheel(start: start, current: point)
        case .button(let button):
            // Pedals: a finger may roll from one to another without lifting.
            if button.slideTarget, !button.contains(point: point, slop: 10),
               let next = self.button(at: point, slidingOnly: true), next !== button {
                button.setPressed(false)
                next.setPressed(true)
                haptics.impactOccurred(intensity: 0.4)
                roles[id] = .button(next)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { endTouch(ObjectIdentifier(touch)) }
        publish()
    }

    private func endTouch(_ id: ObjectIdentifier) {
        if let tap = mapTaps.removeValue(forKey: id), CACurrentMediaTime() - tap.since < 0.3 { openFullMap() }
        guard let role = roles.removeValue(forKey: id) else { return }
        dragOrigins[id] = nil
        switch role {
        case .moveStick, .steer: moveStick.end(); sprintSince = nil; sprintLatched = false
        case .planeStick: rightStick.end()
        case .look: lookStick.end()
        case .weaponWheel: weapons.setPressed(false); updateVisibility()
        case .radioWheel(_, _, let since):
            radio.setPressed(false)
            // Released quickly without picking: a tap, the next station.
            if CACurrentMediaTime() - since < 0.25 { pulse(.left, for: 0.1) }
        case .characterWheel: switcher.setPressed(false)
        case .fireLook(let button):
            button.setPressed(false)
            if button === fire || button === driveBy { fireStartedAt = nil }
            if button !== aim { lastFireTime = CACurrentMediaTime() }
        case .button(let button):
            button.setPressed(false)
            setModKeys(button, false)
            if button === enter { exitHoldStart = nil; enter.setProgress(0) }
        }
    }

    private func publish() { inputChanged?() }

    private func pulse(_ buttons: PadButtons, for duration: CFTimeInterval) {
        pulses.append((buttons, CACurrentMediaTime() + duration))
    }

    /// Where the game draws the minimap this session (GameSettings at engine start, GTA-131).
    static var minimapLayout: (dx: Double, dy: Double, scale: Double) = (0, 0, 1)
    private var mapTaps: [ObjectIdentifier: (since: CFTimeInterval, at: CGPoint)] = [:]
    private var fullMapRequestedAt: CFTimeInterval?
    /// Start opens the pause menu on its Map tab; once the menu takes input, A makes the map full screen.
    private func openFullMap() {
        guard fullMapRequestedAt == nil else { return }
        fullMapRequestedAt = CACurrentMediaTime()
        pulse(.start, for: 0.12)
        hintsChanged?("Minimap tapped: opening the full-screen map.")
    }
    private func advanceFullMap(_ now: CFTimeInterval) {
        guard let since = fullMapRequestedAt else { return }
        if context == .menu && now - since > 1.5 { pulse(.a, for: 0.12); fullMapRequestedAt = nil }
        else if now - since > 5 { fullMapRequestedAt = nil }
    }
    /// Pinch on the full-screen map: mouse-wheel notches, which zoom the PC game's map (GTA-105).
    private lazy var mapPinch: UIPinchGestureRecognizer = {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(mapPinched(_:)))
        pinch.isEnabled = false
        addGestureRecognizer(pinch)
        return pinch
    }()
    private var pinchNotchScale: CGFloat = 1
    @objc private func mapPinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: pinchNotchScale = 1
        case .changed:
            // One notch for every 15% of pinch: out zooms in (wheel up), in zooms out.
            while gesture.scale > pinchNotchScale * 1.15 { PGMouseWheel(1); pinchNotchScale *= 1.15 }
            while gesture.scale < pinchNotchScale / 1.15 { PGMouseWheel(-1); pinchNotchScale /= 1.15 }
        default: break
        }
    }

    func reset(publish: Bool = true, keepStickFinger: Bool = false) {
        clearCameraTravel()
        if mouseButtons != 0 { mouseButtons = 0; PGMouseInput(0, 0, 0) }
        if shiftHeld { shiftHeld = false; PGSetKey(0x10, false); PGSetKey(0xA0, false) }
        rightStick.end()
        planeThrottle = 0
        for (id, role) in roles {
            switch role {
            case .moveStick, .steer:
                if keepStickFinger { roles[id] = context.driving ? .moveStick : .steer; continue }
                moveStick.end()
            case .planeStick: rightStick.end()
            case .button(let button), .fireLook(let button): button.setPressed(false); setModKeys(button, false)
            case .radioWheel: radio.setPressed(false)
            case .weaponWheel: weapons.setPressed(false)
            case .characterWheel: switcher.setPressed(false)
            case .look: lookStick.end()
            }
            roles[id] = nil
        }
        aimToggled = false; aim.active = false
        fireStartedAt = nil; exitHoldStart = nil
        enter.setProgress(0)
        sprintSince = nil; moveStick.sprinting = false; sprintLatched = false
        dragOrigins.removeAll()
        if publish { self.publish() }
    }

    // MARK: Output

    /// Whether the player is aiming; gyro aim runs only then by default.
    var aiming: Bool { aimActive || fire.pressed || leftFire.pressed || driveBy.pressed }
    /// The plane's right thumb controls throttle/rudder rather than gyro aiming.
    var flyingWithRightStick: Bool { has(isPlaneStick) }

    /// The current controller state. `elapsed` turns finger travel into a
    /// stick deflection, so the camera turns about as far as the finger moves.
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// Test (PG_TEST_PRESS="driveAim@50-70,driveBy@72-74"): holds named buttons in those windows (seconds after
    /// WORLD_READY), as a finger would, to check what a button does in the game.
    func applyTestPresses(sinceWorld seconds: Double) {
        guard let spec = ProcessInfo.processInfo.environment["PG_TEST_PRESS"] else { return }
        // A button may be listed more than once ("script_rt@46-46.4,script_rt@77-77.4"): it's down while any entry is.
        var down: [String: Bool] = [:]
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: "@"), times = parts.count == 2 ? parts[1].split(separator: "-").compactMap { Double($0) } : []
            guard times.count == 2 else { continue }
            down[String(parts[0]), default: false] = down[String(parts[0]), default: false] || (seconds >= times[0] && seconds < times[1])
        }
        for (name, on) in down {
            guard let button = allButtons.first(where: { $0.name == name }) else { continue }
            if button.pressed != on { button.setPressed(on); GameFolder.log("TEST: \(button.name) \(on ? "pressed" : "released") at \(Int(seconds)) s") }
        }
    }

    /// Debug channel (DebugChannel.swift): fingers that take the real touch path (beginTouch, moveTouch,
    /// endTouch), numbered by the caller. Points are in this view's coordinates.
    private var debugFingers: [Int: (token: NSObject, point: CGPoint)] = [:]
    func debugTouch(finger: Int, phase: UITouch.Phase, at point: CGPoint?) {
        switch phase {
        case .began:
            if let old = debugFingers.removeValue(forKey: finger) { endTouch(ObjectIdentifier(old.token)) }
            guard let point, !editing else { break }
            let token = NSObject()
            debugFingers[finger] = (token, point)
            beginTouch(ObjectIdentifier(token), at: point)
        case .moved:
            guard let point, let down = debugFingers[finger] else { break }
            debugFingers[finger] = (down.token, point)
            moveTouch(ObjectIdentifier(down.token), to: point, previous: down.point)
        default:
            if let old = debugFingers.removeValue(forKey: finger) { endTouch(ObjectIdentifier(old.token)) }
        }
        publish()
    }

    /// The layout as the player sees it, for the debug channel: centres and sizes are fractions of the view.
    func debugState() -> [String: Any] {
        let size = bounds.size
        func frame(_ view: UIView) -> [Double] {
            [view.frame.midX / size.width, view.frame.midY / size.height, view.frame.width / size.width, view.frame.height / size.height].map { (Double($0) * 1000).rounded() / 1000 }
        }
        let roleNames = roles.values.map { role -> String in
            switch role {
            case .button(let button): return "button:\(button.name)"
            case .fireLook(let button): return "fireLook:\(button.name)"
            default: return String("\(role)".prefix { $0 != "(" })
            }
        }
        return [
            "context": "\(context)", "prompt": promptActive, "scriptMenu": scriptMenu, "phoneDock": phoneDock, "gamePhoneOut": gamePhoneOut,
            "aim": aimToggled, "sprintLatched": sprintLatched, "roles": roleNames,
            "help": hints.helpShown, "helpInputs": hints.helpInputs, "pedModel": hints.pedModel, "vehicleModel": hints.vehicleModel,
            "trailer": hints.trailerAttached, "helpExit": hints.helpExit,
            // The inputs scripts polled (the layouts follow these) and read in any way, in the last 0.7 s (GTA-163).
            "polled": (0..<400).filter { PGInputPolledWithin(Int32($0), 700) != 0 }, "read": (0..<400).filter { PGInputReadWithin(Int32($0), 700) != 0 },
            "missionPolled": polledMission.sorted(), "missionRecent": recentMission.sorted(),
            "visible": visible.map { ["name": $0.name, "at": frame($0), "pressed": $0.pressed] as [String: Any] },
            "size": [Double(size.width), Double(size.height)],
        ]
    }
    func debugButton(named name: String) -> CGPoint? {
        visible.first { $0.name == name }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }
    #endif

    func padState(elapsed: Double) -> PGPadState {
        var state = PGPadState()
        var held = PadButtons()
        let now = CACurrentMediaTime()
        flushCameraTravel()

        // Camera stick: holding the thumb off-centre keeps turning. Drags from
        // Aim/Fire count the same way, measured from where they pressed.
        var look = has(isLook) ? lookStick.value : .zero
        for (_, origin) in dragOrigins {
            let travel = lookStick.travel
            var v = CGPoint(x: (origin.current.x - origin.start.x) / travel, y: -(origin.current.y - origin.start.y) / travel)
            let length = hypot(v.x, v.y)
            if length > 1 { v.x /= length; v.y /= length }
            if hypot(v.x, v.y) > hypot(look.x, look.y) { look = v }
        }
        if !swipeCameraEnabled {
            let speed = CGFloat(aimActive ? GameSettings.shared.aimSensitivity : GameSettings.shared.lookSensitivity)
            (state.rightX, state.rightY) = Self.cameraStick(look, speed: speed)
        }

        switch context {
        case .onFoot:
            state.leftX = Float(moveStick.value.x); state.leftY = Float(moveStick.value.y)
            // The Sprint button presses A while held (also opens the parachute and swims faster).
            if sprint.pressed { held.insert(.a) }
            // Sprint: the Sprint button while moving, or the stick held at its edge.
            // Sprinting is tapping A, as on a controller: holding it only jogs (simulator: holding A about
            // 4 m/s, taps every 0.3 s 5.8 m/s; GTA-46).
            let sprintTap = { () -> Bool in self.sprintClock += elapsed; return self.sprintClock.truncatingRemainder(dividingBy: 0.3) < 0.13 }
            // With the Sprint button on, sprinting is the button's: the stick's edge doesn't sprint and the stick
            // doesn't turn blue (the button lights up instead).
            let sprintByButton = GameSettings.shared.sprintButton
            if sprintLatched && !promptActive && hypot(moveStick.value.x, moveStick.value.y) > 0.2 {
                if sprintTap() { held.insert(.a) }
                moveStick.sprinting = !sprintByButton
            } else if !sprintByButton && hypot(moveStick.value.x, moveStick.value.y) > 0.92 && !promptActive {
                // (Not in a prompt: holding a yoga pose at the stick's edge mustn't tap A.)
                if sprintSince == nil { sprintSince = now; sprintClock = 0 }
                if now - (sprintSince ?? now) > 0.25 { if sprintTap() { held.insert(.a) }; moveStick.sprinting = true }
            } else { sprintSince = nil; sprintClock = 0; moveStick.sprinting = false }
            let firing = fire.pressed || leftFire.pressed
            if firing { lastFireTime = now }
            if aimToggled && moveStick.sprinting {
                aimToggled = false; aim.active = false; updateVisibility()
            }
            let fireAims = GameSettings.shared.fireAlsoAims
            if aimActive || (firing && fireAims) { state.leftTrigger = 1 }
            if firing {
                // When Fire also aims, give the lock-on a moment before the first shot.
                let lockDelay = !aimActive && fireAims && fire.pressed ? 0.09 : 0
                if now - (fireStartedAt ?? 0) >= lockDelay || leftFire.pressed { state.rightTrigger = 1 }
            }
            if jump.pressed { held.insert(.x) }
            if enter.pressed { held.insert(.y) }
            if reload.pressed { held.insert(.b) }
            if cover.pressed { held.insert(.r1) }
            if crouch.pressed { held.insert(.l3) }
            if interact.pressed { held.insert(.right) }
            if zoomIn.pressed { held.insert(.up) }
            if zoomOut.pressed { held.insert(.down) }
            // With the weapon wheel open, D-pad left/right step through the weapons in a slot.
            if weaponPrev.pressed { held.insert(.left) }
            if weaponNext.pressed { held.insert(.right) }
            for role in roles.values {
                guard case .weaponWheel(let start, let current) = role else { continue }
                // Hold the wheel button; the same finger points at a slot.
                held.insert(.l1)
                let d = CGPoint(x: current.x - start.x, y: current.y - start.y), length = hypot(d.x, d.y)
                state.rightX = length > 24 ? Float(d.x / length) : 0
                state.rightY = length > 24 ? Float(-d.y / length) : 0
            }
        case .car, .bike, .bicycle, .boat, .sub:
            let steer = GameSettings.shared.steeringButtons ? (steerRight.pressed ? 1 : 0) - (steerLeft.pressed ? 1 : 0) : moveStick.value.x
            state.leftX = Float(copysign(pow(abs(steer), 1.3), steer))
            let tilt = moveStick.value.y
            if context == .bike || context == .bicycle {
                state.leftY = Float(tilt)
            } else {
                // Cars, boats and subs: up/down pitches in the air or underwater. A wide dead zone keeps
                // sloppy steering from tilting.
                state.leftY = abs(tilt) < 0.35 ? 0 : Float(copysign((abs(tilt) - 0.35) / 0.65, tilt))
            }
            if context == .bicycle {
                // Pedal by tapping A at a steady cadence while Gas is held.
                if gas.pressed {
                    pedalClock += elapsed
                    if pedalClock.truncatingRemainder(dividingBy: 0.3) < 0.15 { held.insert(.a) }
                } else { pedalClock = 0 }
                if brake.pressed { state.leftTrigger = 1 }
                if handbrake.pressed { state.rightTrigger = 1 }
                if bikeJump.pressed { held.insert(.r1) }
            } else {
                if gas.pressed { state.rightTrigger = 1 }
                if brake.pressed { state.leftTrigger = 1 }
                if handbrake.pressed { held.insert(.r1) }
            }
            if driveBy.pressed {
                // Aim with L1; R1 shoots while aiming.
                held.insert(.l1)
                if now - (fireStartedAt ?? now) > 0.12 { held.insert(.r1) }
            }
            if enter.pressed { held.insert(.y) }
            if driveAim.pressed { held.insert(.l1) }
            if duck.pressed && context != .bicycle { held.insert(.a) }
            if interact.pressed { held.insert(.right) }
            if horn.pressed { held.insert(.l3) }
            if lookBack.pressed { held.insert(.r3) }
            if vehicleWeapon.pressed { held.insert(.x) }
            if dive.pressed { held.insert(.a) }
            if surface.pressed { held.insert(.x) }
            if lights.pressed { held.insert(.right) }
            // Detach trailer: a tap holds the headlight input (D-pad right) for 1.5 s, which unhitches the trailer.
            if detachTrailer.pressed && !detachTrailerWasPressed { pulse(.right, for: 1.5) }
            detachTrailerWasPressed = detachTrailer.pressed
            if nextSong.pressed && !nextSongWasPressed { PGSelfRadioNext() }
            nextSongWasPressed = nextSong.pressed
            // INPUT_VEH_GRAPPLING_HOOK, D-pad right in the game's standard pad layout.
            if towHook.pressed { held.insert(.right) }
            // The tow arm moves with the left stick up/down, as on a controller.
            if towArmUp.pressed { state.leftY = 1 } else if towArmDown.pressed { state.leftY = -1 }
            if detonate.pressed { held.insert(.left) }
            for role in roles.values {
                guard case .radioWheel(_, let current, let since) = role, now - since >= 0.25 else { continue }
                // Held: the wheel is open around the middle of the screen, and the station picked is the
                // one the finger points at from there. It goes straight into the wheel's own inputs
                // (PGSetRadioWheelDirection); camera and steering stay still while choosing.
                held.insert(.left)
                let d = CGPoint(x: current.x - bounds.midX, y: current.y - bounds.midY), length = hypot(d.x, d.y)
                radioDirection = length > 40 ? (Float(d.x / length), Float(-d.y / length)) : (0, 0)
                state.rightX = 0; state.rightY = 0
                state.leftX = 0; state.leftY = 0
            }
        case .heli, .plane:
            state.leftX = Float(moveStick.value.x); state.leftY = Float(moveStick.value.y)
            // GTA V's controller flight: RT throttle up / climb, LT down / descend, LB/RB rudder.
            if throttleUp.pressed { state.rightTrigger = 1 }
            if throttleDown.pressed { state.leftTrigger = 1 }
            if yawLeft.pressed { held.insert(.l1) }
            if yawRight.pressed { held.insert(.r1) }
            if planeStickEnabled {
                state.rightTrigger = Float(max(0, planeThrottle))
                state.leftTrigger = Float(max(0, -planeThrottle))
                if rightStick.value.x < -0.35 { held.insert(.l1) }
                if rightStick.value.x > 0.35 { held.insert(.r1) }
                state.rightX = 0; state.rightY = 0
            }
            if airFire.pressed { held.insert(.a) }
            if gear.pressed { held.insert(.l3) }
            if towHook.pressed { held.insert(.right) }   // the Cargobob's hook
            // Interact is D-pad right here too: Eye in the Sky's helicopter camera (the player in the back seat) asks
            // "Press ~INPUT_SCRIPT_PAD_RIGHT~ to toggle the thermal vision mode" and reads INPUT_CONTEXT; the button
            // showed but sent nothing in a helicopter, so the thermal camera never came on (GTA-163).
            if interact.pressed { held.insert(.right) }
            if let start = exitHoldStart {
                // Leaving an aircraft needs a short hold, so a slip cannot bail out.
                let progress = (now - start) / 0.4
                enter.setProgress(CGFloat(progress))
                if progress >= 1 { held.insert(.y) }
            }
        case .menu:
            state.leftX = Float(moveStick.value.x); state.leftY = Float(moveStick.value.y)
        }

        for role in roles.values {
            guard case .characterWheel(let start, let current) = role else { continue }
            // Hold D-pad down (the selector opens); the same finger points at a character.
            held.insert(.down)
            let d = CGPoint(x: current.x - start.x, y: current.y - start.y), length = hypot(d.x, d.y)
            state.rightX = length > 24 ? Float(d.x / length) : 0
            state.rightY = length > 24 ? Float(-d.y / length) : 0
        }
        if camera.pressed { held.insert(.select) }
        if pause.pressed { held.insert(.start) }
        advanceFullMap(CACurrentMediaTime())
        if mapPinch.isEnabled != (context == .menu) { mapPinch.isEnabled = context == .menu }
        if phone.pressed && phoneDock && !gamePhoneOut { held.insert(.up) }
        if !phone.pressed { phoneOpensDock = false }
        if phone.pressed && gamePhoneOut && !phoneOpensDock { held.insert(.b) }
        if tvCouch {
            // The TV remote reads the left stick: left/right change the channel, up/down the volume.
            if left.pressed { state.leftX = -1 } else if right.pressed { state.leftX = 1 }
            if up.pressed { state.leftY = 1 } else if down.pressed { state.leftY = -1 }
        } else if taxiRide {
            // The taxi's destination menu reads the left stick (D-pad left would change the station).
            if up.pressed { held.insert(.up) }
            if down.pressed { held.insert(.down) }
            if left.pressed { state.leftX = -1 }
            if right.pressed { state.leftX = 1 }
        } else {
            if up.pressed { held.insert(.up) }
            if down.pressed { held.insert(.down) }
            if left.pressed { held.insert(.left) }
            if right.pressed { held.insert(.right) }
        }
        if accept.pressed { held.insert(.a) }
        if back.pressed { held.insert(.b) }
        if promptActive {
            let down = [accept, back, promptOption].filter(\.pressed).map(\.name)
            if down != promptButtonsDown { promptButtonsDown = down; if !down.isEmpty { GameFolder.log("Prompt: pressed \(down.joined(separator: ", "))") } }
        }
        if phoneOption.pressed { held.insert(.x) }
        if taxiHurry.pressed { held.insert(.x) }
        if taxiStop.pressed { held.insert(.b) }
        if tabLeft.pressed { held.insert(.l1) }
        if tabRight.pressed { held.insert(.r1) }
        if promptOption.pressed { held.insert(.x) }
        // A trigger asked for together with the right stick latches (By the Book's tooth: hold RT to grip, then rotate
        // the right stick to pull, GTA-94): a tap holds it, so the right thumb is free for the stick, and the next tap
        // lets go; it lets go by itself once the mission stops asking for it or for the stick.
        let stickToo = !polledMission.isDisjoint(with: [220, 221])
        for mission in missionButtons where mission.trigger != 0 {
            let pressed = mission.button.pressed, asked = polledMission.contains(mission.input) || (mission.menuInput.map(polledMission.contains) ?? false)
            if stickToo && pressed && !triggerWasPressed.contains(mission.input) {
                let on = latchedTriggers.remove(mission.input) == nil
                if on { latchedTriggers.insert(mission.input) }
                GameFolder.log("Mission button \(mission.button.name) \(on ? "held (tap again to let go)" : "let go")")
            }
            if pressed { triggerWasPressed.insert(mission.input) } else { triggerWasPressed.remove(mission.input) }
            if !stickToo || !asked { latchedTriggers.remove(mission.input) }
            mission.button.active = latchedTriggers.contains(mission.input)
            // Held counts too: a thumb that has held RT since "Hold RT to grip a tooth" keeps the grip when the
            // rotate step starts asking for the stick (harness, fbi3).
            if latchedTriggers.contains(mission.input) || pressed {
                if mission.trigger == 1 { state.leftTrigger = 1 } else { state.rightTrigger = 1 }
            }
        }
        for mission in missionButtons where mission.button.pressed {
            if let pad = mission.pad { held.insert(pad) }
        }
        // LT+RT: a tap (the press starts) latches both triggers, the next releases them; it lets go by
        // itself once the mission stops asking.
        if bothTriggers.pressed && !bothTriggersWasPressed { bothTriggersHeld.toggle(); bothTriggers.active = bothTriggersHeld }
        bothTriggersWasPressed = bothTriggers.pressed
        if !(polledMission.isSuperset(of: [228, 229]) || polledMission.isSuperset(of: [207, 208])) && bothTriggersHeld { bothTriggersHeld = false; bothTriggers.active = false }
        if bothTriggersHeld { state.leftTrigger = 1; state.rightTrigger = 1 }
        // Without a phone on screen the dock closes itself: after a moment when the phone did not
        // come up, or after 20 s without input as before.
        if phoneDock && !gamePhoneOut {
            if let asked = phoneRequestedAt, now - asked > 2.5 { phoneDock = false; phoneRequestedAt = nil; updateVisibility() }
            else if phoneRequestedAt == nil && now - lastDockInput > 20 { phoneDock = false; updateVisibility() }
        }

        if context == .onFoot && detonate.pressed { held.insert(.left) }
        // The radio wheel's own inputs (see PGSetRadioWheelDirection).
        PGSetRadioWheelDirection(radioDirection?.0 ?? 0, radioDirection?.1 ?? 0, radioDirection != nil)
        radioDirection = nil
        pulses.removeAll { $0.until <= now }
        for pulse in pulses { held.formUnion(pulse.buttons) }
        // Every press reaches the game: a bit stays down at least `minimumPress` after it went down,
        // since the engine samples the pad once per game frame.
        let raw = held
        for bit in 0..<16 {
            let value = UInt32(1) << UInt32(bit)
            if raw.rawValue & value != 0 && lastHeld.rawValue & value == 0 { pressedAt[value] = now }
            if raw.rawValue & value == 0, let at = pressedAt[value], now - at < Self.minimumPress { held.insert(PadButtons(rawValue: value)) }
        }
        lastHeld = raw
        state.padButtons = held
        sendKeyboardMouseEquivalents(state)
        return state
    }

    /// Swipe camera (mouse): once the game has seen mouse movement it takes keyboard-and-mouse input, and
    /// in that mode it ignores some controller buttons the touch controls press: aiming from a vehicle (LB)
    /// did nothing (GTA-83) and sprinting by tapping A stopped (GTA-79). While the swipe camera moves the
    /// mouse, the same actions also go to the mouse and keyboard, as a PC player would press them:
    /// aim = right mouse button, shoot = left mouse button, sprint = Shift.
    private var mouseButtons: Int32 = 0
    private var shiftHeld = false
    private func sendKeyboardMouseEquivalents(_ state: PGPadState) {
        var buttons: Int32 = 0
        var shift = false
        if experimentalMouseLookActive {
            switch context {
            case .onFoot:
                if state.leftTrigger > 0.5 { buttons |= 2 }
                if state.rightTrigger > 0.5 { buttons |= 1 }
                shift = moveStick.sprinting || sprint.pressed
            case .car, .boat, .bike, .bicycle, .sub:
                if driveAim.pressed || driveBy.pressed { buttons |= 2 }
                if driveBy.pressed, let started = fireStartedAt, CACurrentMediaTime() - started > 0.12 { buttons |= 1 }
            default: break
            }
        }
        if buttons != mouseButtons || buttons != 0 { PGMouseInput(0, 0, buttons) }
        mouseButtons = buttons
        if shift != shiftHeld { shiftHeld = shift; PGSetKey(0x10, shift); PGSetKey(0xA0, shift) }
    }

    /// Thumb offset (-1...1) to the engine's right stick. A small inner dead
    /// zone ignores a resting thumb; beyond it, output starts just past the
    /// engine's own dead zone so gentle pushes turn slowly instead of not at
    /// all. `speed` above 1 reaches full turning speed with less travel.
    static func cameraStick(_ value: CGPoint, speed: CGFloat) -> (Float, Float) {
        let length = hypot(value.x, value.y)
        guard length > 0.08 else { return (0, 0) }
        let x = min(1, (length - 0.08) / 0.92 * max(0.3, speed))
        let deadZone: CGFloat = 0.24
        let out = deadZone + (1 - deadZone) * pow(x, 1.4)
        return (Float(value.x / length * out), Float(value.y / length * out))
    }

    /// Finger speed (points/second) to stick deflection. About 320 pt/s is a
    /// full stick. Any real movement starts just past the engine's stick dead
    /// zone, so slow, precise drags still move the camera.
    static func lookAxis(_ velocity: CGFloat) -> Float {
        let speed = abs(velocity)
        guard speed > 4 else { return 0 }
        let x = min(1, speed / 320)
        let deadZone: CGFloat = 0.24
        return Float(copysign(deadZone + (1 - deadZone) * pow(x, 0.75), velocity))
    }
}
