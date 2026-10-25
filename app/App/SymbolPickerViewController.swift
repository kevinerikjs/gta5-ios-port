import UIKit

/// Every SF Symbol this iOS has, in Apple's order, as a grid with search (GTA-210): icons for on-screen mod buttons.
/// The names come from Resources/sf-symbols.json (Scripts/make_symbol_list.py, from the Mac's CoreGlyphs bundle).
final class SymbolPickerViewController: UICollectionViewController, UISearchResultsUpdating {
    private struct Symbol { let name: String; let words: String }
    private static let all: [Symbol] = {
        guard let url = Bundle.main.url(forResource: "sf-symbols", withExtension: "json"), let data = try? Data(contentsOf: url),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String]] else { return [] }
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            // Only symbols this iOS has: each row says the iOS version that brought it.
            let parts = row[1].split(separator: ".").compactMap { Int($0) }
            let needed = OperatingSystemVersion(majorVersion: parts.first ?? 13, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else { return nil }
            return Symbol(name: row[0], words: row.count > 2 ? row[2] : "")
        }
    }()
    private var shown = SymbolPickerViewController.all
    private let selected: String
    private let onPick: (String) -> Void

    init(selected: String, onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.onPick = onPick
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 52, height: 52)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        super.init(collectionViewLayout: layout)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("All icons")
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.register(Cell.self, forCellWithReuseIdentifier: "icon")
        collectionView.keyboardDismissMode = .onDrag
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = AppLanguage.choose("Search icons (in English)")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    // Every word must match the symbol's name or Apple's search words for it ("car", "light", "arrow up").
    func updateSearchResults(for searchController: UISearchController) {
        let words = (searchController.searchBar.text ?? "").lowercased().split(separator: " ").map(String.init)
        shown = words.isEmpty ? Self.all : Self.all.filter { symbol in words.allSatisfy { symbol.name.contains($0) || symbol.words.contains($0) } }
        collectionView.reloadData()
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "icon", for: indexPath) as! Cell
        let symbol = shown[indexPath.item]
        cell.show(symbol.name, selected: symbol.name == selected)
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick(shown[indexPath.item].name)
        navigationController?.popViewController(animated: true)
    }

    private final class Cell: UICollectionViewCell {
        private let image = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.layer.cornerRadius = 10
            image.contentMode = .scaleAspectFit
            image.tintColor = .label
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            image.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(image)
            NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                                         image.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)])
            isAccessibilityElement = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        func show(_ name: String, selected: Bool) {
            image.image = UIImage(systemName: name)
            accessibilityLabel = name.replacingOccurrences(of: ".", with: " ")
            accessibilityTraits = selected ? [.button, .selected] : .button
            contentView.backgroundColor = selected ? UIColor.tintColor.withAlphaComponent(0.25) : .secondarySystemGroupedBackground
        }
    }
}
