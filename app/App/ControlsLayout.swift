import UIKit

/// The player's own touch-control layout. Each moved control is stored by group ("foot" or
/// "vehicle") and name, as its centre in the safe area (0...1 on both axes), a size factor and
/// whether it is hidden. Controls without an entry use the default layout.
struct ControlsLayout {
    struct Entry: Equatable {
        var x: CGFloat, y: CGFloat, scale: CGFloat, hidden: Bool
    }
    private static let key = "controlsLayout"
    /// Never hidden: the game cannot be played (or left) without them.
    static let essential: Set<String> = ["fire", "aim", "enter", "gas", "brake", "pause", "settings", "airFire", "pad_menu"]

    static var entries: [String: Entry] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] else { return [:] }
            return raw.compactMapValues { v in
                v.count >= 4 ? Entry(x: CGFloat(v[0]), y: CGFloat(v[1]), scale: CGFloat(v[2]), hidden: v[3] != 0) : nil
            }
        }
        set {
            let raw = newValue.mapValues { [Double($0.x), Double($0.y), Double($0.scale), $0.hidden ? 1 : 0] }
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
    static func entry(group: String, name: String) -> Entry? { entries["\(group).\(name)"] }
    static func set(_ entry: Entry?, group: String, name: String) {
        var all = entries
        all["\(group).\(name)"] = entry
        entries = all
    }
    static func reset(group: String) { entries = entries.filter { !$0.key.hasPrefix(group + ".") } }
    static var isCustomized: Bool { !entries.isEmpty }
}

/// Full-screen editor: drag a control to move it, pinch (or the slider) to resize it, hide the
/// ones you don't use. Shows the on-foot and the vehicle controls (switch at the bottom), and the Controller buttons
/// touch scheme (GTA-195, ControllerPadView).
final class ControlsLayoutEditorController: UIViewController {
    var onDone: (() -> Void)?
    private let controls = TouchControlsView(frame: .zero)
    private let pad = ControllerPadView(frame: .zero)
    /// The set of controls being edited: the situational layout, or the controller buttons.
    /// In the Controller buttons group the player's mod buttons (in `controls`) are edited alongside the pad's own.
    private var surface: LayoutEditableControls {
        guard groupPicker.selectedSegmentIndex == 3 else { return controls }
        return selected.map { controls.button(named: $0.name) === $0 } == true ? controls : pad
    }
    private func editable(at point: CGPoint) -> ControlButton? {
        groupPicker.selectedSegmentIndex == 3 ? controls.editableButton(at: point) ?? pad.editableButton(at: point) : controls.editableButton(at: point)
    }
    private let background = UIImageView()
    private let toolbar = UIStackView()
    private let groupPicker = UISegmentedControl(items: [AppLanguage.choose("On foot"), AppLanguage.choose("In a vehicle"), AppLanguage.choose("Aircraft"),
                                                             AppLanguage.choose("Controller buttons")])
    private let sizeSlider = UISlider()
    private let hideButton = UIButton(type: .system)
    private let hint = UILabel()
    private var selected: ControlButton? { didSet { refreshSelection() } }
    private var dragOffset = CGPoint.zero
    private var pinchStartScale: CGFloat = 1

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.16, green: 0.2, blue: 0.24, alpha: 1)
        // A game-like backdrop: the title art when the game folder provides it, otherwise a gradient.
        background.contentMode = .scaleAspectFill
        background.clipsToBounds = true
        background.alpha = 0.55
        background.image = UIImage(named: "LaunchBackground")
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.editing = true
        controls.characterSwitchEnabled = true
        controls.isUserInteractionEnabled = false
        view.addSubview(controls)
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.editing = true
        pad.isUserInteractionEnabled = false
        pad.isHidden = true
        view.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: view.leadingAnchor), pad.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pad.topAnchor.constraint(equalTo: view.topAnchor), pad.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor), background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor), background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hint.text = AppLanguage.choose("Drag a button to move it · pinch to resize")
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = UIColor.white.withAlphaComponent(0.85)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        // The Controller buttons scheme opens on its own buttons.
        groupPicker.selectedSegmentIndex = GameSettings.shared.touchScheme == .controller ? 3 : 0
        groupPicker.overrideUserInterfaceStyle = .dark
        groupPicker.addAction(UIAction { [weak self] _ in self?.showGroup() }, for: .valueChanged)
        sizeSlider.minimumValue = 0.6
        sizeSlider.maximumValue = 1.8
        sizeSlider.accessibilityLabel = AppLanguage.choose("Size of the selected button")
        sizeSlider.addAction(UIAction { [weak self] _ in self?.sizeChanged() }, for: .valueChanged)
        sizeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        hideButton.addAction(UIAction { [weak self] _ in self?.toggleHidden() }, for: .touchUpInside)
        let reset = UIButton(type: .system)
        reset.setTitle(AppLanguage.choose("Reset"), for: .normal)
        reset.addAction(UIAction { [weak self] _ in self?.resetGroup() }, for: .touchUpInside)
        let done = UIButton(type: .system)
        done.setTitle(AppLanguage.choose("Done"), for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        for item in [groupPicker, sizeSlider, hideButton, reset, done] as [UIView] { toolbar.addArrangedSubview(item) }
        toolbar.axis = .horizontal
        toolbar.spacing = 12
        toolbar.alignment = .center
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toolbar.layer.cornerRadius = 14
        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            // Bottom-left: the move-stick area, which has no buttons to cover.
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            hint.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        for gesture in [pan, pinch, tap] as [UIGestureRecognizer] { gesture.delegate = self; view.addGestureRecognizer(gesture) }
        showGroup()
        applyLaunchArguments()
    }

    private var group: String { [0: "foot", 3: ControllerPadView.layoutGroup][groupPicker.selectedSegmentIndex] ?? "vehicle" }

    private func showGroup() {
        let padShown = groupPicker.selectedSegmentIndex == 3
        controls.padScheme = padShown   // there it shows only the mod buttons
        pad.isHidden = !padShown
        // Aircraft share the vehicle layout, but show their own buttons (plane: vehicle type 1 + 1).
        if !padShown { controls.updateContext(vehicle: [0, 1, 2][max(0, groupPicker.selectedSegmentIndex)], pauseMenu: false) }
        selected = nil
        surface.updateVisibility()
        surface.setNeedsLayout()
    }

    private func refreshSelection() {
        controls.highlighted = surface === controls ? selected : nil
        pad.highlighted = surface === pad ? selected : nil
        sizeSlider.isEnabled = selected != nil
        let entry = selected.flatMap { ControlsLayout.entry(group: group, name: $0.name) }
        sizeSlider.value = Float(entry?.scale ?? 1)
        if let selected {
            let hidden = entry?.hidden ?? false
            hideButton.setTitle(hidden ? AppLanguage.choose("Show") : AppLanguage.choose("Hide"), for: .normal)
            hideButton.isEnabled = !ControlsLayout.essential.contains(selected.name)
            hint.text = (selected.accessibilityLabel ?? selected.name) + (hidden ? AppLanguage.choose(" (hidden in game)") : "")
        } else {
            hideButton.setTitle(AppLanguage.choose("Hide"), for: .normal)
            hideButton.isEnabled = false
            hint.text = AppLanguage.choose("Drag a button to move it · pinch to resize")
        }
    }

    /// Writes the selected control's current place, keeping its size and hidden state.
    private func store(_ button: ControlButton, center: CGPoint? = nil, scale: CGFloat? = nil, hidden: Bool? = nil) {
        let old = ControlsLayout.entry(group: group, name: button.name)
        let normalized = surface.normalized(center ?? button.center)
        ControlsLayout.set(ControlsLayout.Entry(x: normalized.x, y: normalized.y,
                                                scale: scale ?? old?.scale ?? 1, hidden: hidden ?? old?.hidden ?? false),
                           group: group, name: button.name)
        surface.updateVisibility()
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        selected = editable(at: gesture.location(in: view))
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: surface)
        switch gesture.state {
        case .began:
            // The pan is recognized after the finger has already moved a little: look where it landed.
            let moved = gesture.translation(in: surface)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            selected = editable(at: start)
            if let selected { dragOffset = CGPoint(x: selected.center.x - start.x, y: selected.center.y - start.y) }
        case .changed:
            guard let selected else { return }
            store(selected, center: surface.clampedToSafeArea(CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y)))
        default:
            break
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            if selected == nil { selected = editable(at: gesture.location(in: view)) }
            pinchStartScale = selected.flatMap { ControlsLayout.entry(group: group, name: $0.name)?.scale } ?? 1
        case .changed:
            guard let selected else { return }
            let scale = max(0.6, min(1.8, pinchStartScale * gesture.scale))
            store(selected, scale: scale)
            sizeSlider.value = Float(scale)
        default:
            break
        }
    }
    private func sizeChanged() {
        guard let selected else { return }
        store(selected, scale: CGFloat(sizeSlider.value))
    }
    private func toggleHidden() {
        guard let selected, !ControlsLayout.essential.contains(selected.name) else { return }
        let hidden = !(ControlsLayout.entry(group: group, name: selected.name)?.hidden ?? false)
        store(selected, hidden: hidden)
        refreshSelection()
    }
    private func resetGroup() {
        ControlsLayout.reset(group: group)
        selected = nil
        for each in [controls, pad] as [LayoutEditableControls] { each.updateVisibility(); each.setNeedsLayout() }
    }
    private func finish() {
        onDone?()
        dismiss(animated: true)
    }

    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    /// Debug channel (`editor <group> [reset | <name> <x> <y> [scale] [hide]]`): picks a group (foot, vehicle, aircraft, pad), then selects
    /// a control and moves it the way a drag does (store), to check that the game follows the editor.
    func debugEdit(_ arguments: [String]) -> [String: Any] {
        guard let index = ["foot", "vehicle", "aircraft", "pad"].firstIndex(of: arguments.first ?? "") else { return ["ok": false, "error": "editor foot|vehicle|aircraft|pad [name x y [scale] [hide]]"] }
        if groupPicker.selectedSegmentIndex != index { groupPicker.selectedSegmentIndex = index; showGroup() }
        surface.layoutIfNeeded()
        if arguments.count == 2 && arguments[1] == "reset" { resetGroup(); return ["ok": true, "group": group, "reset": true] }
        guard arguments.count >= 4 else { return ["ok": true, "group": group] }
        guard let button = surface.button(named: arguments[1]), let x = Double(arguments[2]), let y = Double(arguments[3]) else { return ["ok": false, "error": "no such control"] }
        selected = button
        let safe = surface.bounds.inset(by: surface.safeAreaInsets)
        let center = CGPoint(x: safe.minX + CGFloat(x) * safe.width, y: safe.minY + CGFloat(y) * safe.height)
        store(button, center: surface.clampedToSafeArea(center), scale: arguments.count > 4 ? Double(arguments[4]).map { CGFloat($0) } : nil,
              hidden: arguments.count > 5 ? arguments[5] == "hide" : nil)
        refreshSelection()
        return ["ok": true, "group": group, "name": button.name, "center": [Double(button.center.x / surface.bounds.width), Double(button.center.y / surface.bounds.height)]]
    }
    #endif

    /// Automation: --layout-demo moves and enlarges Jump (on foot) so the result can be checked
    /// without touching the screen; --layout-vehicle opens the vehicle set.
    private func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--layout-vehicle") { groupPicker.selectedSegmentIndex = 1; showGroup() }
        if arguments.contains("--layout-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.controls.layoutIfNeeded()
                if let jump = self.controls.button(named: "jump") {
                    self.selected = jump
                    ControlsLayout.set(ControlsLayout.Entry(x: 0.5, y: 0.45, scale: 1.6, hidden: false), group: "foot", name: "jump")
                    self.controls.updateVisibility(); self.controls.setNeedsLayout(); self.controls.layoutIfNeeded()
                    self.refreshSelection()
                }
            }
        }
    }
}

extension ControlsLayoutEditorController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The toolbar keeps its own taps.
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: toolbar)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }
}
