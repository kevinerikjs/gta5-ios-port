import Foundation
import UIKit

/// Anonymous player stats (GTA-137): how many people play each day, on which iPhones, how long, how smoothly,
/// which missions they reach, and whether mods or cheats are in use. Each install gets a random ID; no Apple
/// ID, names, file paths or log text are sent. Events wait in a small file and go out in batches to the
/// website's /api/stats, which checks them against its own list and forwards them to the developer's
/// stats service (the service's key lives on the server, not in the app). Simulator builds send nothing
/// unless PG_STATS_ENDPOINT points them somewhere for a test, and builds made with PG_NO_STATS send nothing.
final class Analytics {
    static let shared = Analytics()

    private let queue = DispatchQueue(label: "analytics")
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("stats-queue.json")
    private var pending: [[String: Any]] = []
    private var sending = false
    private var timer: DispatchSourceTimer?
    private let endpoint: URL?
    let installID: String

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "statsInstallID") { installID = saved } else {
            installID = UUID().uuidString.lowercased(); defaults.set(installID, forKey: "statsInstallID")
        }
        #if targetEnvironment(simulator)
        endpoint = ProcessInfo.processInfo.environment["PG_STATS_ENDPOINT"].flatMap(URL.init(string:))
        #elseif PG_NO_STATS
        endpoint = nil   // the developer's own test builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS PG_NO_STATS) don't count
        #else
        endpoint = URL(string: "https://fivestarport.vercel.app/api/stats")
        #endif
        if let data = try? Data(contentsOf: file), let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { pending = saved }
    }

    /// At launch: count the app open, then send every few minutes and when the app goes to the background.
    func start() {
        track("app_open")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 300)
        timer.setEventHandler { [weak self] in self?.send() }
        timer.resume()
        self.timer = timer
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            // A moment later, so the session that just ended (PlayStats) goes out with it.
            let task = UIApplication.shared.beginBackgroundTask(withName: "stats")
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.send { UIApplication.shared.endBackgroundTask(task) } }
        }
    }

    func track(_ event: String, _ properties: [String: Any] = [:]) {
        let item: [String: Any] = ["e": event, "t": Int64(Date().timeIntervalSince1970 * 1000), "u": UUID().uuidString.lowercased(), "p": properties]
        queue.async {
            self.pending.append(item)
            if self.pending.count > 500 { self.pending.removeFirst(self.pending.count - 500) }
            self.save()
        }
    }

    /// The same for every event: the app and the iPhone, nothing about the player.
    private lazy var common: [String: Any] = {
        let tier = GameSettings.shared.tier
        var values: [String: Any] = [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "device": tier.model, "ios": UIDevice.current.systemVersion,
            "memory_limit_mb": tier.memoryLimitMB, "physical_memory_gb": tier.physicalMemoryMB / 1024,
            "language": AppLanguage.current.rawValue,
        ]
        if let granted = DeviceTier.increasedMemoryGranted { values["extra_memory"] = granted }
        return values
    }()

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: pending) { try? data.write(to: file, options: .atomic) }
    }

    /// Sends up to 50 waiting events; they're kept and tried again later if there's no connection.
    private func send(done: (() -> Void)? = nil) {
        guard let endpoint, !sending, !pending.isEmpty else { done?(); return }
        let batch = Array(pending.prefix(50))
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": installID, "common": common, "events": batch]) else { done?(); return }
        sending = true
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: body) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.sending = false
                // Delivered, or refused for good (400): drop them. Anything else: try again later.
                if status == 200 || status == 400 { self.pending.removeFirst(min(batch.count, self.pending.count)); self.save() }
                done?()
            }
        }.resume()
    }
}

/// Turns what the game is doing into stats: game start, sessions, missions, engine stops and cheats. Fed by
/// the log lines the app already writes and by the 10-second health check.
final class PlayStats {
    private var mode = "story"
    private var started: CFTimeInterval?
    private var fps: [Double] = []
    private var thermal = 0
    private var missions = 0
    /// Health ticks with a game controller connected, of all ticks with a frame rate (GTA-200).
    private var controllerTicks = 0
    private var mission = ""
    private var missionStarted: CFTimeInterval = 0
    private var missionFailed = false
    private var mods = 0, scriptMods = 0, addonPacks = 0
    private var lastLine = ""
    /// The cause the stop panel named (StopCause.Kind, GTA-178), for engine_stop.
    private var stopCause = ""
    private var lastGameStart: CFTimeInterval = 0

    func gameStarting(_ mode: GameMode, sandboxMap: Int) {
        self.mode = mode == .story ? "story" : sandboxMap == 1 ? "test_map" : "sandbox"
    }

    func line(_ line: String) {
        if line.hasPrefix("Stop cause: ") { stopCause = String(line.dropFirst(12).prefix { $0 != " " }); return }
        defer { lastLine = line }
        if line == "WORLD_READY" {
            let now = CACurrentMediaTime()
            guard now - lastGameStart > 60 else { return }   // a world reload during play is not a new game
            lastGameStart = now; started = now
            let settings = GameSettings.shared
            let experimental = [settings.smarterTextureLoading ? "textures" : nil, settings.lighterBigTextures ? "big_mips" : nil, settings.fastEngineThreads ? "threads" : nil, settings.compressedAlphaTextures ? "alpha_astc" : nil, settings.steadyCityLowMemory ? "low_mem_city" : nil, settings.meshMemoryRelease ? "mesh_release" : nil, settings.smallerEngineHeaps ? "small_heaps" : nil].compactMap { $0 }
            Analytics.shared.track("game_start", ["mode": mode, "preset": String(describing: settings.graphicsPreset), "mods": mods, "script_mods": scriptMods,
                                                  "addon_packs": addonPacks, "experimental": experimental.joined(separator: ","), "files": GameFolder.isChosen || GameFolder.inAppFolder ? "local" : "server"])
        } else if line.hasPrefix("Mods active: ") {
            mods = Int(line.dropFirst(13).prefix { $0.isNumber }) ?? 0
            if let range = line.range(of: #"(\d+) add-on pack"#, options: .regularExpression) { addonPacks = Int(line[range].prefix { $0.isNumber }) ?? 0 }
        } else if line.hasPrefix("Script mods active: ") {
            scriptMods = Int(line.dropFirst(20).prefix { $0.isNumber }) ?? 0
        } else if line.hasPrefix("Cheats: requested ") || line.hasPrefix("Story cheat: ") {
            let name = line.hasPrefix("Story cheat: ") ? String(line.dropFirst(13)) : String(line.dropFirst(18).dropLast())
            Analytics.shared.track("cheat_used", ["cheat": String(name.prefix(40))])
        } else if line.hasPrefix("Vehicle menu: requested ") {
            Analytics.shared.track("cheat_used", ["cheat": "Vehicle spawner"])
        } else if line == "The engine stopped: showing Send log and Settings." {
            // The line before says why (a trap, or an engine error); only its first words, without paths or addresses.
            let reason = lastLine.replacingOccurrences(of: #"(/[^ ]+)|(0x[0-9a-fA-F]+)"#, with: "…", options: .regularExpression)
            Analytics.shared.track("engine_stop", ["reason": String(reason.prefix(120)), "cause": stopCause.isEmpty ? "unknown" : stopCause, "minutes": minutes, "mode": mode])
            stopCause = ""
            sessionEnded(); started = nil
        }
    }

    private var minutes: Double { started.map { (CACurrentMediaTime() - $0) / 60 } ?? 0 }

    /// Every 10 s while playing: the frame rate, how hot the phone is, and the mission running.
    func health(fps value: Double, thermal state: Int, mission name: String?, failedScreen: Bool, controller: Bool = false) {
        guard started != nil else { return }
        if value > 0 { fps.append(value); if controller { controllerTicks += 1 } }
        thermal = max(thermal, state)
        // The story context says "fbi5A (FIB5)": the script name is the mission.
        guard let name = name.map({ String($0.prefix { $0 != " " }) }) else { return }
        if name != mission {
            if !mission.isEmpty {
                // Ended without the Mission failed screen: passed (or quit from the pause menu, which looks the same).
                Analytics.shared.track("mission_end", ["mission": mission, "outcome": missionFailed ? "failed" : "passed", "minutes": (CACurrentMediaTime() - missionStarted) / 60])
            }
            mission = name; missionFailed = false; missionStarted = CACurrentMediaTime()
            if !name.isEmpty { missions += 1; Analytics.shared.track("mission_start", ["mission": name]) }
        }
        if failedScreen, !missionFailed, !mission.isEmpty { missionFailed = true; Analytics.shared.track("mission_failed", ["mission": mission]) }
    }

    /// The app went to the background or the engine stopped: one session ends.
    func sessionEnded() {
        guard started != nil else { return }
        let sorted = fps.sorted()
        var values: [String: Any] = ["mode": mode, "minutes": minutes, "missions": missions, "max_thermal": ["nominal", "fair", "serious", "critical"][min(3, thermal)]]
        if !sorted.isEmpty { values["avg_fps"] = sorted.reduce(0, +) / Double(sorted.count); values["min_fps"] = sorted[sorted.count / 20] }
        // The frame rate chosen and whether a controller was mostly connected, so frame rates compare like for like (GTA-200).
        values["fps_cap"] = GameSettings.shared.frameRateCap
        values["controller"] = !sorted.isEmpty && controllerTicks * 2 > sorted.count
        Analytics.shared.track("session_end", values)
        started = CACurrentMediaTime(); fps = []; thermal = 0; missions = 0; controllerTicks = 0
    }

}
