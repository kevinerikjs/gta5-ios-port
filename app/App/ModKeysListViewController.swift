import UIKit

/// Settings › Mods › (a script mod): the keys it uses and what for, read from its .ini settings and its code before it
/// runs, plus the ones it checked while playing (GTA-179). Tap one to put it on screen as a button (GTA-180) or to
/// press it with another key (GTA-181).
final class ModKeysListViewController: UITableViewController {
    private let mod: ModInstaller.Installed
    private var scan = ModKeys.Scan()
    private var loading = true
    /// Keys the mod checked while playing that its settings don't name (empty when the game isn't running).
    private var seen: [ModKeys.Binding] = []
    private var settingsKeys: [ModKeys.Binding] { scan.bindings.filter { $0.source == .settings } }
    private var codeKeys: [ModKeys.Binding] { scan.bindings.filter { $0.source == .code && !seen.contains($0) } }
    private var showAllCode = false
    private static let codePreview = 6

    init(mod: ModInstaller.Installed) {
        self.mod = mod
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mod.name
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: ModButton.changed, object: nil)
        let folder = mod.url
        DispatchQueue.global(qos: .userInitiated).async {
            let scan = ModKeys.scan(folder: folder)
            DispatchQueue.main.async {
                self.scan = scan; self.loading = false
                self.readSeen()
                self.tableView.reloadData()
                GameFolder.log("Mod keys: \(self.mod.name): \(self.settingsKeys.count) from its settings, \(self.codeKeys.count) in its code, \(self.seen.count) checked while playing")
            }
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); readSeen(); tableView.reloadData() }
    @objc private func changed() { tableView.reloadData() }

    private func readSeen() {
        guard !loading else { return }
        var keys = [UInt8](repeating: 0, count: 256), handler = false, any = false
        for script in scan.scripts {
            var part = [UInt8](repeating: 0, count: 256)
            guard PGAsiModuleKeys(script, &part, &handler) else { continue }
            any = true
            for k in 0..<256 where part[k] != 0 { keys[k] = 1 }
        }
        guard any else { seen = []; return }
        let named = Set(settingsKeys.flatMap(\.keys))
        seen = (7..<256).filter { keys[$0] != 0 && !named.contains($0) }.map { ModKeys.Binding(keys: [$0], source: .code, setting: "", reason: "", file: "") }
    }

    // MARK: Table

    private enum Section { case settings, seen, code }
    private var sections: [Section] {
        if loading { return [.settings] }
        return [Section.settings] + (seen.isEmpty ? [] : [.seen]) + (codeKeys.isEmpty ? [] : [.code])
    }
    private func bindings(_ section: Section) -> [ModKeys.Binding] {
        switch section {
        case .settings: return settingsKeys
        case .seen: return seen
        case .code: return showAllCode ? codeKeys : Array(codeKeys.prefix(Self.codePreview))
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let kind = sections[section]
        if kind == .settings && (loading || settingsKeys.isEmpty) { return 1 }
        let more = kind == .code && !showAllCode && codeKeys.count > Self.codePreview ? 1 : 0
        return bindings(kind).count + more
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .settings: return AppLanguage.choose("From its settings")
        case .seen: return AppLanguage.choose("Checked while playing")
        case .code: return AppLanguage.choose("Found in its code")
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .settings:
            var text = AppLanguage.choose("Script mods are made for a PC keyboard. Tap a key to put it on screen as a button, or to press it with another key.")
            if scan.everyKey { text += " " + AppLanguage.choose("This mod also reads every key press, so it may use keys that aren't listed.") }
            return text
        case .seen: return AppLanguage.choose("Keys the mod checked since the game started.")
        case .code: return AppLanguage.choose("Keys its code checks. Some only work inside its own menu.")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none; cell.selectionStyle = .default
        let kind = sections[indexPath.section], list = bindings(kind)
        if kind == .settings && loading {
            content.text = AppLanguage.choose("Reading the mod…"); content.textProperties.color = .secondaryLabel; cell.selectionStyle = .none
        } else if kind == .settings && settingsKeys.isEmpty {
            content.text = AppLanguage.choose("Its settings name no keys"); content.textProperties.color = .secondaryLabel; cell.selectionStyle = .none
        } else if indexPath.row >= list.count {
            content.text = AppLanguage.interpolate(AppLanguage.choose("Show {arg0} more"), [String(codeKeys.count - list.count)])
            content.textProperties.color = view.tintColor ?? .systemBlue
        } else {
            let binding = list[indexPath.row]
            content.text = binding.source == .settings ? ModKeys.title(binding) : ModKeys.name(binding.keys)
            var detail = binding.source == .settings ? [ModKeys.name(binding.keys)] : []
            for key in binding.keys {
                if let other = ModKeyRemap.key(mod: mod.name, modKey: key) {
                    detail.append(AppLanguage.interpolate(AppLanguage.choose("{arg0} pressed with {arg1}"), [ModKeys.name(key), ModKeys.name(other)]))
                }
            }
            if let button = ModButton.button(mod: mod.name, keys: binding.keys) {
                detail.append(button.show == .always ? AppLanguage.choose("on screen") : button.show == .vehicle ? AppLanguage.choose("on screen in vehicles")
                    : AppLanguage.interpolate(AppLanguage.choose("on screen in the {arg0}"), [button.modelName]))
                content.image = button.symbol.isEmpty ? ControlStyle.textIcon(ModKeys.name(button.keys.last ?? 0)) : UIImage(systemName: button.symbol)
            } else {
                content.image = UIImage(systemName: "keyboard")
            }
            content.secondaryText = detail.isEmpty ? nil : detail.joined(separator: " · ")
            content.imageProperties.tintColor = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let kind = sections[indexPath.section], list = bindings(kind)
        if kind == .settings && (loading || settingsKeys.isEmpty) { return }
        guard indexPath.row < list.count else { showAllCode = true; tableView.reloadSections([indexPath.section], with: .automatic); return }
        actions(for: list[indexPath.row], from: tableView.cellForRow(at: indexPath))
    }

    private func actions(for binding: ModKeys.Binding, from cell: UIView?) {
        let name = ModKeys.name(binding.keys)
        let sheet = UIAlertController(title: binding.source == .settings ? ModKeys.title(binding) : name, message: binding.source == .settings ? name : nil, preferredStyle: .actionSheet)
        let existing = ModButton.button(mod: mod.name, keys: binding.keys)
        sheet.addAction(UIAlertAction(title: existing == nil ? AppLanguage.choose("Put on screen…") : AppLanguage.choose("Change its on-screen button…"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(ModButtonEditorViewController(mod: self.mod.name, binding: binding), animated: true)
        })
        if let existing {
            sheet.addAction(UIAlertAction(title: AppLanguage.choose("Remove from screen"), style: .destructive) { _ in ModButton.remove(existing) })
        }
        for key in binding.keys {
            let title = ModKeyRemap.key(mod: mod.name, modKey: key) == nil
                ? AppLanguage.interpolate(AppLanguage.choose("Press {arg0} with another key…"), [ModKeys.name(key)])
                : AppLanguage.interpolate(AppLanguage.choose("Change the key that presses {arg0}…"), [ModKeys.name(key)])
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(ModKeyChooserViewController(mod: self.mod.name, modKey: key), animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: AppLanguage.choose("Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell { popover.sourceView = cell; popover.sourceRect = cell.bounds }
        present(sheet, animated: true)
    }
}

/// Puts a mod's key on screen (GTA-180): when the button shows and its icon. Placed like the other controls, and
/// moved or resized in Edit controls layout.
final class ModButtonEditorViewController: UITableViewController {
    private let binding: ModKeys.Binding
    private var button: ModButton
    private let isNew: Bool
    /// The vehicle the player sits in now (for "only in this one"), from the game.
    private var vehicle: (model: UInt32, name: String)?

    init(mod: String, binding: ModKeys.Binding) {
        self.binding = binding
        let label = binding.source == .settings ? ModKeys.title(binding) : ModKeys.name(binding.keys)
        let existing = ModButton.button(mod: mod, keys: binding.keys)
        isNew = existing == nil
        button = existing ?? ModButton(mod: mod, keys: binding.keys, symbol: "", label: label, show: .always)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ModKeys.name(binding.keys)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: isNew ? AppLanguage.choose("Add") : AppLanguage.choose("Save"), style: .done, target: self, action: #selector(save))
        let model = PGReadControlHints(PGCurrentTouchContext()).vehicleModel
        if model != 0 {
            vehicle = (model, String(format: "0x%08X", model))
            VehicleNames.name(model) { [weak self] name in
                guard let self, let name else { return }
                self.vehicle = (model, name); self.tableView.reloadData()
            }
        }
    }

    @objc private func save() {
        if button.show == .model, let vehicle, button.model == 0 || button.model == vehicle.model { button.model = vehicle.model; button.modelName = vehicle.name }
        ModButton.save(button)
        GameFolder.log("Mod keys: on-screen button \(button.id) (\(button.show.rawValue)\(button.show == .model ? " " + button.modelName : ""), \(button.symbol.isEmpty ? "key name" : button.symbol))")
        navigationController?.popViewController(animated: true)
    }

    private var showOptions: [ModButton.Show] {
        var list: [ModButton.Show] = [.always, .vehicle]
        if vehicle != nil || button.show == .model { list.append(.model) }
        return list
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    // The icon section: the short list, then "All icons…", every SF Symbol in a grid (GTA-210).
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? showOptions.count : ModButton.symbols.count + 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? AppLanguage.choose("Shows") : AppLanguage.choose("Icon")
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return vehicle == nil && button.show != .model ? AppLanguage.choose("Get in a car to make a button for that car only. Buttons show while script mods run.")
                : AppLanguage.choose("Buttons show while script mods run.")
        }
        return AppLanguage.choose("Touch and hold the button to hold the key. Move or resize it in Settings › Edit controls layout.")
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let show = showOptions[indexPath.row]
            switch show {
            case .always: content.text = AppLanguage.choose("Always")
            case .vehicle: content.text = AppLanguage.choose("In any vehicle")
            case .model:
                let name = button.show == .model && button.model != 0 && button.model != vehicle?.model ? button.modelName : vehicle?.name ?? button.modelName
                content.text = AppLanguage.interpolate(AppLanguage.choose("Only in the {arg0}"), [name])
            }
            cell.accessoryType = button.show == show ? .checkmark : .none
        } else if indexPath.row == ModButton.symbols.count {
            let own = !ModButton.symbols.contains(button.symbol)
            content.text = AppLanguage.choose("All icons…")
            content.image = UIImage(systemName: own ? button.symbol : "square.grid.3x3")
            content.imageProperties.tintColor = .label
            cell.accessoryType = own ? .checkmark : .disclosureIndicator
        } else {
            let symbol = ModButton.symbols[indexPath.row]
            content.text = symbol.isEmpty ? AppLanguage.choose("Key name") : Self.symbolNames[symbol] ?? symbol
            content.image = symbol.isEmpty ? ControlStyle.textIcon(ModKeys.name(binding.keys.last ?? 0)) : UIImage(systemName: symbol)
            content.imageProperties.tintColor = .label
            cell.accessoryType = button.symbol == symbol ? .checkmark : .none
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            button.show = showOptions[indexPath.row]
            if button.show == .model, let vehicle { button.model = vehicle.model; button.modelName = vehicle.name }
        } else if indexPath.row == ModButton.symbols.count {
            navigationController?.pushViewController(SymbolPickerViewController(selected: button.symbol) { [weak self] name in
                self?.button.symbol = name
                self?.tableView.reloadData()
            }, animated: true)
            return
        } else {
            button.symbol = ModButton.symbols[indexPath.row]
        }
        tableView.reloadData()
    }
    private static var symbolNames: [String: String] {
        ["list.bullet": AppLanguage.choose("Menu"), "car.side": AppLanguage.choose("Car"), "headlight.high.beam": AppLanguage.choose("Lights"),
         "arrow.left.arrow.right": AppLanguage.choose("Indicators"), "rectangle.portrait.and.arrow.right": AppLanguage.choose("Doors and mirrors"),
         "arrow.up.and.down.square": AppLanguage.choose("Up and down"), "light.beacon.max": AppLanguage.choose("Siren"), "bolt": AppLanguage.choose("Boost"),
         "wrench": AppLanguage.choose("Repair"), "camera": AppLanguage.choose("Camera"), "person": AppLanguage.choose("Player"), "star": AppLanguage.choose("Favourite")]
    }
}

/// Picks the key that presses a mod's key (GTA-181): the mod then reacts to that key instead of its own, from a
/// keyboard, the Mod keys tray or an on-screen button.
final class ModKeyChooserViewController: UITableViewController {
    private let mod: String, modKey: Int
    private let groups: [(title: String, keys: [Int])] = [
        (AppLanguage.choose("Letters"), Array(65...90)), (AppLanguage.choose("Numbers"), Array(48...57)),
        (AppLanguage.choose("F keys"), Array(112...123)), (AppLanguage.choose("Number pad"), Array(96...105)),
        (AppLanguage.choose("Other keys"), [37, 38, 39, 40, 13, 32, 8, 45, 46, 36, 35, 33, 34])]

    init(mod: String, modKey: Int) {
        self.mod = mod; self.modKey = modKey
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.interpolate(AppLanguage.choose("Press {arg0} with"), [ModKeys.name(modKey)])
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }
    private var current: Int { ModKeyRemap.pressed(mod: mod, modKey: modKey) }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : groups[section - 1].keys.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? nil : groups[section - 1].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? AppLanguage.interpolate(AppLanguage.choose("{arg0} reacts to the key you pick instead of {arg1}: from a keyboard, the Mod keys tray or an on-screen button. Applies right away."), [mod, ModKeys.name(modKey)]) : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let key = indexPath.section == 0 ? modKey : groups[indexPath.section - 1].keys[indexPath.row]
        content.text = indexPath.section == 0 ? AppLanguage.interpolate(AppLanguage.choose("{arg0} (its own key)"), [ModKeys.name(modKey)]) : ModKeys.name(key)
        cell.accessoryType = key == current ? .checkmark : .none
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = indexPath.section == 0 ? modKey : groups[indexPath.section - 1].keys[indexPath.row]
        ModKeyRemap.set(mod: mod, modKey: modKey, key: key)
        NotificationCenter.default.post(name: ModButton.changed, object: nil)
        GameFolder.log("Mod keys: \(mod) key \(modKey) pressed with \(key)")
        navigationController?.popViewController(animated: true)
    }
}

/// The name the game shows for a vehicle model (its catalog, read on the game thread; PGRequestVehicleCatalog).
enum VehicleNames {
    static func name(_ model: UInt32, done: @escaping (String?) -> Void) {
        PGRequestVehicleCatalog()
        var tries = 0
        func check() {
            let count = PGVehicleCatalogCount()
            if count == -1, tries < 40 { tries += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check); return }
            var entry = PGVehicleEntry()
            for i in 0..<max(0, count) where PGVehicleCatalogEntryAt(UInt32(i), &entry) && entry.model == model {
                let label = withUnsafeBytes(of: entry.label) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let name = withUnsafeBytes(of: entry.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                done(label.isEmpty ? name : label); return
            }
            done(nil)
        }
        check()
    }
}
