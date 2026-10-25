import UIKit

/// Where the game draws its minimap for a place in its HUD units (GTA-131). The game keeps its HUD in a 16:9
/// area centred on wider screens and measures the minimap's corner from that area's bottom left: the
/// common/data/ui/frontend.xml "minimap" entry (posX -0.0045, posY 0.002, size 0.15 × 0.188888), with
/// alignY="B", so a negative posY is higher up. Checked against a moved map on an iPhone 13 Pro Max.
enum MinimapGeometry {
    static let corner = CGPoint(x: -0.0045, y: 0.002)
    static let size = CGSize(width: 0.150, height: 0.188888)

    static func hudArea(_ bounds: CGRect) -> CGRect {
        let width = min(bounds.width, bounds.height * 16 / 9)
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
    }
    /// The map's rectangle on screen for a place.
    static func rect(_ layout: (dx: Double, dy: Double, scale: Double), in bounds: CGRect) -> CGRect {
        let area = hudArea(bounds), s = CGFloat(layout.scale)
        let posX = corner.x + CGFloat(layout.dx), posY = corner.y + CGFloat(layout.dy)
        let height = size.height * s * area.height
        return CGRect(x: area.minX + posX * area.width, y: area.maxY + posY * area.height - height,
                      width: size.width * s * area.width, height: height)
    }
    /// The place for a rectangle on screen (the inverse of `rect`).
    static func layout(for rect: CGRect, in bounds: CGRect) -> (dx: Double, dy: Double, scale: Double) {
        let area = hudArea(bounds)
        let scale = rect.width / (size.width * area.width)
        let posX = (rect.minX - area.minX) / area.width
        let posY = (rect.maxY - area.maxY) / area.height
        return (Double(posX - corner.x), Double(posY - corner.y), Double(scale))
    }
}

/// Where the game draws its help messages (the box with "Press … to …", HUD_HELP_TEXT in frontend.xml) for a place in
/// its HUD units: the component's top-left corner in fractions of the 16:9 HUD area. Measured in the simulator with a
/// three-line message placed off the top: the box starts 0.0165 right of and 0.015 below the place, 0.2 wide and 0.095
/// high (a line is about 0.03).
enum HelpTextGeometry {
    static let inset = CGPoint(x: 0.0165, y: 0.015)
    /// The box of a typical message (two to three lines), in HUD units.
    static let size = CGSize(width: 0.2, height: 0.095)

    /// The box's rectangle on screen for a place.
    static func rect(_ layout: (x: Double, y: Double, scale: Double), in bounds: CGRect) -> CGRect {
        let area = MinimapGeometry.hudArea(bounds)
        return CGRect(x: area.minX + (CGFloat(layout.x) + inset.x) * area.width, y: area.minY + (CGFloat(layout.y) + inset.y) * area.height,
                      width: size.width * area.width, height: size.height * area.height)
    }
    /// The place for a rectangle on screen (the inverse of `rect`).
    static func layout(for rect: CGRect, in bounds: CGRect) -> (x: Double, y: Double, scale: Double) {
        let area = MinimapGeometry.hudArea(bounds)
        return (Double((rect.minX - area.minX) / area.width - inset.x), Double((rect.minY - area.minY) / area.height - inset.y), 1)
    }
}

/// A HUD piece the player can move (GTA-197): Settings › Touch controls › HUD layout.
enum HUDPiece: String, CaseIterable {
    case characterWheel, fps, minimap, helpText, feed, phone, stats, subtitles, names

    var title: String {
        switch self {
        case .characterWheel: return AppLanguage.choose("Character wheel")
        case .fps: return AppLanguage.choose("FPS counter")
        case .minimap: return AppLanguage.choose("Minimap")
        case .helpText: return AppLanguage.choose("Help messages")
        case .feed: return AppLanguage.choose("Notifications")
        case .phone: return AppLanguage.choose("Phone")
        case .stats: return AppLanguage.choose("Wanted level and cash")
        case .subtitles: return AppLanguage.choose("Subtitles")
        case .names: return AppLanguage.choose("Vehicle and area names")
        }
    }
    var symbol: String {
        switch self {
        case .characterWheel: return "person.3.fill"
        case .fps: return "speedometer"
        case .minimap: return "map.fill"
        case .helpText: return "questionmark.bubble.fill"
        case .feed: return "bell.fill"
        case .phone: return "iphone"
        case .stats: return "star.fill"
        case .subtitles: return "captions.bubble.fill"
        case .names: return "signpost.right.fill"
        }
    }
    /// The engine's piece number (PGSetHudPiece); the minimap, help messages and FPS counter have their own settings.
    var engineIndex: Int32? {
        switch self {
        case .characterWheel: return 0
        case .phone: return 1
        case .feed: return 2
        case .stats: return 3
        case .subtitles: return 4
        case .names: return 5
        case .fps, .minimap, .helpText: return nil
        }
    }
    var resizable: Bool { self == .minimap || self == .characterWheel || self == .phone }
    /// The game reads these places when it starts; the others change at once.
    var needsRestart: Bool { ![.fps, .characterWheel, .phone].contains(self) }
}

/// Which buttons are on screen, for the pieces' own places (GTA-197 follow-up): the situational touch layout, the
/// Controller buttons scheme (GTA-195), or none (a controller plays and the touch controls hide, also when only
/// Settings and Mods stay, GTA-146): then the game's own places.
enum HUDTouchContext: Equatable { case controller, situational, pad }

/// A piece's place: offset from the game's own place in HUD units (fractions of the 16:9 HUD area, x to the right,
/// y down) and a size factor.
struct HUDOffset: Equatable {
    var dx = 0.0, dy = 0.0, scale = 1.0
    static let zero = HUDOffset()
}

/// Where the game draws each piece at its own place, in HUD units from the HUD area's top left, measured in the simulator
/// (GTA-197, iPhone Air). Offsets are in the same units, so a place keeps its meaning on another screen shape. A piece
/// moved by an offset is that rectangle moved; the wheel grows around its bottom-right corner, as the game sizes it.
enum HUDGeometry {
    static func base(_ piece: HUDPiece, settings: GameSettings = .shared) -> CGRect {
        switch piece {
        // The wheel and the stats panel the game shows above it while you choose.
        case .characterWheel: return CGRect(x: 0.8, y: 0.473, width: 0.098, height: 0.502)
        // The phone when it is up: a little of it is below the screen.
        case .phone: return CGRect(x: 0.779, y: 0.471, width: 0.169, height: 0.552)
        // Wanted stars, then cash and the weapon's ammo (a large amount of cash is wider).
        case .stats: return CGRect(x: 0.86, y: 0.0, width: 0.125, height: 0.11)
        // The vehicle name above the area and street names (right-aligned; a long name reaches further left).
        case .names: return CGRect(x: 0.75, y: 0.85, width: 0.235, height: 0.14)
        case .subtitles:
            let raise = settings.subtitlesAboveHomeBar ? 0.05 : 0
            return CGRect(x: 0.25, y: 0.935 - raise, width: 0.5, height: 0.065)
        case .feed:
            // Above the minimap, following it sideways (NativeAssets.m); more messages stack upwards.
            let map = settings.minimapLayout
            return CGRect(x: 0.02 + map.dx, y: 0.55, width: 0.2, height: 0.24)
        case .minimap, .helpText, .fps: return .zero
        }
    }
    /// The places the wheel and the phone have until the player moves them: clear of the touch buttons (measured on the
    /// iPhone Air at the default button size). The game's own places put the wheel's stats panel over the fire button
    /// and the phone under the buttons that show with it.
    static func touchDefault(_ piece: HUDPiece, _ context: HUDTouchContext) -> HUDOffset {
        switch (piece, context) {
        case (_, .controller): return .zero
        // Left of centre, between the left-hand buttons and the middle of the screen.
        case (.characterWheel, .situational): return HUDOffset(dx: -0.644, dy: -0.343, scale: 0.8)
        // Between the D-pad and the right stick.
        case (.characterWheel, .pad): return HUDOffset(dx: -0.366, dy: -0.283, scale: 1)
        // Left of the phone's own buttons, above the subtitles.
        case (.phone, .situational): return HUDOffset(dx: -0.2295, dy: -0.143, scale: 1)
        // Between the D-pad and the right stick, a little smaller to fit.
        case (.phone, .pad): return HUDOffset(dx: -0.3746, dy: -0.3746, scale: 0.8)
        default: return .zero
        }
    }
    /// The game stacks the top-right list at the top itself: it moves sideways only.
    static func movesSidewaysOnly(_ piece: HUDPiece) -> Bool { piece == .stats }
    /// The piece's rectangle on screen for an offset.
    /// The point a piece grows around, as a fraction of its box: the minimap its bottom-left corner, the wheel its
    /// bottom-right one, the phone its centre.
    static func anchor(_ piece: HUDPiece) -> CGPoint {
        switch piece {
        case .minimap: return CGPoint(x: 0, y: 1)
        case .phone: return CGPoint(x: 0.5, y: 0.5)
        default: return CGPoint(x: 1, y: 1)
        }
    }
    /// A rectangle of the given size whose anchor stays where `from`'s is (pinch to resize).
    static func resized(_ piece: HUDPiece, _ from: CGRect, to size: CGSize) -> CGRect {
        let a = anchor(piece)
        let x = from.minX + a.x * from.width, y = from.minY + a.y * from.height
        return CGRect(x: x - a.x * size.width, y: y - a.y * size.height, width: size.width, height: size.height)
    }
    static func rect(_ piece: HUDPiece, _ offset: HUDOffset, in bounds: CGRect) -> CGRect {
        let area = MinimapGeometry.hudArea(bounds), b = base(piece), s = CGFloat(offset.scale), a = anchor(piece)
        let x = b.minX + a.x * b.width + CGFloat(offset.dx), y = b.minY + a.y * b.height + CGFloat(offset.dy)
        let width = b.width * s, height = b.height * s
        return CGRect(x: area.minX + (x - a.x * width) * area.width, y: area.minY + (y - a.y * height) * area.height,
                      width: width * area.width, height: height * area.height)
    }
    /// The offset for a rectangle on screen (the inverse of `rect`).
    static func offset(_ piece: HUDPiece, for rect: CGRect, in bounds: CGRect) -> HUDOffset {
        let area = MinimapGeometry.hudArea(bounds), b = base(piece), a = anchor(piece)
        let scale = piece.resizable ? Double(rect.width / (b.width * area.width)) : 1
        let x = (rect.minX + a.x * rect.width - area.minX) / area.width, y = (rect.minY + a.y * rect.height - area.minY) / area.height
        return HUDOffset(dx: Double(x - b.minX - a.x * b.width), dy: Double(y - b.minY - a.y * b.height), scale: scale)
    }

    /// The FPS counter (the app's own label, NativePortViewController): its size, and its place in the safe area.
    /// Phones with little memory show a red triangle in the counter, which makes it wider (NativePortViewController).
    static var fpsLowMemoryMark: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return GameSettings.shared.tier.memoryLimitMB < 2600
        #endif
    }
    static func fpsSize(lowMemory: Bool) -> CGSize { CGSize(width: lowMemory ? 84 : 68, height: 24) }
    /// Its own place: the safe area's top left, or the bottom left when the minimap is at the top. With touch controls on
    /// screen it sits lower down on the left, so a help message at the top left starts clear of it, between the
    /// buttons there (GTA-197 follow-up).
    static func fpsDefault(in safe: CGRect, size: CGSize, minimapAtTop: Bool, context: HUDTouchContext = .controller, helpTopLeft: Bool = true) -> CGRect {
        if minimapAtTop { return CGRect(x: safe.minX + 12, y: safe.maxY - 8 - size.height, width: size.width, height: size.height) }
        let y = fpsDefaultDrop(context, helpTopLeft: helpTopLeft).map { safe.minY + $0 * safe.height } ?? safe.minY + 8
        return CGRect(x: safe.minX + 12, y: y, width: size.width, height: size.height)
    }
    /// How far down the safe area the counter's own place is (nil: the top, 8 points down). With touch controls on screen
    /// and help messages at the top left it goes under them: below the situational layout's top-left buttons' height, or
    /// between LB and LT with Controller buttons (whose help messages go to the top middle, so this is only until the
    /// game restarts after a switch of schemes).
    static func fpsDefaultDrop(_ context: HUDTouchContext, helpTopLeft: Bool) -> CGFloat? {
        guard helpTopLeft else { return nil }
        switch context {
        case .controller: return nil
        case .situational: return 0.193
        case .pad: return 0.123
        }
    }
    /// A chosen place (fractions of the room the safe area leaves around the label) on screen, and back.
    static func fpsRect(_ place: CGPoint, in safe: CGRect, size: CGSize) -> CGRect {
        CGRect(x: safe.minX + place.x * max(0, safe.width - size.width), y: safe.minY + place.y * max(0, safe.height - size.height), width: size.width, height: size.height)
    }
    static func fpsPlace(for rect: CGRect, in safe: CGRect) -> CGPoint {
        let roomX = max(1, safe.width - rect.width), roomY = max(1, safe.height - rect.height)
        return CGPoint(x: min(max((rect.minX - safe.minX) / roomX, 0), 1), y: min(max((rect.minY - safe.minY) / roomY, 0), 1))
    }
}

extension GameSettings {
    /// HUD layout (GTA-197): the pieces the player moved, by HUDPiece name: [dx, dy, scale] in HUD units.
    private var hudLayoutStore: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: "hudLayout") as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "hudLayout") }
    }
    /// The place the player chose, or nil: the piece's own place for the buttons on screen.
    func hudCustom(_ piece: HUDPiece) -> HUDOffset? {
        guard let v = hudLayoutStore[piece.rawValue], v.count == 3 else { return nil }
        return HUDOffset(dx: v[0], dy: v[1], scale: v[2])
    }
    func hudOffset(_ piece: HUDPiece, _ context: HUDTouchContext) -> HUDOffset { hudCustom(piece) ?? HUDGeometry.touchDefault(piece, context) }
    /// nil: back to the piece's own place.
    func setHudOffset(_ piece: HUDPiece, _ offset: HUDOffset?) {
        var store = hudLayoutStore
        store[piece.rawValue] = offset.map { [$0.dx, $0.dy, $0.scale] }
        hudLayoutStore = store
    }
    /// The buttons on screen now (NativePortViewController keeps it current); the HUD layout editor shows the touch ones.
    static var hudContext: HUDTouchContext = .situational
    var editorHUDContext: HUDTouchContext { touchScheme == .controller ? .pad : .situational }
    /// The FPS counter's chosen place (fractions of the room in the safe area, from its top left); nil: its own place,
    /// which moves to the bottom left when the minimap is at the top.
    var fpsPlace: CGPoint? {
        get {
            guard let v = UserDefaults.standard.array(forKey: "fpsPlace") as? [Double], v.count == 2 else { return nil }
            return CGPoint(x: v[0], y: v[1])
        }
        set { UserDefaults.standard.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "fpsPlace") }
    }
    /// Back to the help messages' own place (which depends on the minimap's).
    func resetHelpTextPlace() { UserDefaults.standard.removeObject(forKey: "helpTextPlace") }
    /// Hands the engine the pieces it places (before the engine starts; the wheel and phone also during play).
    func applyHUDLayout(_ context: HUDTouchContext = GameSettings.hudContext, screen: CGSize = UIScreen.main.bounds.size) {
        // The phone's sideways units follow the screen's height: on a screen narrower than 16:9 (the HUD area is then the
        // whole width) a HUD unit is fewer of them.
        let long = max(screen.width, screen.height), short = max(1, min(screen.width, screen.height))
        let narrow = min(long / short, 16.0 / 9) / (16.0 / 9)
        for piece in HUDPiece.allCases {
            guard let index = piece.engineIndex else { continue }
            let offset = hudOffset(piece, context)
            PGSetHudPiece(index, piece == .phone ? offset.dx * narrow : offset.dx, offset.dy, offset.scale)
        }
    }
    /// Whether any piece is away from its own place (for the Settings row).
    var hudLayoutCustomized: Bool { !hudLayoutStore.isEmpty || fpsPlace != nil || minimapPlace != .bottomLeft || helpTextPlace != defaultHelpTextPlace }
}

/// Settings › Touch controls › HUD layout (GTA-197): every movable piece of the HUD as a box, over the touch controls
/// shown dimmed. Drag a box to move it; pinch the minimap or the character wheel to resize it. Reset puts the chosen
/// piece back, Reset all every piece. The minimap, help messages and the game's own HUD pieces change the next time the
/// game starts; the FPS counter, the character wheel and the phone at once.
final class HUDLayoutEditorController: UIViewController {
    var onDone: (() -> Void)?
    private let settings = GameSettings.shared
    private let background = UIImageView()
    private let controls = TouchControlsView(frame: .zero)
    /// The Controller buttons touch scheme (GTA-195): its buttons show instead, with Settings and Mods from the layer above.
    private let pad = ControllerPadView(frame: .zero)
    private let toolbar = UIStackView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let resetButton = UIButton(type: .system)
    private var boxes: [HUDPiece: HUDPieceBox] = [:]
    private var selected: HUDPiece?
    private var dragOffset = CGPoint.zero
    private var pinchStart = CGRect.zero
    private let lowMemory: Bool

    // The places being edited; saved on Done.
    private var minimap: (dx: Double, dy: Double, scale: Double)
    private var help: (x: Double, y: Double, scale: Double)
    private var helpAtDefault: Bool
    private var offsets: [HUDPiece: HUDOffset] = [:]
    private var fps: CGPoint?
    private var changed = Set<HUDPiece>()
    /// The game's pieces still at their own place (for the touch buttons the editor shows).
    private var atDefault = Set<HUDPiece>()
    private let context: HUDTouchContext

    init(select piece: HUDPiece? = nil) {
        let settings = GameSettings.shared
        minimap = settings.minimapLayout
        help = settings.helpTextLayout
        helpAtDefault = UserDefaults.standard.object(forKey: "helpTextPlace") == nil
        fps = settings.fpsPlace
        self.lowMemory = HUDGeometry.fpsLowMemoryMark
        selected = piece
        context = settings.editorHUDContext
        super.init(nibName: nil, bundle: nil)
        for piece in HUDPiece.allCases where piece.engineIndex != nil {
            offsets[piece] = settings.hudOffset(piece, context)
            if settings.hudCustom(piece) == nil { atDefault.insert(piece) }
        }
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.16, green: 0.2, blue: 0.24, alpha: 1)
        background.contentMode = .scaleAspectFill
        background.clipsToBounds = true
        background.alpha = 0.55
        background.image = UIImage(named: "LaunchBackground")
        // The touch buttons, dimmed, so the pieces can be kept clear of them (they have their own editor).
        controls.editing = true
        controls.isUserInteractionEnabled = false
        controls.alpha = 0.3
        controls.updateContext(vehicle: 0, pauseMenu: false)
        controls.updateVisibility()
        let padScheme = settings.touchScheme == .controller
        if padScheme {
            controls.editing = false
            controls.controllerOnly = true
            pad.editing = true
            pad.isUserInteractionEnabled = false
            pad.alpha = 0.3
        }
        for item in [background] + (padScheme ? [pad, controls] : [controls]) as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
            NSLayoutConstraint.activate([
                item.leadingAnchor.constraint(equalTo: view.leadingAnchor), item.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                item.topAnchor.constraint(equalTo: view.topAnchor), item.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        for piece in HUDPiece.allCases {
            let box = HUDPieceBox(piece)
            boxes[piece] = box
            view.addSubview(box)
        }

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        noteLabel.textAlignment = .center
        noteLabel.numberOfLines = 2
        resetButton.setTitle(AppLanguage.choose("Reset"), for: .normal)
        resetButton.addAction(UIAction { [weak self] _ in self?.reset(self?.selected) }, for: .touchUpInside)
        let resetAll = UIButton(type: .system)
        resetAll.setTitle(AppLanguage.choose("Reset all"), for: .normal)
        resetAll.addAction(UIAction { [weak self] _ in self?.resetAll() }, for: .touchUpInside)
        let done = UIButton(type: .system)
        done.setTitle(AppLanguage.choose("Done"), for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [resetButton, resetAll, done])
        buttons.spacing = 22
        buttons.alignment = .center
        for item in [titleLabel, noteLabel, buttons] as [UIView] { toolbar.addArrangedSubview(item) }
        toolbar.axis = .vertical
        toolbar.alignment = .center
        toolbar.spacing = 2
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16)
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        toolbar.layer.cornerRadius = 14
        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        // Top centre, where the game draws nothing of its own.
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            toolbar.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for gesture in [pan, tap, pinch] as [UIGestureRecognizer] { gesture.delegate = self; view.addGestureRecognizer(gesture) }
        updateToolbar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for piece in HUDPiece.allCases { boxes[piece]?.frame = frame(of: piece) }
        view.bringSubviewToFront(toolbar)
    }

    // MARK: Places
    private var safe: CGRect { view.safeAreaLayoutGuide.layoutFrame }
    private func frame(of piece: HUDPiece) -> CGRect {
        switch piece {
        case .minimap: return MinimapGeometry.rect(minimap, in: view.bounds)
        case .helpText: return HelpTextGeometry.rect(helpAtDefault ? settings.helpTextLayout(for: defaultHelpPlace) : help, in: view.bounds)
        case .fps:
            let size = HUDGeometry.fpsSize(lowMemory: lowMemory)
            return fps.map { HUDGeometry.fpsRect($0, in: safe, size: size) } ?? HUDGeometry.fpsDefault(in: safe, size: size, minimapAtTop: minimapAtTop, context: context, helpTopLeft: helpAtDefault ? defaultHelpPlace == .topLeft : help == (0, 0, 1))
        case .feed:
            // The feed follows the minimap sideways.
            var rect = HUDGeometry.rect(piece, offsets[piece] ?? .zero, in: view.bounds)
            rect.origin.x += CGFloat(minimap.dx - settings.minimapLayout.dx) * MinimapGeometry.hudArea(view.bounds).width
            return rect
        default: return HUDGeometry.rect(piece, offsets[piece] ?? .zero, in: view.bounds)
        }
    }
    /// The minimap in the top half (as GameSettings.minimapAtTop, for the place being edited).
    private var minimapAtTop: Bool { minimap.dy < -0.4 && minimap.dx < 0.25 }
    private var defaultHelpPlace: GameSettings.HelpTextPlace { minimapAtTop ? .topRight : context == .pad ? .topMiddle : .topLeft }

    /// Puts a piece at a frame (kept on screen; the FPS counter inside the safe area) and keeps its place.
    private func place(_ piece: HUDPiece, _ frame: CGRect) {
        var frame = frame
        var room = piece == .fps ? safe : view.bounds
        if piece == .phone { room.size.height += 0.03 * view.bounds.height }   // its own place hangs off the bottom a little
        if HUDGeometry.movesSidewaysOnly(piece), let box = boxes[piece] { frame.origin.y = box.frame.minY }
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
        switch piece {
        case .minimap: minimap = MinimapGeometry.layout(for: frame, in: view.bounds)
        case .helpText: help = HelpTextGeometry.layout(for: frame, in: view.bounds); helpAtDefault = false
        case .fps: fps = HUDGeometry.fpsPlace(for: frame, in: safe)
        case .feed:
            var unshifted = frame
            unshifted.origin.x -= CGFloat(minimap.dx - settings.minimapLayout.dx) * MinimapGeometry.hudArea(view.bounds).width
            offsets[piece] = HUDGeometry.offset(piece, for: unshifted, in: view.bounds)
        default: offsets[piece] = HUDGeometry.offset(piece, for: frame, in: view.bounds)
        }
        atDefault.remove(piece)
        changed.insert(piece)
        boxes[piece]?.frame = frame
        // Pieces that follow the minimap.
        if piece == .minimap { for other in [HUDPiece.feed, .helpText, .fps] { boxes[other]?.frame = self.frame(of: other) } }
    }

    private func reset(_ piece: HUDPiece?) {
        guard let piece else { return }
        switch piece {
        case .minimap: minimap = (0, 0, 1)
        case .helpText: helpAtDefault = true
        case .fps: fps = nil
        default: offsets[piece] = HUDGeometry.touchDefault(piece, context); atDefault.insert(piece)
        }
        changed.insert(piece)
        UIView.animate(withDuration: 0.2) { self.view.setNeedsLayout(); self.view.layoutIfNeeded() }
    }
    private func resetAll() {
        for piece in HUDPiece.allCases { reset(piece) }
    }

    private func select(_ piece: HUDPiece?) {
        selected = piece
        updateToolbar()
    }
    private func updateToolbar() {
        for (piece, box) in boxes { box.isSelected = piece == selected }
        if let piece = selected { view.bringSubviewToFront(boxes[piece]!); view.bringSubviewToFront(toolbar) }
        titleLabel.text = selected?.title ?? AppLanguage.choose("HUD layout")
        if let piece = selected {
            noteLabel.text = HUDGeometry.movesSidewaysOnly(piece) ? AppLanguage.choose("Moves sideways only. Changes apply the next time the game starts.")
                : piece.needsRestart ? AppLanguage.choose("Changes apply the next time the game starts.")
                : piece.resizable ? AppLanguage.choose("Pinch to resize.") : AppLanguage.choose("Changes apply at once.")
            if piece.resizable && piece.needsRestart { noteLabel.text = AppLanguage.choose("Pinch to resize. Changes apply the next time the game starts.") }
        } else {
            noteLabel.text = AppLanguage.choose("Drag a piece to move it.")
        }
        resetButton.isEnabled = selected != nil
    }

    /// The piece under a point: the chosen one first, then the smallest (so a small piece over a big one can be picked).
    private func piece(at point: CGPoint) -> HUDPiece? {
        if let selected, let box = boxes[selected], box.frame.insetBy(dx: -8, dy: -8).contains(point) { return selected }
        return HUDPiece.allCases.filter { boxes[$0]?.frame.insetBy(dx: -6, dy: -6).contains(point) == true }
            .min { (boxes[$0]!.frame.width * boxes[$0]!.frame.height) < (boxes[$1]!.frame.width * boxes[$1]!.frame.height) }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        select(piece(at: gesture.location(in: view)))
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let moved = gesture.translation(in: view)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            guard let piece = piece(at: start), let box = boxes[piece] else { select(nil); return }
            select(piece)
            dragOffset = CGPoint(x: box.frame.minX - start.x, y: box.frame.minY - start.y)
        case .changed:
            guard let piece = selected, let box = boxes[piece] else { return }
            place(piece, CGRect(origin: CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y), size: box.frame.size))
        default:
            break
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let piece = selected, piece.resizable, let box = boxes[piece] else { return }
        switch gesture.state {
        case .began:
            pinchStart = box.frame
        case .changed:
            let base = piece == .minimap ? MinimapGeometry.rect((0, 0, 1), in: view.bounds).size : HUDGeometry.rect(piece, .zero, in: view.bounds).size
            let scale = max(0.6, min(1.8, pinchStart.width / base.width * gesture.scale))
            let size = CGSize(width: base.width * scale, height: base.height * scale)
            // Around the point the game sizes it from.
            place(piece, HUDGeometry.resized(piece, pinchStart, to: size))
        default:
            break
        }
    }

    // MARK: Saving
    private func finish() {
        for piece in changed {
            switch piece {
            case .minimap:
                settings.minimapCustom = minimap
                settings.minimapPlace = minimap == (0, 0, 1) ? .bottomLeft : minimap == (0, -0.79, 1) ? .topLeft : .custom
            case .helpText:
                if helpAtDefault { settings.resetHelpTextPlace() } else { settings.helpTextCustom = help; settings.helpTextPlace = .custom }
            case .fps: settings.fpsPlace = fps
            default: settings.setHudOffset(piece, atDefault.contains(piece) ? nil : offsets[piece] ?? .zero)
            }
        }
        settings.applyHUDLayout()
        onDone?()
        dismiss(animated: true)
    }

    // MARK: Tests (debug channel "hudedit")
    /// hudedit <piece> <dx> <dy> [scale]: moves a piece by points as a drag would (and resizes it); hudedit reset <piece>|all;
    /// hudedit done; hudedit frames: every piece's frame.
    func debugEdit(_ arguments: [String]) -> [String: Any] {
        func frames() -> [String: [Double]] {
            Dictionary(uniqueKeysWithValues: HUDPiece.allCases.compactMap { piece in boxes[piece].map { (piece.rawValue, [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init)) } })
        }
        switch arguments.first {
        case "frames": return ["ok": true, "frames": frames(), "bounds": [Double(view.bounds.width), Double(view.bounds.height)]]
        case "done": finish(); return ["ok": true]
        case "reset":
            if arguments.count > 1, arguments[1] == "all" { resetAll() } else if arguments.count > 1, let piece = HUDPiece(rawValue: arguments[1]) { reset(piece) }
            view.layoutIfNeeded()
            return ["ok": true, "frames": frames()]
        default:
            guard arguments.count >= 3, let piece = HUDPiece(rawValue: arguments[0]), let dx = Double(arguments[1]), let dy = Double(arguments[2]), let box = boxes[piece] else {
                return ["ok": false, "error": "hudedit <piece> <dx> <dy> [scale] | reset <piece>|all | done | frames; pieces: " + HUDPiece.allCases.map(\.rawValue).joined(separator: " ")]
            }
            select(piece)
            var frame = box.frame.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
            if arguments.count > 3, let scale = Double(arguments[3]), piece.resizable {
                let base = piece == .minimap ? MinimapGeometry.rect((0, 0, 1), in: view.bounds).size : HUDGeometry.rect(piece, .zero, in: view.bounds).size
                let size = CGSize(width: base.width * CGFloat(scale), height: base.height * CGFloat(scale))
                frame = HUDGeometry.resized(piece, frame, to: size)
            }
            place(piece, frame)
            return ["ok": true, "frames": frames()]
        }
    }
}

extension HUDLayoutEditorController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: toolbar)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }
}

/// One piece in the HUD layout editor: a box with the piece's symbol and name.
final class HUDPieceBox: UIView {
    let piece: HUDPiece
    private let icon = UIImageView()
    private let label = UILabel()
    var isSelected = false { didSet { style() } }

    init(_ piece: HUDPiece) {
        self.piece = piece
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = piece.title
        layer.cornerRadius = piece == .characterWheel ? 18 : 8
        icon.image = UIImage(systemName: piece.symbol)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        label.text = piece == .fps ? "60 FPS" : piece.title
        label.textColor = .white
        label.font = piece == .fps ? .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        for item in [icon, label] as [UIView] { item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item) }
        if piece == .fps {
            icon.isHidden = true
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        } else {
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 2),
                icon.heightAnchor.constraint(equalToConstant: 18), icon.widthAnchor.constraint(equalToConstant: 24),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            ])
        }
        style()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func style() {
        let color: UIColor
        switch piece {
        case .minimap: color = UIColor(red: 0.35, green: 0.6, blue: 0.45, alpha: 1)
        case .characterWheel: color = UIColor(red: 0.45, green: 0.4, blue: 0.75, alpha: 1)
        case .fps: color = .black
        case .phone: color = UIColor(red: 0.25, green: 0.45, blue: 0.7, alpha: 1)
        default: color = UIColor(white: 0.1, alpha: 1)
        }
        backgroundColor = color.withAlphaComponent(isSelected ? 0.85 : 0.6)
        layer.borderWidth = isSelected ? 3 : 1.5
        layer.borderColor = (isSelected ? Theme.accent : UIColor.white.withAlphaComponent(0.85)).cgColor
    }
}
