import UIKit

/// On launch, asks the website for the newest release, and when it is newer than this app, a popup points to its
/// post in the Telegram group's Releases topic, where every new IPA is posted. Each new version is shown once.
/// fivestarport.site/latest.json ({"version": "1.4.6", "post": "https://t.me/fivestarport/33208"}) is written when
/// a release is posted to Telegram (telegram-ipa-watcher). It asked GitHub until the account was suspended (GTA-161).
enum UpdateCheck {
    private static let latestRelease = URL(string: "https://fivestarport.site/latest.json")!
    /// The Releases topic of the Telegram group, when the answer names no post.
    private static let releasesTopic = URL(string: "https://t.me/fivestarport/786")!
    private static let shownKey = "updatePromptShownFor"

    static func run(from presenter: UIViewController, log: @escaping (String) -> Void) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard status == 200, let version = answer?["version"] as? String else {
                log("Update check: no answer from the website (HTTP \(status)).")
                return
            }
            let latest = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let post = (answer?["post"] as? String).flatMap(URL.init(string:)).flatMap { $0.host == "t.me" ? $0 : nil } ?? releasesTopic
            guard isNewer(latest, than: current) else { log("Update check: v\(current) is the newest (the website has v\(latest))."); return }
            DispatchQueue.main.async {
                guard UserDefaults.standard.string(forKey: shownKey) != latest else {
                    log("Update check: v\(latest) is out (this is v\(current)); already told the player.")
                    return
                }
                log("Update check: v\(latest) is out (this is v\(current)); showing the update popup.")
                show(latest: latest, current: current, post: post, from: presenter)
            }
        }.resume()
    }

    /// "1.3.10" > "1.3.9": compared number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func show(latest: String, current: String, post: URL, from presenter: UIViewController) {
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // Another popup is up (a startup notice): try again once it is gone.
        if top is UIAlertController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { show(latest: latest, current: current, post: post, from: presenter) }
            return
        }
        UserDefaults.standard.set(latest, forKey: shownKey)
        let alert = UIAlertController(
            title: AppLanguage.choose("Update available"),
            message: AppLanguage.interpolate(AppLanguage.choose("Version {arg0} is out. You have {arg1}.\n\nThe new IPA is posted in the Releases topic of our Telegram group. Install it the same way you installed this one."), ["v" + latest, "v" + current]),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLanguage.choose("Later"), style: .cancel))
        let open = UIAlertAction(title: AppLanguage.choose("Open Telegram"), style: .default) { _ in UIApplication.shared.open(post) }
        alert.addAction(open)
        alert.preferredAction = open
        top.present(alert, animated: true)
    }
}
