import UIKit

#if !targetEnvironment(macCatalyst)
/// "Show me how" on Game files (GTA-248): how to put the game on an iPhone, five steps, each with a small moving
/// picture of exactly what to tap. The folder and archive pickers failed on many sideloaded installs (Open stays
/// grey, the zip can't be picked), so on iPhone the way in is the app's own folder in Files (or a link): open it,
/// move the game folder or its .zip/.rar in, come back, and the app finds it and unpacks it.
final class AddGameGuideViewController: UIViewController {
    /// Opens the GTA V Port folder in Files; called after the guide closed.
    var onOpenFolder: (() -> Void)?

    private struct Step { let title: String; let text: String; let picture: () -> GuidePicture }
    private let steps: [Step] = [
        Step(title: AppLanguage.choose("Open the GTA V Port folder"),
             text: AppLanguage.choose("Tap Open the GTA V Port folder. The Files app opens at this app's own folder: that's where the game goes."),
             picture: { OpenFolderPicture() }),
        Step(title: AppLanguage.choose("Find your game"),
             text: AppLanguage.choose("In Files, tap Browse at the bottom and go to where your game is, usually Downloads. It's the unpacked game folder, or the .zip or .rar you downloaded."),
             picture: { FindGamePicture() }),
        Step(title: AppLanguage.choose("Move it into GTA V Port"),
             text: AppLanguage.choose("Touch and hold it, tap Move, pick On My iPhone › GTA V Port, then tap Move at the top. On an iPad you can also drag it onto the GTA V Port folder. Game in several parts (.part1.rar, .part2.rar…)? Move every part."),
             picture: { MovePicture() }),
        Step(title: AppLanguage.choose("Come back to this app"),
             text: AppLanguage.choose("Tap ◀ GTA V Port in the top left corner, or open the app again from your Home Screen."),
             picture: { ComeBackPicture() }),
        Step(title: AppLanguage.choose("The app finds it"),
             text: AppLanguage.choose("Back in the app, it looks in its folder by itself (or tap Look for the game). A .zip or .rar? Tap Unpack: the app unpacks it and checks every file, no unzip app needed. Then it says Ready to play."),
             picture: { FoundPicture() })
    ]
    private var index = 0
    private var picture: GuidePicture?
    private let pictureHolder = UIView()
    private let stepLabel = UILabel()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let backButton = Theme.glassButton(AppLanguage.choose("Back"), symbol: "chevron.backward")
    private let nextButton = Theme.primaryButton(AppLanguage.choose("Next"), symbol: "chevron.forward")
    private let openButton = Theme.primaryButton(AppLanguage.choose("Open the GTA V Port folder"), symbol: "arrow.up.forward.app")
    private let columns = UIStackView()
    private var pictureShare: [NSLayoutConstraint] = []   // the picture's share of the screen: width side by side, height stacked

    init(startAt page: Int = 0) {
        super.init(nibName: nil, bundle: nil)
        index = max(0, min(page, steps.count - 1))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("How to add the game")
        view.backgroundColor = Theme.night   // no artwork behind: the steps are read, not skimmed
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem?.tintColor = Theme.accent

        stepLabel.font = Theme.body(14, .semibold)
        stepLabel.textColor = Theme.accent
        titleLabel.font = Theme.display(22, .heavy)
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 0
        textLabel.font = Theme.body(16)
        textLabel.textColor = Theme.text
        textLabel.numberOfLines = 0
        backButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.show(self.index - 1, animated: true) }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.show(self.index + 1, animated: true) }, for: .touchUpInside)
        openButton.addAction(UIAction { [weak self] _ in
            let open = self?.onOpenFolder
            self?.dismiss(animated: true) { open?() }
        }, for: .touchUpInside)

        // The picture, as large as its box allows.
        let pictureBox = UIView()
        pictureHolder.translatesAutoresizingMaskIntoConstraints = false
        pictureBox.addSubview(pictureHolder)
        let fill = pictureHolder.widthAnchor.constraint(equalTo: pictureBox.widthAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pictureHolder.centerXAnchor.constraint(equalTo: pictureBox.centerXAnchor),
            pictureHolder.centerYAnchor.constraint(equalTo: pictureBox.centerYAnchor),
            pictureHolder.widthAnchor.constraint(lessThanOrEqualTo: pictureBox.widthAnchor),
            pictureHolder.heightAnchor.constraint(lessThanOrEqualTo: pictureBox.heightAnchor),
            pictureHolder.heightAnchor.constraint(equalTo: pictureHolder.widthAnchor, multiplier: GuidePicture.size.height / GuidePicture.size.width),
            fill
        ])
        // The step's words scroll when a language runs long; the buttons stay put below them.
        let texts = UIStackView(arrangedSubviews: [stepLabel, titleLabel, textLabel])
        texts.axis = .vertical
        texts.spacing = 6
        texts.setCustomSpacing(10, after: titleLabel)
        texts.translatesAutoresizingMaskIntoConstraints = false
        let textScroll = UIScrollView()
        textScroll.addSubview(texts)
        NSLayoutConstraint.activate([
            texts.topAnchor.constraint(equalTo: textScroll.contentLayoutGuide.topAnchor),
            texts.bottomAnchor.constraint(equalTo: textScroll.contentLayoutGuide.bottomAnchor),
            texts.leadingAnchor.constraint(equalTo: textScroll.contentLayoutGuide.leadingAnchor),
            texts.trailingAnchor.constraint(equalTo: textScroll.contentLayoutGuide.trailingAnchor),
            texts.widthAnchor.constraint(equalTo: textScroll.frameLayoutGuide.widthAnchor)
        ])
        textScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        // "Step 3 of 5" above shows where you are; Back and Next keep their words on one line in every language.
        let buttons = UIStackView(arrangedSubviews: [backButton, UIView(), nextButton])
        buttons.alignment = .center
        buttons.spacing = 8
        for button in [backButton, nextButton] { button.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let side = UIStackView(arrangedSubviews: [textScroll, openButton, buttons])
        side.axis = .vertical
        side.spacing = 14

        columns.addArrangedSubview(pictureBox)
        columns.addArrangedSubview(side)
        columns.spacing = 28
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        let guide = view.safeAreaLayoutGuide
        let wide = columns.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -40)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            columns.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            columns.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            columns.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
            columns.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -40),
            wide
        ])
        pictureShare = [pictureBox.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.5, constant: -14),
                        pictureBox.heightAnchor.constraint(equalTo: columns.heightAnchor, multiplier: 0.45)]

        // A swipe turns the page too.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        show(index, animated: false)
    }

    /// Side by side when the screen is wider than tall (the game runs in landscape), one above the other otherwise.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let wide = view.bounds.width > view.bounds.height
        columns.axis = wide ? .horizontal : .vertical
        columns.alignment = .fill
        pictureShare[0].isActive = wide
        pictureShare[1].isActive = !wide
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        picture?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        picture?.stop()
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        show(index + (swipe.direction == .left ? 1 : -1), animated: true)
    }

    private func show(_ page: Int, animated: Bool) {
        guard page >= 0, page < steps.count else { return }
        let changed = page != index || picture == nil
        index = page
        let step = steps[page]
        stepLabel.text = AppLanguage.interpolate(AppLanguage.choose("Step {arg0} of {arg1}"), [String(page + 1), String(steps.count)])
        titleLabel.text = step.title
        textLabel.text = step.text
        backButton.isHidden = page == 0
        nextButton.isHidden = page == steps.count - 1
        openButton.isHidden = page != steps.count - 1
        guard changed else { return }
        picture?.stop()
        picture?.removeFromSuperview()
        let next = step.picture()
        next.frame = pictureHolder.bounds
        next.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pictureHolder.addSubview(next)
        picture = next
        if animated {
            next.alpha = 0
            UIView.animate(withDuration: 0.25) { next.alpha = 1 }
        }
        if view.window != nil { next.play() }
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }
}

// MARK: Pictures

/// A small moving picture drawn on a fixed 320 x 220 canvas, scaled to fit. Each one is a list of beats (one
/// animated change each) that repeats; with Reduce Motion on it shows the last beat's result and stays still.
class GuidePicture: UIView {
    static let size = CGSize(width: 320, height: 220)
    let canvas = UIView(frame: CGRect(origin: .zero, size: GuidePicture.size))
    let finger = UIImageView(image: UIImage(systemName: "hand.point.up.left.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)))
    private var beats: [(TimeInterval, () -> Void)] = []
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        clipsToBounds = true   // screens slide in from outside the canvas
        addSubview(canvas)
        finger.tintColor = .white
        finger.layer.shadowColor = UIColor.black.cgColor
        finger.layer.shadowOpacity = 0.6
        finger.layer.shadowRadius = 6
        finger.layer.shadowOffset = CGSize(width: 0, height: 3)
        build()
        canvas.addSubview(finger)
        reset()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Subclasses add their views to `canvas` and their beats with `beat`.
    func build() {}
    /// Puts every view back where the picture starts.
    func reset() {}

    func beat(_ duration: TimeInterval, _ change: @escaping () -> Void) { beats.append((duration, change)) }

    /// Puts the fingertip (top left of the hand) on a point of the canvas.
    func point(at spot: CGPoint) {
        finger.transform = .identity
        finger.frame.origin = CGPoint(x: spot.x - 7, y: spot.y - 3)
    }
    func press(_ down: Bool) { finger.transform = down ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity }

    func play() {
        generation += 1
        if UIAccessibility.isReduceMotionEnabled {
            reset()
            beats.forEach { $0.1() }
            finger.alpha = 0
            return
        }
        UIView.performWithoutAnimation(reset)
        run(0, generation)
    }
    func stop() { generation += 1 }

    private func run(_ i: Int, _ playing: Int) {
        guard playing == generation else { return }
        guard i < beats.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, playing == self.generation else { return }
                UIView.performWithoutAnimation(self.reset)
                self.run(0, playing)
            }
            return
        }
        UIView.animate(withDuration: beats[i].0, delay: 0.12, options: [.curveEaseInOut, .allowUserInteraction], animations: beats[i].1) { [weak self] _ in
            self?.run(i + 1, playing)
        }
    }

    // Building blocks that look like the iPhone's own screens (dark appearance).

    static let filesBlue = UIColor.systemBlue
    static func screen(_ frame: CGRect) -> UIView {
        let view = UIView(frame: frame)
        view.backgroundColor = UIColor(white: 0.09, alpha: 1)
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        view.clipsToBounds = true
        return view
    }
    static func label(_ text: String, _ size: CGFloat, _ weight: UIFont.Weight = .regular, color: UIColor = .white, frame: CGRect) -> UILabel {
        let label = UILabel(frame: frame)
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        return label
    }
    static func icon(_ symbol: String, _ size: CGFloat, color: UIColor, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)))
        view.tintColor = color
        view.contentMode = .center
        view.frame = frame
        return view
    }
    /// A row of a Files list: icon and name.
    static func row(_ symbol: String, _ name: String, color: UIColor, frame: CGRect) -> UIView {
        let row = UIView(frame: frame)
        row.backgroundColor = UIColor(white: 0.17, alpha: 1)
        row.layer.cornerRadius = 10
        row.layer.cornerCurve = .continuous
        row.addSubview(icon(symbol, 20, color: color, frame: CGRect(x: 8, y: 0, width: 34, height: frame.height)))
        row.addSubview(label(name, 15, .medium, frame: CGRect(x: 48, y: 0, width: frame.width - 56, height: frame.height)))
        return row
    }
    /// The app's orange button.
    static func appButton(_ title: String, symbol: String, frame: CGRect) -> UIView {
        let button = UIView(frame: frame)
        button.backgroundColor = Theme.accent
        button.layer.cornerRadius = frame.height / 2
        let dark = UIColor(red: 0.16, green: 0.07, blue: 0.02, alpha: 1)
        button.addSubview(icon(symbol, 14, color: dark, frame: CGRect(x: 10, y: 0, width: 24, height: frame.height)))
        let text = label(title, 14, .heavy, color: dark, frame: CGRect(x: 36, y: 0, width: frame.width - 46, height: frame.height))
        button.addSubview(text)
        return button
    }
    /// The app's own screen behind its buttons: dark, with the name on top.
    static func appScreen(_ frame: CGRect) -> UIView {
        let view = screen(frame)
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 1)
        view.addSubview(label("GTA V Port", 17, .heavy, frame: CGRect(x: 18, y: 14, width: frame.width - 36, height: 24)))
        return view
    }
}

/// Step 1: tap Open the GTA V Port folder, and Files opens at that (still empty) folder.
private final class OpenFolderPicture: GuidePicture {
    private let app = GuidePicture.appScreen(CGRect(x: 30, y: 8, width: 260, height: 204))
    private let button = GuidePicture.appButton(AppLanguage.choose("Open the GTA V Port folder"), symbol: "arrow.up.forward.app", frame: CGRect(x: 18, y: 86, width: 224, height: 40))
    private let files = GuidePicture.screen(CGRect(x: 30, y: 8, width: 260, height: 204))

    override func build() {
        app.addSubview(button)
        canvas.addSubview(app)
        files.addSubview(GuidePicture.label("‹ " + AppLanguage.choose("On My iPhone"), 13, color: GuidePicture.filesBlue, frame: CGRect(x: 14, y: 12, width: 200, height: 18)))
        files.addSubview(GuidePicture.label("GTA V Port", 24, .bold, frame: CGRect(x: 14, y: 34, width: 230, height: 30)))
        files.addSubview(GuidePicture.icon("folder", 54, color: UIColor(white: 1, alpha: 0.18), frame: CGRect(x: 80, y: 82, width: 100, height: 90)))
        canvas.addSubview(files)
        beat(0.6) { self.finger.alpha = 1; self.point(at: CGPoint(x: 160, y: 114)) }
        beat(0.15) { self.press(true); self.button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95); self.button.alpha = 0.8 }
        beat(0.15) { self.press(false); self.button.transform = .identity; self.button.alpha = 1 }
        beat(0.5) { self.finger.alpha = 0; self.files.transform = .identity }
    }
    override func reset() {
        finger.alpha = 0
        point(at: CGPoint(x: 240, y: 200))
        files.transform = CGAffineTransform(translationX: 0, y: 230)
    }
}

/// Step 2: Browse at the bottom of Files, then the game in Downloads (the folder or the archive).
private final class FindGamePicture: GuidePicture {
    private let files = GuidePicture.screen(CGRect(x: 30, y: 8, width: 260, height: 204))
    private let list = UIView(frame: CGRect(x: 0, y: 0, width: 260, height: 160))
    private let folderRow = GuidePicture.row("folder.fill", "GTA V", color: GuidePicture.filesBlue, frame: CGRect(x: 12, y: 56, width: 236, height: 40))
    private let archiveRow = GuidePicture.row("doc.zipper", "GTA V.zip", color: UIColor(white: 0.8, alpha: 1), frame: CGRect(x: 12, y: 102, width: 236, height: 40))
    private let browse = UIView(frame: CGRect(x: 160, y: 164, width: 90, height: 36))

    override func build() {
        list.addSubview(GuidePicture.label(AppLanguage.choose("Downloads"), 24, .bold, frame: CGRect(x: 14, y: 14, width: 230, height: 30)))
        list.addSubview(folderRow)
        list.addSubview(archiveRow)
        files.addSubview(list)
        let bar = UIView(frame: CGRect(x: 0, y: 160, width: 260, height: 44))
        bar.backgroundColor = UIColor(white: 0.13, alpha: 1)
        files.addSubview(bar)
        files.addSubview(GuidePicture.icon("clock.fill", 18, color: UIColor(white: 1, alpha: 0.4), frame: CGRect(x: 30, y: 166, width: 40, height: 22)))
        browse.addSubview(GuidePicture.icon("folder.fill", 18, color: GuidePicture.filesBlue, frame: CGRect(x: 0, y: 2, width: 90, height: 20)))
        let name = GuidePicture.label(AppLanguage.choose("Browse"), 10, .semibold, color: GuidePicture.filesBlue, frame: CGRect(x: 0, y: 22, width: 90, height: 12))
        name.textAlignment = .center
        browse.addSubview(name)
        files.addSubview(browse)
        canvas.addSubview(files)
        beat(0.6) { self.finger.alpha = 1; self.point(at: CGPoint(x: 235, y: 180)) }
        beat(0.15) { self.press(true); self.browse.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }
        beat(0.15) { self.press(false); self.browse.transform = .identity }
        beat(0.4) { self.list.alpha = 1; self.point(at: CGPoint(x: 230, y: 140)) }
        beat(0.35) { self.highlight(self.folderRow, true) }
        beat(0.35) { self.highlight(self.folderRow, false); self.highlight(self.archiveRow, true) }
        beat(0.35) { self.highlight(self.archiveRow, false); self.highlight(self.folderRow, true) }
        beat(0.35) { self.highlight(self.folderRow, false); self.highlight(self.archiveRow, true); self.finger.alpha = 0 }
    }
    private func highlight(_ row: UIView, _ on: Bool) {
        row.backgroundColor = on ? Theme.accent.withAlphaComponent(0.45) : UIColor(white: 0.17, alpha: 1)
        row.transform = on ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
    }
    override func reset() {
        finger.alpha = 0
        point(at: CGPoint(x: 260, y: 230))
        list.alpha = 0
        highlight(folderRow, false)
        highlight(archiveRow, false)
    }
}

/// Step 3: touch and hold the archive, Move, pick On My iPhone › GTA V Port, Move. The archive leaves Downloads.
private final class MovePicture: GuidePicture {
    private let files = GuidePicture.screen(CGRect(x: 30, y: 8, width: 260, height: 204))
    private let archiveRow = GuidePicture.row("doc.zipper", "GTA V.zip", color: UIColor(white: 0.8, alpha: 1), frame: CGRect(x: 12, y: 50, width: 236, height: 40))
    private let folderRow = GuidePicture.row("folder.fill", "GTA V", color: GuidePicture.filesBlue, frame: CGRect(x: 12, y: 96, width: 236, height: 40))
    private let menu = UIView(frame: CGRect(x: 96, y: 94, width: 150, height: 84))
    private let moveItem = UIView(frame: CGRect(x: 0, y: 28, width: 150, height: 28))
    private let sheet = UIView(frame: CGRect(x: 0, y: 40, width: 260, height: 164))
    private let portRow = GuidePicture.row("folder.fill", "GTA V Port", color: GuidePicture.filesBlue, frame: CGRect(x: 26, y: 78, width: 222, height: 36))
    private let sheetMove = UILabel()

    override func build() {
        files.addSubview(GuidePicture.label(AppLanguage.choose("Downloads"), 24, .bold, frame: CGRect(x: 14, y: 14, width: 230, height: 30)))
        files.addSubview(folderRow)
        files.addSubview(archiveRow)
        menu.backgroundColor = UIColor(white: 0.24, alpha: 1)
        menu.layer.cornerRadius = 12
        menu.clipsToBounds = true
        for (i, item) in [(AppLanguage.choose("Copy"), "doc.on.doc"), (AppLanguage.choose("Move"), "folder"), (AppLanguage.choose("Share"), "square.and.arrow.up")].enumerated() {
            let row = i == 1 ? moveItem : UIView(frame: CGRect(x: 0, y: CGFloat(i) * 28, width: 150, height: 28))
            row.addSubview(GuidePicture.label(item.0, 14, frame: CGRect(x: 12, y: 0, width: 100, height: 28)))
            row.addSubview(GuidePicture.icon(item.1, 14, color: .white, frame: CGRect(x: 116, y: 0, width: 26, height: 28)))
            menu.addSubview(row)
        }
        files.addSubview(menu)
        sheet.backgroundColor = UIColor(white: 0.15, alpha: 1)
        sheet.layer.cornerRadius = 16
        sheet.addSubview(GuidePicture.label(AppLanguage.choose("Move"), 15, .semibold, frame: CGRect(x: 14, y: 10, width: 120, height: 20)))
        sheetMove.frame = CGRect(x: 170, y: 10, width: 76, height: 20)
        sheetMove.text = AppLanguage.choose("Move")
        sheetMove.font = .systemFont(ofSize: 15, weight: .bold)
        sheetMove.textColor = GuidePicture.filesBlue
        sheetMove.textAlignment = .right
        sheetMove.adjustsFontSizeToFitWidth = true
        sheet.addSubview(sheetMove)
        sheet.addSubview(GuidePicture.row("iphone", AppLanguage.choose("On My iPhone"), color: UIColor(white: 0.8, alpha: 1), frame: CGRect(x: 12, y: 38, width: 236, height: 36)))
        sheet.addSubview(portRow)
        files.addSubview(sheet)
        canvas.addSubview(files)
        // Touch and hold the archive: it lifts and the menu opens.
        beat(0.6) { self.finger.alpha = 1; self.point(at: CGPoint(x: 120, y: 80)) }
        beat(0.5) { self.press(true); self.archiveRow.transform = CGAffineTransform(scaleX: 1.04, y: 1.04); self.archiveRow.backgroundColor = UIColor(white: 0.26, alpha: 1) }
        beat(0.3) { self.press(false); self.menu.alpha = 1; self.menu.transform = .identity; self.point(at: CGPoint(x: 112, y: 104)) }
        // Move.
        beat(0.4) { self.point(at: CGPoint(x: 180, y: 142)) }
        beat(0.15) { self.press(true); self.moveItem.backgroundColor = UIColor(white: 1, alpha: 0.18) }
        beat(0.15) { self.press(false) }
        // The folder list: On My iPhone › GTA V Port, then Move at the top.
        beat(0.45) { self.menu.alpha = 0; self.archiveRow.transform = .identity; self.sheet.transform = .identity; self.point(at: CGPoint(x: 150, y: 175)) }
        beat(0.4) { self.point(at: CGPoint(x: 140, y: 142)) }
        beat(0.15) { self.press(true); self.portRow.backgroundColor = Theme.accent.withAlphaComponent(0.45) }
        beat(0.15) { self.press(false) }
        beat(0.45) { self.point(at: CGPoint(x: 268, y: 66)) }
        beat(0.15) { self.press(true); self.sheetMove.alpha = 0.5 }
        beat(0.15) { self.press(false); self.sheetMove.alpha = 1 }
        // Done: the archive is in GTA V Port now, gone from Downloads.
        beat(0.45) { self.finger.alpha = 0; self.sheet.transform = CGAffineTransform(translationX: 0, y: 180); self.archiveRow.alpha = 0; self.archiveRow.transform = CGAffineTransform(translationX: 60, y: 0) }
    }
    override func reset() {
        finger.alpha = 0
        point(at: CGPoint(x: 260, y: 230))
        archiveRow.alpha = 1
        archiveRow.transform = .identity
        archiveRow.backgroundColor = UIColor(white: 0.17, alpha: 1)
        menu.alpha = 0
        menu.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        moveItem.backgroundColor = .clear
        sheet.transform = CGAffineTransform(translationX: 0, y: 180)
        portRow.backgroundColor = UIColor(white: 0.17, alpha: 1)
        sheetMove.alpha = 1
    }
}

/// Step 4: ◀ GTA V Port in the top left corner brings the app back.
private final class ComeBackPicture: GuidePicture {
    private let files = GuidePicture.screen(CGRect(x: 30, y: 8, width: 260, height: 204))
    private let back = UIView(frame: CGRect(x: 8, y: 6, width: 104, height: 22))
    private let app = GuidePicture.appScreen(CGRect(x: 30, y: 8, width: 260, height: 204))

    override func build() {
        back.addSubview(GuidePicture.icon("arrowtriangle.backward.fill", 9, color: .white, frame: CGRect(x: 0, y: 0, width: 14, height: 22)))
        back.addSubview(GuidePicture.label("GTA V Port", 12, .semibold, frame: CGRect(x: 16, y: 0, width: 88, height: 22)))
        files.addSubview(back)
        files.addSubview(GuidePicture.label("GTA V Port", 24, .bold, frame: CGRect(x: 14, y: 40, width: 230, height: 30)))
        files.addSubview(GuidePicture.row("doc.zipper", "GTA V.zip", color: UIColor(white: 0.8, alpha: 1), frame: CGRect(x: 12, y: 82, width: 236, height: 40)))
        canvas.addSubview(files)
        app.addSubview(GuidePicture.icon("magnifyingglass", 34, color: UIColor(white: 1, alpha: 0.5), frame: CGRect(x: 80, y: 80, width: 100, height: 70)))
        canvas.addSubview(app)
        beat(0.6) { self.finger.alpha = 1; self.point(at: CGPoint(x: 70, y: 26)) }
        beat(0.15) { self.press(true); self.back.alpha = 0.5 }
        beat(0.15) { self.press(false); self.back.alpha = 1 }
        beat(0.5) { self.finger.alpha = 0; self.app.transform = .identity }
    }
    override func reset() {
        finger.alpha = 0
        point(at: CGPoint(x: 200, y: 200))
        back.alpha = 1
        app.transform = CGAffineTransform(translationX: -300, y: 0)
    }
}

/// Step 5: the app looks, finds the archive, Unpack, and Ready to play.
private final class FoundPicture: GuidePicture {
    private let app = GuidePicture.appScreen(CGRect(x: 30, y: 8, width: 260, height: 204))
    private let card = UIView(frame: CGRect(x: 14, y: 50, width: 232, height: 140))
    private let statusIcon = UIImageView()
    private let statusTitle = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let unpack = GuidePicture.appButton(AppLanguage.choose("Unpack"), symbol: "archivebox", frame: CGRect(x: 16, y: 72, width: 130, height: 36))
    private let bar = UIProgressView(progressViewStyle: .default)

    override func build() {
        card.backgroundColor = UIColor(white: 1, alpha: 0.08)
        card.layer.cornerRadius = 16
        statusIcon.frame = CGRect(x: 14, y: 16, width: 34, height: 34)
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        card.addSubview(statusIcon)
        spinner.frame = statusIcon.frame
        spinner.color = .white
        card.addSubview(spinner)
        statusTitle.frame = CGRect(x: 56, y: 16, width: 166, height: 34)
        statusTitle.font = .systemFont(ofSize: 16, weight: .bold)
        statusTitle.textColor = .white
        statusTitle.numberOfLines = 2
        statusTitle.adjustsFontSizeToFitWidth = true
        statusTitle.minimumScaleFactor = 0.6
        card.addSubview(statusTitle)
        card.addSubview(unpack)
        bar.frame = CGRect(x: 16, y: 118, width: 200, height: 4)
        bar.progressTintColor = Theme.accent
        bar.trackTintColor = UIColor(white: 1, alpha: 0.15)
        card.addSubview(bar)
        app.addSubview(card)
        canvas.addSubview(app)
        beat(1.0) { self.spinner.alpha = 1 }
        beat(0.3) { self.status(nil, AppLanguage.choose("Found a game archive")); self.unpack.alpha = 1 }
        beat(0.5) { self.finger.alpha = 1; self.point(at: CGPoint(x: 120, y: 147)) }
        beat(0.15) { self.press(true); self.unpack.transform = CGAffineTransform(scaleX: 0.95, y: 0.95) }
        beat(0.15) { self.press(false); self.unpack.transform = .identity }
        beat(0.3) { self.finger.alpha = 0; self.unpack.alpha = 0; self.bar.alpha = 1 }
        beat(1.6) { self.bar.setProgress(1, animated: true) }
        beat(0.4) { self.bar.alpha = 0; self.status(true, AppLanguage.choose("Ready to play")) }
    }
    private func status(_ ok: Bool?, _ title: String) {
        spinner.alpha = 0
        statusIcon.alpha = 1
        statusIcon.image = UIImage(systemName: ok == true ? "checkmark.circle.fill" : "archivebox.fill")
        statusIcon.tintColor = ok == true ? Theme.ok : Theme.warning
        statusTitle.text = title
    }
    override func reset() {
        finger.alpha = 0
        point(at: CGPoint(x: 260, y: 230))
        statusIcon.alpha = 0
        statusTitle.text = AppLanguage.choose("Looking for the game…")
        spinner.alpha = 1
        spinner.startAnimating()
        unpack.alpha = 0
        unpack.transform = .identity
        bar.alpha = 0
        bar.setProgress(0, animated: false)
    }
}
#endif
