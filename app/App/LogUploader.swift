import Foundation
import UIKit

/// Sends the app's logs to the developer (fivestarport.site/api/log, which forwards them on Telegram; GTA-240).
enum LogUploader {
    static let endpoint = URL(string: "https://fivestarport.site/api/log")!
    /// The site accepts up to 4 MB, so each log is trimmed to 1.8 MB: its start (device, settings,
    /// game files) and its end (where it stopped or crashed).
    private static let perLog = 1_800_000

    /// GTA-201: after a log is sent, offer to open the public report page (fivestarport.site/report) with the device,
    /// system and app version and the log reference filled in, so the report arrives with its log. An optional
    /// button next to OK (Kevin, 2026-10-25: on from v1.5).
    static let offersReportPage = true
    /// The report page for the log just sent (set on success when offersReportPage is on).
    private(set) static var lastReportURL: URL?

    static func reportURL(logID: String?) -> URL? {
        var parts = URLComponents(string: "https://fivestarport.site/report/")
        #if targetEnvironment(macCatalyst)
        let (system, platform) = ("macOS", "mac")
        #else
        let (system, platform) = ("iOS", "iphone")
        #endif
        parts?.queryItems = [
            URLQueryItem(name: "from", value: "app"),
            URLQueryItem(name: "device", value: GameSettings.shared.tier.model),
            URLQueryItem(name: "os", value: "\(system) \(UIDevice.current.systemVersion)"),
            URLQueryItem(name: "v", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
            URLQueryItem(name: "platform", value: platform),
        ] + (logID.map { [URLQueryItem(name: "log", value: $0)] } ?? [])
        return parts?.url
    }

    /// The alert after Send log: OK, plus "Report the problem" when the report page is on and the log went through.
    static func resultAlert(_ title: String, _ message: String) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if offersReportPage, let url = lastReportURL {
            alert.message = message + "\n\n" + AppLanguage.choose("You can also describe the problem on our report board, with this log attached. Others can vote on it, and you can follow the fix.")
            alert.addAction(UIAlertAction(title: AppLanguage.choose("Report the problem"), style: .default) { _ in UIApplication.shared.open(url) })
            lastReportURL = nil
        }
        alert.addAction(UIAlertAction(title: AppLanguage.choose("OK"), style: offersReportPage ? .cancel : .default))
        return alert
    }
    private static let head = 256_000

    static func trimmed(_ data: Data, to limit: Int = perLog) -> Data {
        guard data.count > limit else { return data }
        var result = Data(data.prefix(head))
        result.append("\n… \(data.count - limit) bytes cut …\n".data(using: .utf8)!)
        result.append(data.suffix(limit - head))
        return result
    }

    /// The newest Story mode save (SGTA5…, about 0.5 MB), so the developer can load the game where it happened
    /// (Harness/gta.py save-from-log). Mission replay restore points (MISREP) and backups are left out.
    static func latestSave() -> URL? {
        let folder = URL(fileURLWithPath: EnginePaths.filesRoot().path).appendingPathComponent("userdata/Documents/Rockstar Games/GTA V/Default")
        let saves = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return saves.filter { $0.lastPathComponent.hasPrefix("SGTA5") && $0.pathExtension.isEmpty }
            .max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                 < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func send(note: String, includeSave: Bool = false, done: @escaping ((String, String)) -> Void) {
        let save = includeSave ? latestSave().flatMap { url in (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) } } : nil
        var body = Data()
        // A stopped run and iOS's own reports go first when there are any (GTA-159); the logs share the site's 4 MB,
        // with a little less room when a save goes too.
        let logs = RunEnd.reportLogs()
        let room = max(400_000, (save == nil ? 2 * perLog : 2 * 1_400_000) / max(1, logs.filter { $0.title.hasSuffix("RUN") }.count))
        for (title, url) in logs {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            body.append("===== \(title) (\(url.lastPathComponent)) =====\n".data(using: .utf8)!)
            body.append(trimmed(data, to: title.hasSuffix("RUN") ? room : 65_536))
            body.append("\n".data(using: .utf8)!)
        }
        if let (name, data) = save {
            body.append("===== SAVE (\(name), \(data.count) bytes, base64) =====\n".data(using: .utf8)!)
            body.append(data.base64EncodedData(options: [.lineLength76Characters, .endLineWithLineFeed]))
            body.append("\n===== END SAVE =====\n".data(using: .utf8)!)
        }
        guard !body.isEmpty else { DispatchQueue.main.async { done((AppLanguage.choose("No log yet"), AppLanguage.choose("Start the game once, then try again."))) }; return }
        var url = endpoint
        #if targetEnvironment(simulator)
        // Test (PG_LOG_ENDPOINT=http://127.0.0.1:port/): the upload goes to a local catcher, not to Telegram.
        if let local = ProcessInfo.processInfo.environment["PG_LOG_ENDPOINT"].flatMap(URL.init(string:)) { url = local }
        #endif
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        #if targetEnvironment(macCatalyst)
        let system = "macOS"
        #else
        let system = "iOS"
        #endif
        request.setValue("\(GameSettings.shared.tier.model) · \(system) \(UIDevice.current.systemVersion) · \(GameSettings.shared.tier.memoryLimitMB) MB limit", forHTTPHeaderField: "X-Device")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?", forHTTPHeaderField: "X-App-Version")
        request.setValue(String(note.prefix(400)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "X-Note")
        URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let result: (String, String)
            if status == 200 {
                RunEnd.sent()
                lastReportURL = offersReportPage ? reportURL(logID: reply?["id"] as? String) : nil
                result = (AppLanguage.choose("Log sent, thank you!"), AppLanguage.interpolate(AppLanguage.choose("Reference: {arg0}. Mention it if you also ask for help in the community."), [String(describing: reply?["id"] as? String ?? "-")]))
            } else if error != nil {
                result = (AppLanguage.choose("Couldn't send the log"), AppLanguage.choose("No internet connection? Try again, or use Share log instead."))
            } else {
                result = (AppLanguage.choose("Couldn't send the log"), (reply?["error"] as? String) ?? AppLanguage.choose("Try again later, or use Share log instead."))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}

/// "Send log to the developer": its own screen so the buttons stay visible above the keyboard in landscape.
final class SendLogViewController: UIViewController {
    private let note = UITextView()
    private let status = UILabel()
    private let includeSave = UISwitch()
    var finished: ((String, String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = AppLanguage.choose("Send log to the developer")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: AppLanguage.choose("Send"), primaryAction: UIAction { [weak self] _ in self?.send() })
        navigationItem.rightBarButtonItem?.style = .done

        let info = UILabel()
        info.text = AppLanguage.choose("Sends this run's game log and the previous one: your iPhone model, iOS version, app settings and what the game printed. No personal data, photos or contacts.")
        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .footnote)
        info.textColor = .secondaryLabel
        note.font = .preferredFont(forTextStyle: .body)
        note.layer.cornerRadius = 10
        note.backgroundColor = .secondarySystemGroupedBackground
        note.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        note.accessibilityLabel = AppLanguage.choose("What happened? (optional)")
        let placeholder = UILabel()
        placeholder.text = AppLanguage.choose("What happened? (optional)")
        placeholder.textColor = .placeholderText
        placeholder.font = note.font
        placeholder.tag = 7
        note.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([placeholder.topAnchor.constraint(equalTo: note.topAnchor, constant: 10),
                                     placeholder.leadingAnchor.constraint(equalTo: note.leadingAnchor, constant: 13)])
        NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification, object: note, queue: .main) { [weak self] _ in
            self?.note.viewWithTag(7)?.isHidden = !(self?.note.text.isEmpty ?? true)
        }
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        // The save lets the developer load the game where it happened; it holds game progress only.
        let saveLabel = UILabel()
        saveLabel.text = AppLanguage.choose("Include my latest save (game progress only, about 0.5 MB), so the developer can load the game where it happened")
        saveLabel.numberOfLines = 0
        saveLabel.font = .preferredFont(forTextStyle: .footnote)
        includeSave.isOn = LogUploader.latestSave() != nil
        includeSave.isEnabled = includeSave.isOn
        let saveRow = UIStackView(arrangedSubviews: [saveLabel, includeSave])
        saveRow.spacing = 12
        saveRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [info, note, saveRow, status])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            // The note shrinks to stay above the keyboard.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            note.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let preferred = note.heightAnchor.constraint(equalToConstant: 140)
        preferred.priority = .defaultLow
        preferred.isActive = true
    }

    private func send() {
        navigationItem.rightBarButtonItem?.isEnabled = false
        note.resignFirstResponder()
        status.text = AppLanguage.choose("Sending…")
        LogUploader.send(note: note.text ?? "", includeSave: includeSave.isOn) { [weak self] result in
            guard let self else { return }
            let done = self.finished
            self.dismiss(animated: true) { done?(result.0, result.1) }
        }
    }
}
