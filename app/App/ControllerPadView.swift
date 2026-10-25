import UIKit

/// What the layout editor (ControlsLayoutEditorController) needs from a set of on-screen controls: the situational
/// layout (TouchControlsView) and the controller buttons (ControllerPadView) both take it.
protocol LayoutEditableControls: UIView {
    var highlighted: ControlButton? { get set }
    func editableButton(at point: CGPoint) -> ControlButton?
    func button(named name: String) -> ControlButton?
    func normalized(_ point: CGPoint) -> CGPoint
    func clampedToSafeArea(_ point: CGPoint) -> CGPoint
    func updateVisibility()
}
extension TouchControlsView: LayoutEditableControls {}

#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
/// The debug channel's fingers and layout readout (DebugChannel.swift), on whichever touch scheme is showing.
protocol DebugTouchSurface: UIView {
    func debugTouch(finger: Int, phase: UITouch.Phase, at point: CGPoint?)
    func debugState() -> [String: Any]
    func debugButton(named name: String) -> CGPoint?
}
extension TouchControlsView: DebugTouchSurface {}
#endif

/// Settings › Touch controls › Touch scheme › Controller buttons (GTA-195): every button of an Xbox controller on
/// screen, all the time, for players who know the controller and for moments the situational layout has no button
/// for. Two sticks (they only steer; L3/R3 are their own buttons, Kevin 2026-10-25), A B X Y, LB RB, LT RT (full on touch; slide
/// the finger up to ease off), the D-pad, View and Menu. It reports exactly what a real controller would
/// (PGPadState(gamepad:)), so the game shows controller prompts and anything a controller does works.
/// Settings and Mods stay in the situational layer above, which shows only them while this scheme is on.
/// Positions, sizes and hidden buttons are in ControlsLayout under the group "pad" (Edit controls layout).
final class ControllerPadView: UIView, LayoutEditableControls {
    static let layoutGroup = "pad"
    var inputChanged: (() -> Void)?
    /// In the layout editor: shown but not played; hidden buttons stay visible, dimmed.
    var editing = false { didSet { updateVisibility() } }
    weak var highlighted: ControlButton? { didSet { updateHighlight() } }
    /// The situational layer above this one (Settings and Mods); debug-channel fingers on those go to it.
    weak var overlay: TouchControlsView?

    private enum Stick { case left, right }
    private enum Role {
        case button(ControlButton)
        /// LT/RT: full where the finger lands; sliding up eases off (analog), sliding back down presses again.
        case trigger(ControlButton, startY: CGFloat)
        /// A stick. It only steers: L3/R3 are the separate buttons (a double tap clicked it by mistake, Kevin 2026-10-25).
        case stick(Stick)
    }
    private var roles: [ObjectIdentifier: Role] = [:]
    private var triggerValues: [ObjectIdentifier: CGFloat] = [:]

    private struct Spec {
        let name: String, icon: String, label: String
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        var pad: PadButtons? = nil, pedal = false, group = 0
    }
    /// Default places as fractions of the safe area, sizes in points before Button size. Glyphs are SF Symbols
    /// that exist on iOS 16 (the controller symbols came in iOS 14 and 15); the D-pad uses arrows, which read better small.
    private static let face: (x: CGFloat, y: CGFloat) = (0.875, 0.56)
    /// The D-pad sits high enough that the layout editor's toolbar (bottom left) doesn't cover its down button.
    private static let dpad: (x: CGFloat, y: CGFloat) = (0.32, 0.62)
    private static func specs() -> [Spec] {
        [Spec(name: "pad_ls", icon: "sf:l.joystick.fill", label: AppLanguage.choose("Left stick"), x: 0.12, y: 0.64, width: 128, height: 128),
         Spec(name: "pad_rs", icon: "sf:r.joystick.fill", label: AppLanguage.choose("Right stick"), x: 0.64, y: 0.76, width: 116, height: 116),
         Spec(name: "pad_y", icon: "sf:y.circle.fill", label: AppLanguage.choose("Y"), x: face.x, y: face.y, width: 54, height: 54, pad: .y, group: 1),
         Spec(name: "pad_a", icon: "sf:a.circle.fill", label: AppLanguage.choose("A"), x: face.x, y: face.y, width: 54, height: 54, pad: .a, group: 1),
         Spec(name: "pad_x", icon: "sf:x.circle.fill", label: AppLanguage.choose("X"), x: face.x, y: face.y, width: 54, height: 54, pad: .x, group: 1),
         Spec(name: "pad_b", icon: "sf:b.circle.fill", label: AppLanguage.choose("B"), x: face.x, y: face.y, width: 54, height: 54, pad: .b, group: 1),
         Spec(name: "pad_lb", icon: "sf:lb.rectangle.roundedbottom.fill", label: AppLanguage.choose("LB"), x: 0.16, y: 0.13, width: 50, height: 50, pad: .l1),
         Spec(name: "pad_rb", icon: "sf:rb.rectangle.roundedbottom.fill", label: AppLanguage.choose("RB"), x: 0.84, y: 0.13, width: 50, height: 50, pad: .r1),
         Spec(name: "pad_lt", icon: "sf:lt.rectangle.roundedtop.fill", label: AppLanguage.choose("LT"), x: 0.05, y: 0.27, width: 58, height: 72, pedal: true),
         Spec(name: "pad_rt", icon: "sf:rt.rectangle.roundedtop.fill", label: AppLanguage.choose("RT"), x: 0.95, y: 0.27, width: 58, height: 72, pedal: true),
         Spec(name: "pad_l3", icon: "sf:l.joystick.press.down.fill", label: AppLanguage.choose("Left stick click"), x: 0.24, y: 0.38, width: 42, height: 42, pad: .l3),
         Spec(name: "pad_r3", icon: "sf:r.joystick.press.down.fill", label: AppLanguage.choose("Right stick click"), x: 0.66, y: 0.50, width: 42, height: 42, pad: .r3),
         Spec(name: "pad_view", icon: "sf:rectangle.fill.on.rectangle.fill.circle", label: AppLanguage.choose("View"), x: 0.40, y: 0.08, width: 42, height: 42, pad: .select),
         Spec(name: "pad_menu", icon: "sf:line.3.horizontal.circle.fill", label: AppLanguage.choose("Menu"), x: 0.465, y: 0.08, width: 42, height: 42, pad: .start),
         Spec(name: "pad_up", icon: "sf:arrowtriangle.up.fill", label: AppLanguage.choose("D-pad up"), x: dpad.x, y: dpad.y, width: 48, height: 48, pad: .up, group: 2),
         Spec(name: "pad_down", icon: "sf:arrowtriangle.down.fill", label: AppLanguage.choose("D-pad down"), x: dpad.x, y: dpad.y, width: 48, height: 48, pad: .down, group: 2),
         Spec(name: "pad_left", icon: "sf:arrowtriangle.left.fill", label: AppLanguage.choose("D-pad left"), x: dpad.x, y: dpad.y, width: 48, height: 48, pad: .left, group: 2),
         Spec(name: "pad_right", icon: "sf:arrowtriangle.right.fill", label: AppLanguage.choose("D-pad right"), x: dpad.x, y: dpad.y, width: 48, height: 48, pad: .right, group: 2)]
    }
    private let specs = ControllerPadView.specs()
    private let buttons: [ControlButton]
    private var visible: [ControlButton] = []
    private func spec(_ button: ControlButton) -> Spec? { specs.first { $0.name == button.name } }
    private func named(_ name: String) -> ControlButton { buttons.first { $0.name == name }! }
    private lazy var leftZone = named("pad_ls")
    private lazy var rightZone = named("pad_rs")
    private lazy var leftTrigger = named("pad_lt")
    private lazy var rightTrigger = named("pad_rt")
    private let leftStick = FloatingStick(), rightStick = FloatingStick()
    private func view(_ stick: Stick) -> FloatingStick { stick == .left ? leftStick : rightStick }
    private func zone(_ stick: Stick) -> ControlButton { stick == .left ? leftZone : rightZone }

    /// Every press reaches the game: a bit stays down at least this long (the engine samples once per frame).
    private static let minimumPress: CFTimeInterval = 0.07
    private var pressedAt: [UInt32: CFTimeInterval] = [:]
    private var lastHeld = PadButtons()
    private var scale: CGFloat = 1
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var settingsObserver: NSObjectProtocol?
    private var refreshQueued = false

    override init(frame: CGRect) {
        buttons = specs.map { ControlButton($0.name, icon: $0.icon, label: $0.label) }
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        for (button, spec) in zip(buttons, specs) { button.isPedal = spec.pedal; button.alpha = 0; addSubview(button) }
        for stick in [leftStick, rightStick] { addSubview(stick) }
        // The stick areas are big: their glyph is drawn at half the usual size, so it reads as a label, not a blob.
        for zone in [leftZone, rightZone] {
            let symbol = zone === leftZone ? "l.joystick.fill" : "r.joystick.fill"
            zone.subviews.compactMap { $0 as? UIImageView }.first?.image = Self.smallSymbol(symbol)
        }
        // Button size, opacity and the layout editor all write UserDefaults: follow them.
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.refreshQueued else { return }
                self.refreshQueued = true
                DispatchQueue.main.async { self.refreshQueued = false; self.updateVisibility() }
            }
        }
        updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// An SF Symbol in the middle of a transparent square twice its size.
    private static func smallSymbol(_ name: String) -> UIImage? {
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold)) else { return nil }
        let side = max(symbol.size.width, symbol.size.height) * 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            symbol.withTintColor(.white).draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
        }.withRenderingMode(.alwaysTemplate)
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }

    override var isHidden: Bool { didSet { if isHidden && !oldValue { reset() } } }

    // MARK: Layout

    private func hiddenByPlayer(_ button: ControlButton) -> Bool {
        ControlsLayout.entry(group: Self.layoutGroup, name: button.name)?.hidden ?? false
    }

    func updateVisibility() {
        visible = buttons.filter { editing || !hiddenByPlayer($0) }
        let opacity = CGFloat(GameSettings.shared.controlOpacity)
        for button in buttons {
            let hidden = hiddenByPlayer(button)
            // The stick areas are big: drawn fainter, so the game shows through.
            var target = hidden ? (editing ? 0.3 : 0) : (button === leftZone || button === rightZone ? opacity * 0.6 : opacity)
            if !editing && roles.values.contains(where: { if case .stick(let s) = $0 { return zone(s) === button }; return false }) { target *= 0.5 }
            if abs(button.alpha - target) > 0.01 { button.alpha = target }
            button.isAccessibilityElement = editing || !hidden
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return }
        // The same scale as the situational layout (TouchControlsView), with Settings › Button size.
        scale = max(0.8, min(1.25, min(safe.width / 832, safe.height / 407))) * CGFloat(GameSettings.shared.controlScale)
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: safe.minX + fx * safe.width, y: safe.minY + fy * safe.height) }
        let faceStep = 58 * scale, dpadStep = 50 * scale
        let offsets: [String: CGPoint] = [
            "pad_y": CGPoint(x: 0, y: -faceStep), "pad_a": CGPoint(x: 0, y: faceStep), "pad_x": CGPoint(x: -faceStep, y: 0), "pad_b": CGPoint(x: faceStep, y: 0),
            "pad_up": CGPoint(x: 0, y: -dpadStep), "pad_down": CGPoint(x: 0, y: dpadStep), "pad_left": CGPoint(x: -dpadStep, y: 0), "pad_right": CGPoint(x: dpadStep, y: 0)]
        for (button, spec) in zip(buttons, specs) {
            var size = CGSize(width: max(40, spec.width * scale), height: max(40, spec.height * scale))
            var center = point(spec.x, spec.y)
            if let offset = offsets[spec.name] { center.x += offset.x; center.y += offset.y }
            if let entry = ControlsLayout.entry(group: Self.layoutGroup, name: spec.name) {
                size = CGSize(width: max(36, size.width * entry.scale), height: max(36, size.height * entry.scale))
                center = point(entry.x, entry.y)
            }
            button.bounds.size = size
            button.center = center
        }
        for stick in [Stick.left, .right] {
            let floating = view(stick), area = zone(stick)
            floating.frame = bounds
            floating.baseDiameter = area.bounds.width * 0.9
            floating.travel = area.bounds.width * 0.36
        }
        updateHighlight()
    }

    // MARK: Layout editor

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
    func editableButton(at point: CGPoint) -> ControlButton? { button(at: point) }
    func button(named name: String) -> ControlButton? { buttons.first { $0.name == name } }
    func normalized(_ point: CGPoint) -> CGPoint {
        let safe = bounds.inset(by: safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - safe.minX) / safe.width, y: (point.y - safe.minY) / safe.height)
    }
    func clampedToSafeArea(_ point: CGPoint) -> CGPoint {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 24, dy: 24)
        return CGPoint(x: min(max(point.x, safe.minX), safe.maxX), y: min(max(point.y, safe.minY), safe.maxY))
    }

    // MARK: Touches

    /// The control under a point; nearest centre wins where hit areas overlap. The stick areas reach a bit further.
    private func button(at point: CGPoint, group: Int? = nil) -> ControlButton? {
        visible.filter { b in
            (group == nil || spec(b)?.group == group) && b.contains(point: point, slop: b === leftZone || b === rightZone ? 20 : 6)
        }.min { hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isHidden || editing { return nil }
        // Only the controls take touches; the rest of the screen stays free.
        return button(at: point) == nil ? nil : self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { return }
        for touch in touches { beginTouch(ObjectIdentifier(touch), at: touch.location(in: self)) }
        inputChanged?()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { moveTouch(ObjectIdentifier(touch), to: touch.location(in: self)) }
        inputChanged?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { endTouch(ObjectIdentifier(touch)) }
        inputChanged?()
    }

    private func stickHeld(_ stick: Stick) -> Bool {
        roles.values.contains { if case .stick(let s) = $0 { return s == stick }; return false }
    }

    private func beginTouch(_ id: ObjectIdentifier, at point: CGPoint) {
        guard let button = button(at: point) else { return }
        haptics.impactOccurred(intensity: 0.6)
        if button === leftZone || button === rightZone {
            let stick: Stick = button === leftZone ? .left : .right
            guard !stickHeld(stick) else { return }
            roles[id] = .stick(stick)
            view(stick).begin(at: point)
            updateVisibility()
        } else if button === leftTrigger || button === rightTrigger {
            button.setPressed(true)
            roles[id] = .trigger(button, startY: point.y)
            triggerValues[ObjectIdentifier(button)] = 1
        } else {
            button.setPressed(true)
            roles[id] = .button(button)
        }
    }

    private func moveTouch(_ id: ObjectIdentifier, to point: CGPoint) {
        guard let role = roles[id] else { return }
        switch role {
        case .stick(let stick):
            view(stick).move(to: point)
        case .trigger(let button, let startY):
            // Up from where the finger landed eases off; a full button height is released.
            let travel = max(40, button.bounds.height)
            triggerValues[ObjectIdentifier(button)] = max(0, min(1, 1 - (startY - point.y) / travel))
        case .button(let button):
            // The face buttons and the D-pad: a thumb may roll from one to the next without lifting.
            guard let group = spec(button)?.group, group != 0, !button.contains(point: point, slop: 6),
                  let next = self.button(at: point, group: group), next !== button, !next.pressed else { return }
            button.setPressed(false)
            next.setPressed(true)
            haptics.impactOccurred(intensity: 0.4)
            roles[id] = .button(next)
        }
    }

    private func endTouch(_ id: ObjectIdentifier) {
        guard let role = roles.removeValue(forKey: id) else { return }
        switch role {
        case .stick(let stick):
            view(stick).end()
            zone(stick).active = false
            updateVisibility()
        case .trigger(let button, _):
            button.setPressed(false)
            triggerValues[ObjectIdentifier(button)] = nil
        case .button(let button):
            button.setPressed(false)
        }
    }

    func reset() {
        for id in Array(roles.keys) { endTouch(id) }
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        debugFingers.removeAll()
        #endif
    }

    // MARK: Output

    /// The pad as a controller would send it.
    func padState() -> PGPadState {
        var state = PGPadState()
        var held = PadButtons()
        let now = CACurrentMediaTime()
        for role in roles.values {
            switch role {
            case .stick(let stick):
                let value = view(stick).value
                if stick == .left { state.leftX = Float(value.x); state.leftY = Float(value.y) }
                else { state.rightX = Float(value.x); state.rightY = Float(value.y) }
            case .trigger(let button, _):
                let value = Float(triggerValues[ObjectIdentifier(button)] ?? 0)
                if button === leftTrigger { state.leftTrigger = max(state.leftTrigger, value) } else { state.rightTrigger = max(state.rightTrigger, value) }
            case .button(let button):
                if let bit = spec(button)?.pad { held.insert(bit) }
            }
        }
        let raw = held
        for bit in 0..<16 {
            let value = UInt32(1) << UInt32(bit)
            if raw.rawValue & value != 0 && lastHeld.rawValue & value == 0 { pressedAt[value] = now }
            if raw.rawValue & value == 0, let at = pressedAt[value], now - at < Self.minimumPress { held.insert(PadButtons(rawValue: value)) }
        }
        lastHeld = raw
        state.padButtons = held
        return state
    }

    // MARK: Debug channel

    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// Fingers that take the real touch path, numbered by the caller; a finger that lands on Settings or Mods goes
    /// to the situational layer above, as a real touch would.
    private var debugFingers: [Int: (token: NSObject, overlay: Bool)] = [:]
    func debugTouch(finger: Int, phase: UITouch.Phase, at point: CGPoint?) {
        switch phase {
        case .began:
            debugTouch(finger: finger, phase: .ended, at: nil)
            guard let point, !editing else { break }
            if let overlay, overlay.hitTest(point, with: nil) != nil {
                debugFingers[finger] = (NSObject(), true)
                overlay.debugTouch(finger: finger, phase: .began, at: point)
                return
            }
            let token = NSObject()
            debugFingers[finger] = (token, false)
            beginTouch(ObjectIdentifier(token), at: point)
        case .moved:
            guard let point, let down = debugFingers[finger] else { break }
            if down.overlay { overlay?.debugTouch(finger: finger, phase: .moved, at: point); return }
            moveTouch(ObjectIdentifier(down.token), to: point)
        default:
            guard let down = debugFingers.removeValue(forKey: finger) else { break }
            if down.overlay { overlay?.debugTouch(finger: finger, phase: .ended, at: nil); return }
            endTouch(ObjectIdentifier(down.token))
        }
        inputChanged?()
    }

    /// The layout as the player sees it: this scheme's controls plus Settings and Mods from the layer above.
    func debugState() -> [String: Any] {
        let size = bounds.size
        func frame(_ view: UIView) -> [Double] {
            [view.frame.midX / size.width, view.frame.midY / size.height, view.frame.width / size.width, view.frame.height / size.height].map { (Double($0) * 1000).rounded() / 1000 }
        }
        let roleNames = roles.values.map { role -> String in
            switch role {
            case .stick(let stick): return "stick:\(stick)"
            case .trigger(let button, _): return "trigger:\(button.name)=\(String(format: "%.2f", Double(triggerValues[ObjectIdentifier(button)] ?? 0)))"
            case .button(let button): return "button:\(button.name)"
            }
        }
        var shown: [[String: Any]] = visible.map { ["name": $0.name, "at": frame($0), "pressed": $0.pressed, "alpha": (Double($0.alpha) * 100).rounded() / 100] }
        if let above = overlay?.debugState()["visible"] as? [[String: Any]] { shown += above }
        return ["scheme": "controller", "roles": roleNames, "visible": shown, "size": [Double(size.width), Double(size.height)],
                "sticks": [[Double(leftStick.value.x), Double(leftStick.value.y)], [Double(rightStick.value.x), Double(rightStick.value.y)]]]
    }
    func debugButton(named name: String) -> CGPoint? {
        visible.first { $0.name == name }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? overlay?.debugButton(named: name)
    }
    #endif
}

#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
extension ControllerPadView: DebugTouchSurface {}
#endif
