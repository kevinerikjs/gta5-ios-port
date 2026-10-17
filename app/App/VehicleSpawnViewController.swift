import UIKit

struct SpawnVehicle {
    let model: UInt32
    let name: String
    let title: String
    let category: String

    init(_ entry: PGVehicleEntry) {
        model = entry.model
        var entry = entry
        name = withUnsafeBytes(of: &entry.name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let label = withUnsafeBytes(of: &entry.label) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        title = (label.isEmpty || label == "CARNOTFOUND" ? name : label).replacingOccurrences(of: "_", with: " ").capitalized
        let classes = ["Compacts", "Sedans", "SUVs", "Coupes", "Muscle", "Sports classics", "Sports", "Super",
                       "Motorcycles", "Off-road", "Industrial", "Utility", "Vans", "Cycles", "Boats",
                       "Helicopters", "Planes", "Service", "Emergency", "Military", "Commercial", "Trains"]
        category = Int(entry.vehicleClass) < classes.count ? classes[Int(entry.vehicleClass)] : "Other"
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
            "\(title) \(name) \(category)".localizedCaseInsensitiveContains(String(word))
        }
    }
}

/// The catalogue comes from registered engine models, including installed DLC.
/// No game metadata or hand-maintained model list is bundled with the port.
final class VehicleSpawnViewController: UITableViewController, UISearchResultsUpdating {
    var vehicleSelected: ((SpawnVehicle, Bool) -> Void)?
    private var vehicles: [SpawnVehicle] = []
    private var filtered: [SpawnVehicle] = []
    private var enterVehicle = true
    private var timer: Timer?
    private var loadingSince = Date()
    private let search = UISearchController(searchResultsController: nil)
    private let message = UILabel()

    init() {
        super.init(style: .insetGrouped)
        title = AppLanguage.choose("Spawn vehicle")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        Theme.styleSettingsTable(tableView)
        tableView.keyboardDismissMode = .onDrag
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = AppLanguage.choose("Search name, model or category")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: AppLanguage.choose("Done"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        message.textColor = Theme.secondaryText
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = Theme.body(16)
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        if let background = tableView.backgroundView {
            background.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                message.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
                message.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            ])
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard vehicles.isEmpty else { return }
        PGRequestVehicleCatalog()
        loadingSince = Date()
        readCatalog()
        if vehicles.isEmpty {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.readCatalog() }
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate(); timer = nil
    }
    private func readCatalog() {
        let count = PGVehicleCatalogCount()
        if count < 0 {
            let waiting = count == -1 && Date().timeIntervalSince(loadingSince) < 15
            message.text = AppLanguage.choose(waiting ? "Reading available vehicles…" : "Vehicles are unavailable. Return to gameplay, then reopen this menu.")
            message.isHidden = false
            if !waiting { timer?.invalidate(); timer = nil }
            return
        }
        timer?.invalidate(); timer = nil
        vehicles = (0..<count).compactMap { index in
            var entry = PGVehicleEntry()
            return PGVehicleCatalogEntryAt(UInt32(index), &entry) ? SpawnVehicle(entry) : nil
        }.sorted { ($0.title, $0.name) < ($1.title, $1.name) }
        updateSearchResults(for: search)
    }
    func updateSearchResults(for searchController: UISearchController) {
        filtered = vehicles.filter { $0.matches(searchController.searchBar.text ?? "") }
        if vehicles.isEmpty || filtered.isEmpty {
            message.text = AppLanguage.choose(vehicles.isEmpty ? "No vehicles are available yet. Return to gameplay, then reopen this menu." : "No matching vehicles")
            message.isHidden = false
        } else { message.isHidden = true }
        tableView.reloadData()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : filtered.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 && !vehicles.isEmpty ? "\(filtered.count) / \(vehicles.count) " + AppLanguage.choose("Vehicles") : nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? AppLanguage.choose("Spawns ahead of you when gameplay resumes. Keeps up to two menu vehicles; an older empty one is removed before another loads. Use open space for aircraft and water for boats. Trailers and rail vehicles may not be drivable.") : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = Theme.text
        content.secondaryTextProperties.color = Theme.secondaryText
        if indexPath.section == 0 {
            content.text = AppLanguage.choose("Enter spawned vehicle")
            let toggle = UISwitch()
            toggle.isOn = enterVehicle
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.enterVehicle = toggle?.isOn ?? true }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else {
            let vehicle = filtered[indexPath.row]
            content.text = vehicle.title
            content.secondaryText = "\(vehicle.name) · \(AppLanguage.choose(vehicle.category))"
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }
    // Apply the glass styling after UIKit configures the row, exactly as the
    // other Settings pages do. Content configuration can reset its background.
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.backgroundColor = Theme.rowBackground
        let selected = UIView()
        selected.backgroundColor = Theme.rowSelected
        cell.selectedBackgroundView = selected
    }
    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        var content = header.defaultContentConfiguration()
        content.text = self.tableView(tableView, titleForHeaderInSection: section)
        content.textProperties.font = Theme.display(15, .bold)
        content.textProperties.color = Theme.text
        content.textProperties.transform = .uppercase
        header.contentConfiguration = content
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let vehicle = filtered[indexPath.row], enter = enterVehicle
        let selected = vehicleSelected
        navigationController?.dismiss(animated: true) { selected?(vehicle, enter) }
    }
}
