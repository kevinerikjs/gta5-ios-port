import UIKit
import UniformTypeIdentifiers

/// Settings › Mods (GTA-69): install a downloaded mod (ModInstaller works out where its files go),
/// and switch installed mods on or off, or remove them. Changes apply the next time the game starts.
final class ModsViewController: UITableViewController, UIDocumentPickerDelegate {
    private var mods: [ModInstaller.Installed] = []
    /// Archives (zip, rar, 7z, oiv) put in the Mods folder still packed: the game skips them ("is not a game file path;
    /// ignored", 34 of 315 player logs on 2026-10-22, GTA-167), so they're offered for install here.
    private var packed: [URL] = []
    private var busy = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("Mods")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        reload()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    private func reload() { mods = ModInstaller.installed(); packed = ModInstaller.packedInModsFolder(besides: mods); tableView.reloadData() }

    private enum Section { case actions, packed, installed }
    private var sections: [Section] { packed.isEmpty ? [.actions, .installed] : [.actions, .packed, .installed] }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] { case .actions: return 3; case .packed: return packed.count; case .installed: return max(mods.count, 1) }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .actions: return nil
        case .packed: return AppLanguage.choose("Still packed in the Mods folder")
        case .installed: return AppLanguage.choose("Installed")
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .actions: return AppLanguage.choose("Pick a mod as you downloaded it (zip, rar, oiv, asi or loose files). The app finds where each file goes. Car, skin and add-on mods need the game files on this iPhone.")
        case .packed: return AppLanguage.choose("The game can't use a mod that is still packed. Tap one to install it.")
        case .installed: return AppLanguage.choose("Changes apply the next time the game starts. Mods can cause crashes and glitches that we can't fix: ask about them in the Mods topic on Telegram.")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil; cell.accessoryType = .none; cell.selectionStyle = .default
        if sections[indexPath.section] == .packed {
            content.text = packed[indexPath.row].lastPathComponent
            content.secondaryText = AppLanguage.choose("Tap to install")
            content.image = UIImage(systemName: "shippingbox")
            content.textProperties.color = busy ? .secondaryLabel : tintColor()
        } else if sections[indexPath.section] == .actions {
            content.text = [busy ? AppLanguage.choose("Reading the mod…") : AppLanguage.choose("Install a mod…"),
                            AppLanguage.choose("Show the Mods folder in Files"), AppLanguage.choose("Mods guide")][indexPath.row]
            content.image = UIImage(systemName: ["square.and.arrow.down", "folder", "book"][indexPath.row])
            content.textProperties.color = tintColor()
        } else if mods.isEmpty {
            content.text = AppLanguage.choose("No mods installed yet")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            let mod = mods[indexPath.row]
            content.text = mod.name
            content.secondaryText = AppLanguage.interpolate(AppLanguage.choose("{arg0} files"), [String(mod.files)])
            // Files installed before the game had run: placed at the next start, or (index there) not in this game.
            if mod.waiting > 0 {
                content.secondaryText! += " · " + AppLanguage.interpolate(ModInstaller.hasGameIndex
                    ? AppLanguage.choose("{arg0} not in this game version") : AppLanguage.choose("{arg0} placed when the game starts"), [String(mod.waiting)])
            }
            // Changed while the game is running: applied at the next start (ModInstaller.pending).
            let change = ModInstaller.pending[mod.name]
            if let change {
                content.secondaryText! += " · " + (change == "remove" ? AppLanguage.choose("removed when the game starts again")
                    : change == "on" ? AppLanguage.choose("switched on when the game starts again") : AppLanguage.choose("switched off when the game starts again"))
            }
            let toggle = UISwitch()
            toggle.isOn = change.map { $0 == "on" } ?? mod.enabled
            toggle.isEnabled = change != "remove"
            toggle.addAction(UIAction { [weak self] action in
                guard let self, let toggle = action.sender as? UISwitch else { return }
                do { try ModInstaller.setEnabled(mod, toggle.isOn) } catch { toggle.isOn = !toggle.isOn; self.show(error) }
                self.reload()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }
    private func tintColor() -> UIColor { view.tintColor ?? .systemBlue }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if sections[indexPath.section] == .packed { if !busy { install(packed[indexPath.row]) }; return }
        guard sections[indexPath.section] == .actions else { return }
        if indexPath.row == 0 {
            guard !busy else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker, animated: true)
        } else if indexPath.row == 2 {
            if let url = URL(string: "https://fivestarport.site/mods/") { UIApplication.shared.open(url) }
        } else {
            showInFiles(ModInstaller.modsFolder)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard sections[indexPath.section] == .installed, !mods.isEmpty else { return nil }
        let mod = mods[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: AppLanguage.choose("Remove")) { [weak self] _, _, done in
            do { try ModInstaller.remove(mod) } catch { self?.show(error, title: AppLanguage.choose("Couldn't remove the mod")) }
            self?.reload(); done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: Installing

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        install(url)
    }

    /// Unpacks and plans in the background, then asks before copying.
    func install(_ url: URL) {
        busy = true; tableView.reloadData()
        let manifest = EnginePaths.manifest
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (ModInstaller.Plan, URL) in
                let folder = try ModInstaller.unpack(url)
                let plan = ModInstaller.plan(folder: folder, name: url.lastPathComponent, index: .load(manifest: manifest))
                return (plan, folder)
            }
            DispatchQueue.main.async {
                self.busy = false; self.tableView.reloadData()
                switch result {
                case let .failure(error): self.show(error)
                case let .success((plan, folder)): self.confirm(plan, folder: folder)
                }
            }
        }
    }

    private func confirm(_ plan: ModInstaller.Plan, folder: URL) {
        var lines: [String] = []
        for item in plan.items.prefix(12) { lines.append("• " + (item.target as NSString).lastPathComponent + " → " + item.note) }
        if plan.items.count > 12 { lines.append(AppLanguage.interpolate(AppLanguage.choose("…and {arg0} more"), [String(plan.items.count - 12)])) }
        if !plan.skipped.isEmpty {
            lines.append("")
            lines.append(AppLanguage.choose("Not installed:"))
            for skip in plan.skipped.prefix(8) { lines.append("• " + (skip.file as NSString).lastPathComponent + ": " + skip.reason) }
        }
        guard !plan.items.isEmpty else {
            // Left out because it can't work on iPhone (Windows .NET, GTA V Enhanced): say so, not "couldn't tell where".
            let title = plan.unsupported ? AppLanguage.choose("This mod can't run on iPhone") : AppLanguage.choose("Nothing to install")
            let help = plan.unsupported ? AppLanguage.choose("It needs something that only runs on a Windows PC, or it was made for another version of the game. The guide lists what works.")
                : AppLanguage.choose("The app couldn't tell where this mod's files go. See the guide for putting files in the Mods folder by hand.")
            let alert = UIAlertController(title: title, message: lines.joined(separator: "\n") + "\n\n" + help, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: AppLanguage.choose("OK"), style: .cancel) { _ in try? FileManager.default.removeItem(at: folder) })
            present(alert, animated: true); return
        }
        let alert = UIAlertController(title: AppLanguage.interpolate(AppLanguage.choose("Install \"{arg0}\"?"), [plan.name]), message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Cancel"), style: .cancel) { _ in try? FileManager.default.removeItem(at: folder) })
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Install"), style: .default) { [weak self] _ in
            do {
                try ModInstaller.install(plan)
                NSLog("Mods: installed %@ (%d files, %d skipped)", plan.name, plan.items.count, plan.skipped.count)
            } catch { self?.show(error) }
            try? FileManager.default.removeItem(at: folder)
            self?.reload()
        })
        present(alert, animated: true)
    }

    private func show(_ error: Error, title: String = AppLanguage.choose("Couldn't install the mod")) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("OK"), style: .cancel))
        present(alert, animated: true)
    }
}
