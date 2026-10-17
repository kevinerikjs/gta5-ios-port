import UIKit

/// The look shared by the start screen, the game files screens and Settings: the app icon's sunset
/// over blue, glass panels on top of the background art, and one warm accent for the main actions.
enum Theme {
    /// The app's version as players should quote it in reports, e.g. "v1.3 (6)".
    /// The community: official releases, help and announcements.
    static let telegramURL = URL(string: "https://t.me/fivestarport")!
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        // Each release has one build number, so the marketing version alone identifies it.
        return "v\(info?["CFBundleShortVersionString"] as? String ?? "?")" + (isLite ? " Lite" : "")
    }()
    /// The Lite build for iPhones with little memory: Info.plist PGLiteMode (build_ipa.sh --lite), or PG_LITE=1.
    static let isLite: Bool = (Bundle.main.object(forInfoDictionaryKey: "PGLiteMode") as? Bool ?? false)
        || (ProcessInfo.processInfo.environment["PG_LITE"].map { $0 != "0" } ?? false)
    static let accent = UIColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1)        // sunset orange
    static let accentDeep = UIColor(red: 0.95, green: 0.36, blue: 0.16, alpha: 1)
    static let ok = UIColor(red: 0.30, green: 0.85, blue: 0.47, alpha: 1)
    static let warning = UIColor(red: 1.0, green: 0.78, blue: 0.26, alpha: 1)
    static let problem = UIColor(red: 1.0, green: 0.42, blue: 0.38, alpha: 1)
    static let text = UIColor.white
    static let secondaryText = UIColor(white: 1, alpha: 0.68)
    static let tertiaryText = UIColor(white: 1, alpha: 0.45)
    static let night = UIColor(red: 0.03, green: 0.05, blue: 0.11, alpha: 1)       // behind everything
    static let panelStroke = UIColor(white: 1, alpha: 0.12)

    static func display(_ size: CGFloat, _ weight: UIFont.Weight = .heavy) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
    }
    static func body(_ size: CGFloat = 15, _ weight: UIFont.Weight = .regular) -> UIFont { .systemFont(ofSize: size, weight: weight) }

    /// A blurred glass panel with a hairline edge. Put content in `contentView`.
    static func panel(cornerRadius: CGFloat = 18) -> UIVisualEffectView {
        let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        panel.layer.cornerRadius = cornerRadius
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.layer.borderWidth = 1
        panel.layer.borderColor = panelStroke.cgColor
        return panel
    }

    /// The background art (the beach selfie) with darkening on the left where the controls sit.
    static func backdrop(image name: String, darken: CGFloat = 0.55) -> UIView {
        let view = UIView()
        view.backgroundColor = night
        let art = UIImageView(image: UIImage(named: name))
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        let shade = GradientView(colors: [night.withAlphaComponent(0.92), night.withAlphaComponent(darken), night.withAlphaComponent(0.05)],
                                 locations: [0, 0.42, 1], horizontal: true)
        let floor = GradientView(colors: [.clear, night.withAlphaComponent(0.6)], locations: [0.6, 1], horizontal: false)
        for layer in [art, shade, floor] as [UIView] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: view.leadingAnchor), layer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                layer.topAnchor.constraint(equalTo: view.topAnchor), layer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        view.isUserInteractionEnabled = false
        return view
    }

    /// The background art behind Settings: evenly darkened so every row stays readable.
    static func dimmedBackdrop(image name: String) -> UIView {
        let view = UIView()
        view.backgroundColor = night
        let art = UIImageView(image: UIImage(named: name))
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        let shade = UIView()
        shade.backgroundColor = night.withAlphaComponent(0.78)
        for layer in [art, shade] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: view.leadingAnchor), layer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                layer.topAnchor.constraint(equalTo: view.topAnchor), layer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        view.isUserInteractionEnabled = false
        return view
    }
    static func styleSettingsTable(_ table: UITableView) {
        table.backgroundColor = night
        table.backgroundView = dimmedBackdrop(image: "SettingsBackground")
        table.separatorColor = UIColor(white: 1, alpha: 0.1)
    }
    /// A table row on the dark art.
    static let rowBackground = UIColor(white: 1, alpha: 0.07)
    static let rowSelected = UIColor(white: 1, alpha: 0.14)

    /// The big main-action button (Play, Install): warm gradient, rounded, bold.
    static func primaryButton(_ title: String, symbol: String? = nil) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = symbol.map { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(weight: .heavy)) } ?? nil
        config.imagePadding = 10
        config.cornerStyle = .capsule
        config.baseForegroundColor = UIColor(red: 0.16, green: 0.07, blue: 0.02, alpha: 1)
        config.background.backgroundColor = accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 30, bottom: 14, trailing: 30)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = display(20, .heavy); return attributes
        }
        let button = UIButton(configuration: config)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isEnabled ? (button.isHighlighted ? accentDeep : accent) : UIColor(white: 1, alpha: 0.16)
            button.configuration?.baseForegroundColor = button.isEnabled ? UIColor(red: 0.16, green: 0.07, blue: 0.02, alpha: 1) : UIColor(white: 1, alpha: 0.6)
        }
        button.layer.shadowColor = accent.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 18
        button.layer.shadowOffset = .zero
        return button
    }

    /// A quieter glass button (Settings, Controls layout, secondary actions).
    static func glassButton(_ title: String, symbol: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseForegroundColor = text
        config.background.backgroundColor = UIColor(white: 1, alpha: 0.12)
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = body(15, .semibold); return attributes
        }
        return UIButton(configuration: config)
    }

    /// Navigation bars and tables in Settings and the game files screens.
    static func styleNavigation(_ navigation: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.titleTextAttributes = [.foregroundColor: text, .font: display(18, .bold)]
        appearance.largeTitleTextAttributes = [.foregroundColor: text, .font: display(32, .heavy)]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.compactAppearance = appearance
        navigation.navigationBar.tintColor = accent
        navigation.overrideUserInterfaceStyle = .dark
        navigation.view.tintColor = accent
    }
}

/// A view that draws a linear gradient (backdrop shading).
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(colors: [UIColor], locations: [NSNumber], horizontal: Bool) {
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        gradient.colors = colors.map(\.cgColor)
        gradient.locations = locations
        gradient.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        gradient.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
