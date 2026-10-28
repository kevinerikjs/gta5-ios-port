import UIKit
import UniformTypeIdentifiers

/// The game files screen: where the files are and whether every one of them checks out, finding them in
/// the app's own folder (on the Mac also anywhere you pick), and getting them from a link (your own game
/// server, or an archive the app downloads, unpacks and checks by itself). On iPhone the folder and archive
/// pickers are gone (GTA-248): they failed on many sideloaded installs, so the game goes into the GTA V Port
/// folder in Files, with a step-by-step guide (AddGameGuideViewController).
final class GameFilesViewController: UIViewController, UIDocumentPickerDelegate, UITextFieldDelegate {
    /// Called whenever the game files in use changed.
    var onChange: (() -> Void)?
    /// Called with a game server address the user entered (streams the files instead of storing them).
    var onServer: ((String) -> Void)?
    /// Why the saved game server didn't answer, when Play found no files because of it (GTA-153).
    var serverProblem: String?
    /// Where unpacked games go: inside the app's folder, so the app finds them like any other.
    static var installFolder: URL { GameFolder.appFolder.appendingPathComponent("GTA V") }

    private let stack = UIStackView()
    private let statusIcon = UIImageView()
    private let statusTitle = UILabel()
    private let statusDetail = UILabel()
    private let detailsButton = Theme.glassButton(AppLanguage.choose("Show every problem"), symbol: "list.bullet")
    private let anywayButton = Theme.glassButton(AppLanguage.choose("Play anyway"), symbol: "exclamationmark.triangle")
    private let continueButton = Theme.glassButton(AppLanguage.choose("Continue the download"), symbol: "arrow.clockwise")
    private let linkField = UITextField()
    private let linkButton = Theme.primaryButton(AppLanguage.choose("Continue"), symbol: "arrow.down.circle.fill")
    private let archivesStack = UIStackView()
    private let progressPanel = Theme.panel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressTitle = UILabel()
    private let progressDetail = UILabel()
    private let cancelButton = Theme.glassButton(AppLanguage.choose("Cancel"), symbol: "xmark")
    private var lastReport: GameFiles.Report?
    private var pickingArchive = false
    private var install: GameInstallManager { .shared }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("Game files")
        view.backgroundColor = Theme.night
        let backdrop = Theme.backdrop(image: "SettingsBackground", darken: 0.8)
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItem?.tintColor = Theme.accent

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            stack.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -40)
        ])
        let wide = stack.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -40)
        wide.priority = .defaultHigh
        wide.isActive = true

        stack.addArrangedSubview(statusSection())
        #if targetEnvironment(macCatalyst)
        stack.addArrangedSubview(findSection())
        stack.addArrangedSubview(linkSection())
        stack.addArrangedSubview(archiveSection())
        #else
        stack.addArrangedSubview(folderSection())
        stack.addArrangedSubview(linkSection())
        #endif
        stack.addArrangedSubview(progressSection())
        NotificationCenter.default.addObserver(self, selector: #selector(installChanged), name: .gameInstallChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil)
        // An install may already be running (started before this screen was closed).
        if install.isRunning { installChanged() } else { refresh(recheck: true) }
        // Automation: --install-link <url> starts a link install; --install-cancel-after <s> cancels it.
        let arguments = ProcessInfo.processInfo.arguments
        // Automation: --game-files-scroll-bottom shows the end of the screen (the archive card's notes).
        if arguments.contains("--game-files-scroll-bottom") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let scroll = self.stack.superview as? UIScrollView else { return }
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            }
        }
        #if !targetEnvironment(macCatalyst)
        // Automation: --add-game-guide <step> opens the guide at that step (1-5); --game-files-look taps Look for the game.
        if let i = arguments.firstIndex(of: "--add-game-guide"), i + 1 < arguments.count, let step = Int(arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showGuide(startAt: step - 1) }
        }
        if arguments.contains("--game-files-look") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.lookInAppFolder() }
        }
        #endif
        // Automation: --install-continue taps Continue the download after a few seconds (GTA-93 test).
        if arguments.contains("--install-continue") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                GameFolder.log("Automation: Continue the download (\(self.continueButton.isHidden ? "hidden" : "shown"))")
                if !self.continueButton.isHidden { self.continueInstall() }
            }
        }
        if let i = arguments.firstIndex(of: "--install-link"), i + 1 < arguments.count {
            linkField.text = arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.useLink() }
            if let c = arguments.firstIndex(of: "--install-cancel-after"), c + 1 < arguments.count, let seconds = Double(arguments[c + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + seconds) {
                    GameFolder.log("Automation: cancelling the install")
                    self.install.cancel()
                }
            }
            // Bring the progress into view.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let scroll = self.stack.superview as? UIScrollView else { return }
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            }
        }
    }

    // MARK: Sections

    private func statusSection() -> UIView {
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        statusTitle.font = Theme.display(19, .bold)
        statusTitle.textColor = Theme.text
        statusTitle.numberOfLines = 0
        statusDetail.font = Theme.body(14)
        statusDetail.textColor = Theme.secondaryText
        statusDetail.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [statusTitle, statusDetail])
        texts.axis = .vertical
        texts.spacing = 4
        let row = UIStackView(arrangedSubviews: [statusIcon, texts])
        row.spacing = 14
        row.alignment = .top
        detailsButton.addAction(UIAction { [weak self] _ in self?.showDetails() }, for: .touchUpInside)
        let check = Theme.glassButton(AppLanguage.choose("Check every file again"), symbol: "checkmark.shield")
        check.addAction(UIAction { [weak self] _ in self?.refresh(recheck: true) }, for: .touchUpInside)
        anywayButton.addAction(UIAction { [weak self] _ in self?.confirmPlayAnyway() }, for: .touchUpInside)
        anywayButton.isHidden = true
        continueButton.addAction(UIAction { [weak self] _ in self?.continueInstall() }, for: .touchUpInside)
        continueButton.isHidden = true
        let buttons = UIStackView(arrangedSubviews: [continueButton, check, detailsButton, anywayButton, UIView()])
        buttons.spacing = 10
        return card(nil, [row, buttons])
    }

    #if targetEnvironment(macCatalyst)
    private func findSection() -> UIView {
        let find = Theme.glassButton(AppLanguage.choose("Look again"), symbol: "magnifyingglass")
        find.addAction(UIAction { [weak self] _ in self?.lookInAppFolder() }, for: .touchUpInside)
        let pick = Theme.glassButton(AppLanguage.choose("Choose a folder…"), symbol: "folder")
        pick.addAction(UIAction { [weak self] _ in self?.pickFolder() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [find, pick, UIView()])
        buttons.spacing = 10
        let files = Theme.glassButton(AppLanguage.choose("Open GTA V Port in Files"), symbol: "arrow.up.forward.app")
        files.addAction(UIAction { [weak self] _ in self?.openAppFolderInFiles() }, for: .touchUpInside)
        let filesRow = UIStackView(arrangedSubviews: [files, UIView()])
        var liveContainer: [UIView] = []
        if GameFolder.insideLiveContainer {
            let first = note(AppLanguage.choose("Inside LiveContainer the picker can't open your game folder until two of its fixes are on: in LiveContainer, open GTA V Port's settings and under Fixes turn on Fix File Picker and Use LiveContainer's Bundle ID. Then choose your game folder, also one kept from an earlier version."))
            first.textColor = Theme.text
            liveContainer.append(first)
        }
        return card(AppLanguage.choose("Already on this iPhone"), liveContainer + [
            note(AppLanguage.choose("Easiest: in the Files app, move your unpacked game folder into On My iPhone › GTA V Port. The app finds it there by itself, however deep it is.")),
            note(AppLanguage.choose("This button opens that folder in Files. Move your game folder into it (touch and hold the game folder › Move), then come back: the app checks it by itself.")),
            filesRow,
            note(AppLanguage.choose("Somewhere else? Choose any folder above it, even On My iPhone itself, and the app searches everything inside.")),
            note(AppLanguage.choose("In the picker, tap the folder so you see what's inside it, then tap Open at the top. If Open stays grey (it can on some sideloaded installs), use the easiest way above.")),
            buttons
        ])
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    /// iPhone (GTA-248): the one way in that works on every install, besides a link. The game folder, or its
    /// .zip/.rar (all parts), goes into Files › On My iPhone › GTA V Port; coming back, the app looks there by itself.
    private func folderSection() -> UIView {
        archivesStack.axis = .vertical
        archivesStack.spacing = 8
        let guide = Theme.primaryButton(AppLanguage.choose("Show me how"), symbol: "play.circle.fill")
        guide.addAction(UIAction { [weak self] _ in self?.showGuide(startAt: 0) }, for: .touchUpInside)
        let files = Theme.glassButton(AppLanguage.choose("Open the GTA V Port folder"), symbol: "arrow.up.forward.app")
        files.addAction(UIAction { [weak self] _ in self?.openAppFolderInFiles() }, for: .touchUpInside)
        let find = Theme.glassButton(AppLanguage.choose("Look for the game"), symbol: "magnifyingglass")
        find.addAction(UIAction { [weak self] _ in self?.lookInAppFolder() }, for: .touchUpInside)
        var views: [UIView] = [
            note(AppLanguage.choose("Put your unpacked game folder, or the .zip or .rar it came in, into Files › On My iPhone › GTA V Port. When you come back, the app finds it by itself and unpacks an archive for you.")),
            archivesStack, guide,   // an archive found here: Unpack is the next thing to do
            UIStackView(arrangedSubviews: [files, UIView()]),
            UIStackView(arrangedSubviews: [find, UIView()])
        ]
        if GameFolder.insideLiveContainer {
            views.insert(note(AppLanguage.choose("In LiveContainer this app's folder is inside LiveContainer's own folder in Files, not directly in On My iPhone: Open the GTA V Port folder takes you there.")), at: 1)
        }
        return card(AppLanguage.choose("Put the game in the GTA V Port folder"), views)
    }

    private func showGuide(startAt step: Int) {
        guard presentedViewController == nil else { return }
        let guide = AddGameGuideViewController(startAt: step)
        guide.onOpenFolder = { [weak self] in self?.openAppFolderInFiles() }
        let navigation = UINavigationController(rootViewController: guide)
        Theme.styleNavigation(navigation)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    /// The guide opens by itself the first time this screen has nothing at all to show (no game, archive or server).
    private func showGuideOnce() {
        let key = "addGameGuideShown"
        guard !UserDefaults.standard.bool(forKey: key), !ProcessInfo.processInfo.arguments.contains("--no-add-game-guide") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.view.window != nil, self.presentedViewController == nil, !self.install.isRunning else { return }
            UserDefaults.standard.set(true, forKey: key)
            GameFolder.log("Game files: no game yet, showing the add-the-game guide")
            self.showGuide(startAt: 0)
        }
    }
    #endif

    private func linkSection() -> UIView {
        linkField.placeholder = "https://…"
        linkField.text = GameSettings.shared.assetServer
        linkField.keyboardType = .URL
        linkField.autocapitalizationType = .none
        linkField.autocorrectionType = .no
        linkField.returnKeyType = .go
        linkField.clearButtonMode = .whileEditing
        linkField.delegate = self
        linkField.textColor = Theme.text
        linkField.font = Theme.body(16)
        linkField.backgroundColor = UIColor(white: 1, alpha: 0.08)
        linkField.layer.cornerRadius = 12
        linkField.layer.cornerCurve = .continuous
        linkField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        linkField.leftViewMode = .always
        linkField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        linkField.accessibilityLabel = AppLanguage.choose("Link to your game files")
        linkButton.addAction(UIAction { [weak self] _ in self?.useLink() }, for: .touchUpInside)
        return card(AppLanguage.choose("From a link"), [
            note(AppLanguage.interpolate(AppLanguage.choose("Paste a direct link to your game archive (zip or rar): the app downloads it, unpacks it as it goes, checks every file and deletes the archive. It needs about {arg0} free, not double. Keep the app open while it works."), [GameFiles.Report.size(Self.gameBytes)])),
            note(AppLanguage.choose("A download page where you tap Download first works too: it opens here in a browser, and the app takes the download over.")),
            note(AppLanguage.choose("Or the address of your own game server (for example your computer over Tailscale): the game then streams its files from there.")),
            linkField, linkButton
        ])
    }

    #if targetEnvironment(macCatalyst)
    private func archiveSection() -> UIView {
        archivesStack.axis = .vertical
        archivesStack.spacing = 8
        let pick = Theme.glassButton(AppLanguage.choose("Choose an archive…"), symbol: "doc.zipper")
        pick.addAction(UIAction { [weak self] _ in self?.pickArchive() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [pick, UIView()])
        return card(AppLanguage.choose("From an archive in Files"), [
            note(AppLanguage.choose("Got a .zip or .rar of the game (or all parts of a multi-part one) in Files? The app unpacks it straight into its own folder and checks every file. No separate unzip app needed.")),
            // GTA-62: the two reasons players found for a picker that does nothing.
            note(AppLanguage.choose("Can't pick it? A cloud icon next to the file means it's still in iCloud Drive: move it to On My iPhone first. In LiveContainer, turn on Fix File Picker and Use LiveContainer's Bundle ID in GTA V Port's settings (under Fixes).")),
            archivesStack, buttons
        ])
    }
    #endif

    private func progressSection() -> UIView {
        progressTitle.font = Theme.body(16, .semibold)
        progressTitle.textColor = Theme.text
        progressDetail.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        progressDetail.textColor = Theme.secondaryText
        progressDetail.numberOfLines = 0
        progressBar.progressTintColor = Theme.accent
        progressBar.trackTintColor = UIColor(white: 1, alpha: 0.12)
        cancelButton.addAction(UIAction { [weak self] _ in self?.install.cancel() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancelButton, UIView()])
        let inner = UIStackView(arrangedSubviews: [progressTitle, progressBar, progressDetail, buttons])
        inner.axis = .vertical
        inner.spacing = 10
        fill(progressPanel, with: inner)
        progressPanel.isHidden = true
        return progressPanel
    }

    // MARK: State

    /// Shows the files in use (checking every one when asked) and any archives seen.
    private func refresh(recheck: Bool) {
        setStatus(nil, title: AppLanguage.choose("Checking your game files…"), detail: "")
        DispatchQueue.global(qos: .userInitiated).async {
            let found = GameFolder.isChosen || GameFolder.findInAppFolder()
            let report = found && recheck ? GameFolder.checkChosen() : nil
            DispatchQueue.main.async { self.show(report: report, found: found) }
        }
    }

    private func show(report: GameFiles.Report?, found: Bool) {
        lastReport = report ?? GameFolder.appFolderReport
        #if !targetEnvironment(macCatalyst)
        var nothingYet = false   // nothing at all to show: the guide opens by itself the first time
        #endif
        let server = GameSettings.shared.assetServer
        if let report, found {
            if report.isComplete {
                let format = GameFolder.inAppFolder
                    ? AppLanguage.choose("\"{arg0}\" in the GTA V Port folder: all {arg1} game files checked ({arg2}).")
                    : AppLanguage.choose("\"{arg0}\" on this iPhone: all {arg1} game files checked ({arg2}).")
                setStatus(true, title: AppLanguage.choose("Ready to play"), detail: AppLanguage.interpolate(format, [GameFolder.name, String(report.fileCount), GameFiles.Report.size(report.totalBytes)]))
            } else {
                // In use with problems: the player chose Play anyway for this folder.
                setStatus(true, title: Self.readyWithProblems(report.problems.count), detail: AppLanguage.choose("You chose to play anyway. ") + report.explanation.message)
            }
        } else if found {
            setStatus(true, title: AppLanguage.choose("Ready to play"), detail: AppLanguage.interpolate(AppLanguage.choose("\"{arg0}\" on this iPhone."), [GameFolder.name]))
        } else if let problem = GameFolder.appFolderReport {
            let explanation = problem.explanation
            setStatus(false, title: explanation.title, detail: AppLanguage.choose("Found a game folder in GTA V Port, but it can't be used yet. ") + explanation.message)
        } else if !server.isEmpty, let serverProblem {
            setStatus(false, title: AppLanguage.choose("Your game server doesn't answer"),
                      detail: server + " · " + serverProblem + "\n\n" + AppLanguage.choose("Without it there are no game files to play. Check the address, or use one of the ways below to put the files on this iPhone."))
        } else if !server.isEmpty {
            setStatus(true, title: AppLanguage.choose("Streaming from your server"), detail: server)
        } else if let archive = GameFolder.archivesFound.first, !install.isRunning {
            // A .zip/.rar moved into the app's folder (GTA-248): say so, the Unpack button is in the folder card.
            setStatus(nil, title: AppLanguage.choose("Found a game archive"), detail: AppLanguage.interpolate(AppLanguage.choose("{arg0} isn't unpacked yet. Tap Unpack below and the app does it for you."), [archive.lastPathComponent]))
        } else if lookedAgain {
            #if targetEnvironment(macCatalyst)
            setStatus(false, title: AppLanguage.choose("Nothing in this app's folder"), detail: AppLanguage.choose("The app looked through every folder in On My iPhone › GTA V Port and found no game. If your game is somewhere else (another folder, or another app's folder), tap Choose a folder… below and pick it, or pick On My iPhone itself to search everything. iOS only lets an app into other folders once you pick them."))
            #else
            setStatus(false, title: AppLanguage.choose("Nothing in this app's folder"), detail: AppLanguage.choose("The app looked through every folder in On My iPhone › GTA V Port and found no game. Put your unpacked game folder, or its .zip or .rar, in there (Show me how explains each step), then come back."))
            #endif
        } else {
            #if !targetEnvironment(macCatalyst)
            nothingYet = true
            #endif
            // A player who updated with another sideloader or Apple ID gets a second, empty app (GTA-153).
            var detail = AppLanguage.choose("Use one of the ways below. Whichever you choose, the app checks every file before you play.")
            #if !targetEnvironment(macCatalyst)
            detail += "\n\n" + AppLanguage.choose("Updated the app and your files are gone? Installing with another sideloader or Apple ID makes a separate copy of the app with an empty folder. Install over the old app the same way, or put your game in this app's folder again.")
            #endif
            setStatus(nil, title: AppLanguage.choose("No game files yet"), detail: detail)
        }
        lookedAgain = false
        // An install that stopped (lost connection, app closed): it continues where it stopped (GTA-93).
        let resumable = found || install.isRunning ? nil : GameInstaller.resumableInstall(at: Self.installFolder.resolvingSymlinksInPath())
        continueButton.isHidden = resumable == nil
        if let resumable {
            let percent = String(Int((resumable.fraction * 100).rounded(.down)))
            #if targetEnvironment(macCatalyst)
            let fromArchive = AppLanguage.choose("Tap Continue the download and pick the same archive: files already unpacked aren't unpacked again.")
            #else
            let fromArchive = AppLanguage.choose("Tap Continue the download. If the archive is gone from the GTA V Port folder, put the same one back there first: files already unpacked aren't unpacked again.")
            #endif
            setStatus(false, title: AppLanguage.interpolate(AppLanguage.choose("The download stopped at {arg0}%"), [percent]),
                      detail: resumable.urls.isEmpty ? fromArchive : AppLanguage.choose("Tap Continue the download: it picks up where it stopped instead of starting again."))
        }
        #if !targetEnvironment(macCatalyst)
        if nothingYet && resumable == nil { showGuideOnce() }
        #endif
        detailsButton.isHidden = lastReport?.isComplete ?? true
        anywayButton.isHidden = found || !(lastReport.map(GameFolder.playAnywayAllowed) ?? false)
        showArchives()
        onChange?()
    }

    private func setStatus(_ ok: Bool?, title: String, detail: String) {
        statusTitle.text = title
        statusDetail.text = detail
        statusDetail.isHidden = detail.isEmpty
        statusIcon.image = UIImage(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.triangle.fill" : "folder.badge.questionmark")
        statusIcon.tintColor = ok == true ? Theme.ok : ok == false ? Theme.problem : Theme.warning
    }

    private static func readyWithProblems(_ count: Int) -> String {
        count == 1 ? AppLanguage.choose("Ready, with 1 problem file") : AppLanguage.interpolate(AppLanguage.choose("Ready, with {arg0} problem files"), [String(count)])
    }

    private func showArchives() {
        archivesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for archive in GameFolder.archivesFound {
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { GameFiles.Report.size(UInt64($0)) } ?? ""
            let button = Theme.glassButton(AppLanguage.interpolate(AppLanguage.choose("Unpack {arg0} ({arg1})"), [archive.lastPathComponent, size]), symbol: "archivebox")
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.startInstall(.file(archive, ownedByApp: true)) }, for: .touchUpInside)
            archivesStack.addArrangedSubview(button)
        }
        archivesStack.isHidden = GameFolder.archivesFound.isEmpty
    }

    /// Continues a stopped install (GTA-93): from its link at the saved byte, or from the same archive.
    private func continueInstall() {
        guard let resumable = GameInstaller.resumableInstall(at: Self.installFolder.resolvingSymlinksInPath()) else { refresh(recheck: false); return }
        GameFolder.log("Continuing the stopped install at \(Int(resumable.fraction * 100))% (\(resumable.format), continues download: \(resumable.continuesDownload))")
        if let url = resumable.urls.first {
            startInstall(.url(url))
        } else if let name = resumable.fileNames.first, let archive = GameFolder.archivesFound.first(where: { $0.lastPathComponent == name }) {
            startInstall(.file(archive, ownedByApp: true), confirmed: true)
        } else {
            #if targetEnvironment(macCatalyst)
            pickArchive()
            #else
            setStatus(false, title: AppLanguage.choose("The archive isn't in the GTA V Port folder"), detail: AppLanguage.choose("Tap Continue the download. If the archive is gone from the GTA V Port folder, put the same one back there first: files already unpacked aren't unpacked again."))
            #endif
        }
    }

    private func confirmPlayAnyway() {
        guard let report = lastReport else { return }
        let count = report.problems.count
        let title = count == 1 ? AppLanguage.choose("Play with 1 problem file?") : AppLanguage.interpolate(AppLanguage.choose("Play with {arg0} problem files?"), [String(count)])
        let alert = UIAlertController(title: title, message: AppLanguage.choose("The game starts, but it may crash or show missing things wherever it needs those files. Fixing the folder (unpacking again) is the real cure."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Play anyway"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = GameFolder.playAnyway(report)
                DispatchQueue.main.async {
                    if ok {
                        self.setStatus(true, title: Self.readyWithProblems(report.problems.count), detail: AppLanguage.choose("You chose to play anyway. The game may crash where it needs them."))
                        self.anywayButton.isHidden = true
                        self.onChange?()
                    } else {
                        self.setStatus(false, title: AppLanguage.choose("Couldn't use that folder"), detail: AppLanguage.choose("Try choosing it again."))
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    private func showDetails() {
        guard let report = lastReport else { return }
        let text = UITextView()
        text.text = report.explanation.message + "\n\n" + AppLanguage.choose("Every problem:") + "\n" + report.details
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = Theme.text
        text.backgroundColor = Theme.night
        let controller = UIViewController()
        controller.title = AppLanguage.interpolate(AppLanguage.choose("{arg0} problems"), [String(report.problems.count)])
        controller.view = text
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak controller] _ in
            let share = UIActivityViewController(activityItems: [text.text ?? ""], applicationActivities: nil)
            share.popoverPresentationController?.barButtonItem = controller?.navigationItem.rightBarButtonItem
            controller?.present(share, animated: true)
        })
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: Finding

    private var lookedAgain = false
    private func lookInAppFolder() {
        lookedAgain = true
        if !GameFolder.inAppFolder { GameFolder.clear() }
        refresh(recheck: true)
    }

    /// The way that works on every install (GTA-62): the Files app opens at this app's own folder, the
    /// player moves the game folder in, and coming back to the app looks there again.
    private var lookWhenBack = false
    private func openAppFolderInFiles() {
        try? FileManager.default.createDirectory(at: GameFolder.appFolder, withIntermediateDirectories: true)
        guard let url = URL(string: "shareddocuments://" + GameFolder.appFolder.path) else { return }
        GameFolder.log("Game files: opened the app's folder in Files to move the game in")
        UIApplication.shared.open(url) { [weak self] opened in
            guard let self else { return }
            if opened {
                self.lookWhenBack = true
            } else {
                self.setStatus(false, title: AppLanguage.choose("Files didn't open"), detail: AppLanguage.choose("Open the Files app yourself and go to On My iPhone › GTA V Port, move your game folder there, then come back."))
            }
        }
    }

    @objc private func cameBack() {
        // On iPhone, coming back without a game in use always looks again: the game may have been moved in by hand.
        #if targetEnvironment(macCatalyst)
        guard lookWhenBack, !install.isRunning else { return }
        #else
        guard lookWhenBack || !GameFolder.isChosen, !install.isRunning, presentedViewController == nil else { return }
        #endif
        lookWhenBack = false
        // A complete game folder picked elsewhere stays in use; only without one does the app's folder take over.
        if GameFolder.isChosen, !GameFolder.inAppFolder, lastReport?.isComplete == true { refresh(recheck: false); return }
        lookInAppFolder()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !pickingArchive else { return }
        // On some sideloaded installs the picker's Open never answers, so players can only cancel (GTA-62).
        GameFolder.log("Game files: the folder picker was closed without a folder")
        if GameFolder.isChosen, lastReport?.isComplete == true { return }   // the game is set up already
        if GameFolder.insideLiveContainer {
            setStatus(nil, title: AppLanguage.choose("Open didn't work?"), detail: AppLanguage.choose("Inside LiveContainer the picker can't open your game folder until two of its fixes are on: in LiveContainer, open GTA V Port's settings and under Fixes turn on Fix File Picker and Use LiveContainer's Bundle ID. Then choose your game folder, also one kept from an earlier version."))
            return
        }
        setStatus(nil, title: AppLanguage.choose("Open didn't work?"), detail: AppLanguage.choose("Some sideloaded installs can't hand a folder to the app. Tap Open GTA V Port in Files, move your game folder there, then come back: the app finds it by itself."))
    }

    private func pickFolder() {
        pickingArchive = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickArchive() {
        pickingArchive = true
        let types = ["zip", "rar", "7z"].compactMap { UTType(filenameExtension: $0) } + [.zip, .archive]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if pickingArchive {
            let parts = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard let first = parts.first else { return }
            startInstall(parts.count > 1 ? .parts(parts) : .file(first, ownedByApp: first.path.hasPrefix(GameFolder.appFolder.path)))
            return
        }
        guard let folder = urls.first else { return }
        // On some sideloaded installs iOS hands over a copy in tmp/…-Inbox instead of the folder itself (player
        // logs, GTA-62), and iOS may clear tmp at any time: keep the copy by moving it into the app's own folder.
        if folder.path.contains("-Inbox/") {
            let kept = GameFolder.appFolder.appendingPathComponent(folder.lastPathComponent)
            if !FileManager.default.fileExists(atPath: kept.path), (try? FileManager.default.moveItem(at: folder, to: kept)) != nil {
                GameFolder.log("Game files: the picker gave a copy (\(folder.lastPathComponent)); moved it into the app's folder")
                lookInAppFolder()
                return
            }
            GameFolder.log("Game files: the picker gave a copy in \(folder.deletingLastPathComponent().lastPathComponent) and it couldn't be moved")
        }
        setStatus(nil, title: AppLanguage.interpolate(AppLanguage.choose("Searching \"{arg0}\"…"), [folder.lastPathComponent]), detail: AppLanguage.choose("Looking through every folder inside for your game, then checking each file."))
        DispatchQueue.global(qos: .userInitiated).async {
            let choice = GameFolder.choose(folder)
            DispatchQueue.main.async {
                switch choice {
                case let .accepted(report): self.show(report: report, found: true)
                case let .incomplete(report):
                    self.lastReport = report
                    let explanation = report.explanation
                    self.setStatus(false, title: explanation.title, detail: AppLanguage.interpolate(AppLanguage.choose("Found the game in \"{arg0}\", but it can't be used yet. "), [report.data.deletingLastPathComponent().lastPathComponent]) + explanation.message)
                    self.detailsButton.isHidden = false
                    self.anywayButton.isHidden = !GameFolder.playAnywayAllowed(report)
                case let .archivesOnly(archives):
                    self.setStatus(nil, title: AppLanguage.choose("Found a game archive"), detail: AppLanguage.interpolate(AppLanguage.choose("{arg0} isn't unpacked yet. Tap Unpack below and the app does it for you."), [archives[0].lastPathComponent]))
                    self.showArchives()
                case let .refused(message):
                    self.setStatus(false, title: AppLanguage.choose("No game in that folder"), detail: message)
                }
            }
        }
    }

    // MARK: Link

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { useLink(); return true }

    /// A game server answers with the game's file list; anything else is treated as an archive download.
    private func useLink() {
        linkField.resignFirstResponder()
        var text = (linkField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            setStatus(false, title: AppLanguage.choose("That isn't a web link"), detail: AppLanguage.choose("Paste the full link, starting with https://"))
            return
        }
        setStatus(nil, title: AppLanguage.choose("Checking the link…"), detail: text)
        // A link to an archive file is always an install (some file hosts answer "OK" to any path).
        let archiveName = url.lastPathComponent.lowercased()
        if [".zip", ".rar", ".7z", ".001"].contains(where: archiveName.hasSuffix) || archiveName.range(of: #"\.(z|r)\d\d$"#, options: .regularExpression) != nil {
            startInstall(.url(url))
            return
        }
        // Otherwise it's a game server only if it really serves the game's file list.
        var server = text
        while server.hasSuffix("/") { server.removeLast() }
        var request = URLRequest(url: URL(string: server + "/data/manifest.json")!, timeoutInterval: 10)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        DownloadBrowserViewController.loadUserAgent { userAgent in
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let head = data.flatMap { String(data: $0.prefix(4096), encoding: .utf8) } ?? ""
            let isGameList = (code == 200 || code == 206) && head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") && head.contains("\"files\"")
            DispatchQueue.main.async {
                guard let self else { return }
                if isGameList {
                    self.onServer?(server)
                    self.setStatus(true, title: AppLanguage.choose("Streaming from your server"), detail: AppLanguage.interpolate(AppLanguage.choose("{arg0} answers with the game's file list. The game reads its files from there while you play."), [server]))
                    self.onChange?()
                } else {
                    self.openOrInstall(url)
                }
            }
        }.resume()
        }
    }

    /// A direct file link is installed; a web page (a download portal) opens in the download
    /// browser, which hands over the file when the page starts it.
    private func openOrInstall(_ url: URL) {
        // Asked the way Safari opens a typed link (no range), and dropped once the headers arrive.
        DownloadBrowserViewController.loadUserAgent { userAgent in
            var request = URLRequest(url: url, timeoutInterval: 15)
            for (name, value) in DownloadBrowserViewController.safariHeaders(for: url, page: nil, userAgent: userAgent, method: "GET", body: nil) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            Task { [weak self] in
                var type = "", status = 0
                if let (bytes, response) = try? await URLSession.shared.bytes(for: request) {
                    type = response.mimeType?.lowercased() ?? ""
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    bytes.task.cancel()
                }
                // A web page, or a refusal (a bot check answers 403 or 503): the browser handles it like Safari.
                let browser = type.contains("html") || [401, 403, 429, 503].contains(status)
                GameFolder.log("Link check (\(url.host ?? "?")): HTTP \(status), \(type.isEmpty ? "no type" : type); \(browser ? "opening the browser" : "installing from the link").")
                await MainActor.run {
                    guard let self else { return }
                    if browser { self.openBrowser(url) } else { self.startInstall(.url(url)) }
                }
            }
        }
    }

    private func openBrowser(_ url: URL) {
        setStatus(nil, title: AppLanguage.choose("That link is a web page"), detail: AppLanguage.choose("Use the page's download button in the browser; the app takes over the download."))
        let browser = DownloadBrowserViewController(url: url)
        browser.onDownload = { [weak self] file, request in self?.startInstall(.browser(file, request)) }
        let navigation = UINavigationController(rootViewController: browser)
        Theme.styleNavigation(navigation)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    // MARK: Installing

    static var gameBytes: UInt64 { GameFiles.manifest.reduce(0) { $0 + $1.1 } }

    private func startInstall(_ source: GameInstallSource, confirmed: Bool = false) {
        guard !install.isRunning else { return }
        if case let .file(url, true) = source, !confirmed {
            // Unpacking frees the archive as it goes (that's how it fits next to the game).
            let alert = UIAlertController(title: AppLanguage.interpolate(AppLanguage.choose("Unpack {arg0}?"), [url.lastPathComponent]), message: AppLanguage.choose("To fit on this iPhone, the archive is used up while it unpacks: once it's done, only the unpacked game is left. If unpacking stops half way, you'll need the archive again."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: AppLanguage.choose("Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: AppLanguage.choose("Unpack"), style: .default) { [weak self] _ in self?.startInstall(source, confirmed: true) })
            present(alert, animated: true)
            return
        }
        // Installing replaces streaming: a link saved as a game server earlier is forgotten.
        if !GameSettings.shared.assetServer.isEmpty { GameSettings.shared.assetServer = ""; onChange?() }
        progressPanel.isHidden = false
        progressTitle.text = AppLanguage.choose("Starting…")
        progressDetail.text = ""
        progressBar.progress = 0
        // The status card at the top follows the install too, and the progress comes into view.
        setStatus(nil, title: AppLanguage.choose("Getting your game files…"), detail: AppLanguage.choose("Downloading and unpacking. Keep the app open; progress is shown below."))
        DispatchQueue.main.async {
            guard let scroll = self.stack.superview as? UIScrollView else { return }
            scroll.scrollRectToVisible(scroll.convert(self.progressPanel.bounds, from: self.progressPanel).insetBy(dx: 0, dy: -20), animated: true)
        }
        UIApplication.shared.isIdleTimerDisabled = true
        install.start(source, to: Self.installFolder)
    }

    /// Shows the shared install's state (it keeps running while this screen is closed).
    @objc private func installChanged() {
        switch install.state {
        case .idle:
            break
        case let .running(update):
            progressPanel.isHidden = false
            cancelButton.isHidden = false
            progressTitle.text = update.title
            progressDetail.text = update.detail
            progressBar.setProgress(Float(update.fraction), animated: true)
            setStatus(nil, title: update.title, detail: update.detail.split(separator: "\n").first.map(String.init) ?? "")
        case let .finished(result):
            install.acknowledge()
            switch result {
            case .success:
                progressPanel.isHidden = false
                progressTitle.text = AppLanguage.choose("Done: every game file unpacked and checked")
                progressDetail.text = ""
                progressBar.progress = 1
                cancelButton.isHidden = true
                refresh(recheck: true)
            case let .failure(message):
                progressPanel.isHidden = false
                progressTitle.text = AppLanguage.choose("Couldn't finish")
                progressDetail.text = message
                cancelButton.isHidden = true
                setStatus(false, title: AppLanguage.choose("Couldn't get the game files"), detail: message)
                continueButton.isHidden = GameInstaller.resumableInstall(at: Self.installFolder.resolvingSymlinksInPath()) == nil
            case let .webPage(url):
                progressPanel.isHidden = true
                openBrowser(url)
            }
        }
    }

    // MARK: Layout helpers

    private func card(_ title: String?, _ views: [UIView]) -> UIView {
        let panel = Theme.panel()
        var items = views
        if let title {
            let label = UILabel()
            label.text = title
            label.font = Theme.display(18, .bold)
            label.textColor = Theme.text
            items.insert(label, at: 0)
        }
        let inner = UIStackView(arrangedSubviews: items)
        inner.axis = .vertical
        inner.spacing = 10
        inner.alignment = .fill
        fill(panel, with: inner)
        return panel
    }
    private func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.body(14)
        label.textColor = Theme.secondaryText
        label.numberOfLines = 0
        return label
    }
    private func fill(_ panel: UIVisualEffectView, with content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -16)
        ])
    }
    /// Closing is fine while an install runs: it carries on, and the start screen shows its progress.
    private func close() {
        dismiss(animated: true)
    }
}
