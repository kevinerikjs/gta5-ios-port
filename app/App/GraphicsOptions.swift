import Foundation
import Metal
import UIKit
import os

/// Graphics presets. The engine reads quality settings once at boot; only the
/// resolution can change while it runs.
/// Ultra Performance (the Lite mode) sits below Battery (raw value -1, so the saved values of the
/// others stay as they were).
enum GraphicsPreset: Int, CaseIterable {
    case lite = -1, battery, performance, balanced, quality, ultra, max

    /// Ultra Performance: Battery's options, plus half-size textures and a thinner, shorter-range world
    /// (PG_LITE), for phones whose app limit is about 2-2.5 GB. PG_LITE_PRESET=0 hides it (comparisons).
    static let liteAvailable: Bool = ProcessInfo.processInfo.environment["PG_LITE_PRESET"] != "0"
    /// The presets Settings offers, lowest first.
    static var available: [GraphicsPreset] { allCases.filter { $0 != .lite || liteAvailable } }

    var title: String { [AppLanguage.choose("Ultra Performance"), AppLanguage.choose("Battery"), AppLanguage.choose("Performance"), AppLanguage.choose("Balanced"), AppLanguage.choose("Quality"), AppLanguage.choose("Ultra"), AppLanguage.choose("Max")][rawValue + 1] }
    /// Render height in pixels; width follows the screen's shape.
    var height: Int { [432, 432, 540, 720, 900, 1080, 1290][rawValue + 1] }
    var detail: String {
        [AppLanguage.choose("For iPhones with little memory: lower detail and draw distance, so the world keeps loading"),
         AppLanguage.choose("Lowest load, longest play time"), AppLanguage.choose("Today's tested setup for 6 GB iPhones"), AppLanguage.choose("Sharper image and shadows"),
         AppLanguage.choose("Higher detail textures, effects and draw distance"), AppLanguage.choose("1080p with high shaders, shadows and reflections"),
         AppLanguage.choose("Near-native resolution, high textures and full draw distance (newest Pro phones)")][rawValue + 1]
    }

    /// Engine command-line options. Shader quality never goes below 1 (the
    /// low shader set is mostly missing), and tessellation, MSAA and depth of
    /// field stay off because their shaders do not run on Metal here.
    var engineOptions: [String] {
        switch self {
        case .lite, .battery, .performance:
            return ["-shaderQuality=1", "-textureQuality=0", "-shadowQuality=-1", "-reflectionQuality=0", "-particleQuality=0",
                    "-grassQuality=0", "-cityDensity=0", "-lodScale=0", "-pedLodBias=0", "-vehicleLodBias=0", "-pedVariety=0", "-vehicleVariety=0"]
        case .balanced:
            return ["-shaderQuality=1", "-textureQuality=0", "-shadowQuality=0", "-reflectionQuality=0", "-particleQuality=0",
                    "-grassQuality=0", "-cityDensity=0.2", "-lodScale=0.2", "-pedLodBias=0", "-vehicleLodBias=0", "-pedVariety=0.2", "-vehicleVariety=0.2"]
        case .quality:
            return ["-shaderQuality=1", "-textureQuality=1", "-shadowQuality=0", "-reflectionQuality=1", "-particleQuality=1",
                    "-grassQuality=1", "-cityDensity=0.4", "-lodScale=0.4", "-pedLodBias=0.2", "-vehicleLodBias=0.2", "-pedVariety=0.4", "-vehicleVariety=0.4"]
        case .ultra:
            return ["-shaderQuality=2", "-textureQuality=1", "-shadowQuality=1", "-reflectionQuality=2", "-particleQuality=1",
                    "-grassQuality=1", "-cityDensity=0.6", "-lodScale=0.6", "-pedLodBias=0.4", "-vehicleLodBias=0.4", "-pedVariety=0.6", "-vehicleVariety=0.6"]
        case .max:
            return ["-shaderQuality=2", "-textureQuality=2", "-shadowQuality=2", "-reflectionQuality=2", "-particleQuality=2",
                    "-grassQuality=2", "-cityDensity=1", "-lodScale=1", "-pedLodBias=0.6", "-vehicleLodBias=0.6", "-pedVariety=0.8", "-vehicleVariety=0.8"]
        }
    }
}

/// One detail the player can set apart from the preset (GTA-84): an engine option and its choices.
struct GraphicsDetail {
    let option: String
    let title: String
    let values: [String]
    let names: [String]

    static let all: [GraphicsDetail] = {
        let levels = [AppLanguage.choose("Low"), AppLanguage.choose("High"), AppLanguage.choose("Very high")]
        let percent = ["0", "0.2", "0.4", "0.6", "0.8", "1"]
        return [
            GraphicsDetail(option: "textureQuality", title: AppLanguage.choose("Textures"), values: ["0", "1", "2"], names: levels),
            // Shaders never below High: the low shader set is mostly missing.
            GraphicsDetail(option: "shaderQuality", title: AppLanguage.choose("Shaders"), values: ["1", "2"], names: Array(levels.dropFirst())),
            GraphicsDetail(option: "shadowQuality", title: AppLanguage.choose("Shadows"), values: ["-1", "0", "1", "2"], names: [AppLanguage.choose("Off")] + levels),
            GraphicsDetail(option: "reflectionQuality", title: AppLanguage.choose("Reflections"), values: ["0", "1", "2"], names: levels),
            GraphicsDetail(option: "lodScale", title: AppLanguage.choose("Draw distance"), values: percent, names: percent.map { "\(Int((Double($0) ?? 0) * 100))%" }),
            GraphicsDetail(option: "grassQuality", title: AppLanguage.choose("Grass"), values: ["0", "1", "2"], names: levels),
            GraphicsDetail(option: "particleQuality", title: AppLanguage.choose("Particles"), values: ["0", "1", "2"], names: levels),
            GraphicsDetail(option: "cityDensity", title: AppLanguage.choose("Traffic and people"), values: percent, names: percent.map { "\(Int((Double($0) ?? 0) * 100))%" }),
        ]
    }()

    /// The preset's own value for this detail.
    func presetValue(_ preset: GraphicsPreset) -> String {
        preset.engineOptions.first { $0.hasPrefix("-\(option)=") }.map { String($0.dropFirst(option.count + 2)) } ?? values[0]
    }
    /// A value from the game's pause menu can lie between the choices here (GTA-166): a percentage is shown as one.
    func name(of value: String) -> String {
        if let index = values.firstIndex(of: value) { return names[index] }
        if names.allSatisfy({ $0.hasSuffix("%") }), let number = Double(value) { return "\(Int((number * 100).rounded()))%" }
        return value
    }
}

/// What this device can afford, measured before the engine starts.
struct DeviceTier {
    let memoryLimitMB: Int
    let physicalMemoryMB: Int
    let model: String
    let supportsBCTextures: Bool

    /// BC textures sampled as they are; the property exists from iOS 16.4 (before that: decoded).
    static func readsBC(_ device: MTLDevice?) -> Bool {
        guard let device else { return false }
        if #available(iOS 16.4, *) { return device.supportsBCTextureCompression }
        return false
    }

    /// capMB: Settings › Memory cap (or -memoryCapMB for one launch), 0 for none. A cap lowers the limit the app plans
    /// with too, so a test phone with more memory takes the small-memory paths of the phone it stands in for (GTA-241).
    static func probe(capMB: Int = 0) -> DeviceTier {
        var info = utsname(); uname(&info)
        var model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if targetEnvironment(macCatalyst)
        // On a Mac uname says only "arm64"; the model name (Mac16,10) tells logs and play stats which Mac it is.
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 {
            var name = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &name, &size, nil, 0) == 0 { model = String(cString: name) }
        }
        #endif
        let device = MTLCreateSystemDefaultDevice()
        let limit = Self.processMemoryLimitMB()
        return DeviceTier(memoryLimitMB: capMB > 0 ? min(limit, capMB) : limit,
                          physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                          model: model,
                          supportsBCTextures: Self.readsBC(device))
    }

    /// Jetsam limit = memory still available + what the app already uses.
    private static func processMemoryLimitMB() -> Int {
        #if targetEnvironment(simulator)
        // Model the target phone (iPhone 13 Pro Max) unless told otherwise.
        return Int(ProcessInfo.processInfo.environment["PG_SIM_MEMORY_LIMIT_MB"] ?? "") ?? 4096
        #else
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let footprint = result == KERN_SUCCESS ? Int(vm.phys_footprint) : 0
        return (Int(PGProcessAvailableMemory()) + footprint) / 1_048_576
        #endif
    }

    /// The Metal renderer needs about 700 MB less than the old renderer did. Limits of 2,600-3,400 MB (6 GB phones on
    /// a free Apple ID) got Battery until v1.5.2; Performance has the same engine options at 540 instead of 432 lines,
    /// and play stats show no cost there (GTA-242, iPhones, 2026-10-17 to 27, sessions of 3 minutes or more):
    /// Performance 1,343 sessions, 5% under 25 FPS, 3% thermal critical; Battery 13,069 sessions, 7% and 4%.
    /// The other bands match their stats: at 3,400-4,600 Balanced and above cost a lot (Quality 44% under 25 FPS).
    var recommended: GraphicsPreset {
        let byMemory: GraphicsPreset = GraphicsPreset.liteAvailable && memoryLimitMB < 2600 ? .lite : memoryLimitMB < 4600 ? .performance : memoryLimitMB < 6000 ? .balanced : memoryLimitMB < 8000 ? .quality : .ultra
        guard var ceiling = Self.heatCeiling[model] else { return byMemory }
        if ceiling == .lite && !GraphicsPreset.liteAvailable { ceiling = .battery }
        return byMemory.rawValue > ceiling.rawValue ? ceiling : byMemory
    }
    /// The highest preset recommended on phones that often reach thermal "critical" (where iOS slows the chip
    /// hard), from play stats of 2026-10-20 to 23, sessions of 3 minutes or more (GTA-175):
    /// - iPhone 12 Pro Max: 50% of sessions reached critical on Battery and 52% on Performance, 18% on Ultra
    ///   Performance, which also averaged more FPS (31.2 against 28.9). Rendering fewer pixels (Battery) didn't
    ///   help; Ultra Performance's shorter range cuts the world's CPU and memory work, where the heat comes from.
    /// - iPhone 12 Pro: 26% on Performance, 14% on Battery (and 15% on Ultra Performance), so Battery at most.
    /// Their 4 GB siblings already get Ultra Performance from the memory rule. Rechecked for v1.5.2 (GTA-242, 2026-10-17
    /// to 27, presets with 150 sessions or more): no other iPhone reaches critical in 15% of its sessions above its
    /// lowest preset (iPhone 11 Pro Max 16% and 15 Pro 15% only on Ultra Performance itself), so the table stays.
    static let heatCeiling: [String: GraphicsPreset] = ["iPhone13,4": .lite, "iPhone13,3": .battery]
    /// 4 GB iPhones (an app limit under 2,600 MB): Ultra Performance's memory settings and resolution on every preset (GTA-241).
    /// Above it, Performance at 2,098 MB evicted and reloaded textures about 20,000 times a minute and the road
    /// vanished under the car (Kevin's iPhone at a 2,098 MB cap, 2026-10-27); 27% of these phones' sessions in the
    /// last 10 days ran a preset above Ultra Performance.
    var lowMemory: Bool { GraphicsPreset.liteAvailable && memoryLimitMB < 2600 }
    /// Every preset can be chosen; those above the recommended one show a warning.
    var allowed: [GraphicsPreset] { GraphicsPreset.available }
    /// Presets shown with a warning because they may run out of memory or heat up.
    func risky(_ preset: GraphicsPreset) -> Bool { preset.rawValue > recommended.rawValue }
    /// For the log (kept in English).
    var summary: String { "\(model) · \(physicalMemoryMB / 1024) GB · app limit \(memoryLimitMB) MB\(supportsBCTextures ? " · BC textures" : "")" }
    /// The same line for Settings, in the app's language.
    var displaySummary: String {
        AppLanguage.interpolate(AppLanguage.choose("{arg0} · {arg1} GB · app limit {arg2} MB"), [model, String(physicalMemoryMB / 1024), String(memoryLimitMB)])
            + (supportsBCTextures ? " · " + AppLanguage.choose("BC textures") : "")
    }

    /// Whether this install was signed with the increased memory limit (Apple grants it per
    /// signature, so a sideloading tool can drop it). nil when it can't be read.
    static let increasedMemoryGranted: Bool? = entitlement("com.apple.developer.kernel.increased-memory-limit")
    /// For Settings and the log: is the extra memory actually in effect?
    var increasedMemoryStatus: String {
        #if targetEnvironment(macCatalyst)
        // macOS has no per-app memory limit to raise (GTA-9).
        return AppLanguage.interpolate(AppLanguage.choose("The game may use up to {arg0} MB of this Mac's memory."), ["\(memoryLimitMB)"])
        #else
        switch Self.increasedMemoryGranted {
        case true?: return AppLanguage.interpolate(AppLanguage.choose("Extra memory: on. This install has the increased memory limit, so the game may use up to {arg0} MB."), ["\(memoryLimitMB)"])
        case false?: return AppLanguage.interpolate(AppLanguage.choose("Extra memory: off. This install was signed without the increased memory limit, so the game gets the normal {arg0} MB. For more, install the app with AltStore 2.3 or newer (free Apple ID) or with a paid developer account."), ["\(memoryLimitMB)"])
        case nil: return AppLanguage.interpolate(AppLanguage.choose("Extra memory: unknown. The game may use up to {arg0} MB."), ["\(memoryLimitMB)"])
        }
        #endif
    }

    /// Reads a boolean entitlement of this app (SecTask is not public on iOS, so it is looked up at run time).
    private static func entitlement(_ key: String) -> Bool? {
        #if targetEnvironment(simulator)
        return nil
        #else
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias Copy = @convention(c) (AnyObject, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<AnyObject>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let create = dlsym(handle, "SecTaskCreateFromSelf"), let copy = dlsym(handle, "SecTaskCopyValueForEntitlement"),
              let task = unsafeBitCast(create, to: Create.self)(nil)?.takeRetainedValue() else { return nil }
        let value = unsafeBitCast(copy, to: Copy.self)(task, key as CFString, nil)?.takeRetainedValue()
        return (value as? Bool) ?? false
        #endif
    }
}

enum GraphicsConfiguration {
    /// The screen's height in pixels (the "Native" resolution).
    static var nativeHeight: Int {
        let screen = UIScreen.main
        return Int(min(screen.nativeBounds.width, screen.nativeBounds.height))
    }
    /// Resolutions offered in Settings, besides "Auto" (the detail preset's own).
    static var resolutionChoices: [Int] { [540, 720, 900, 1080].filter { $0 < nativeHeight } + [nativeHeight] }
    /// Width/height to render at: the chosen height (or the preset's), shaped like the screen so the
    /// picture is not stretched.
    static func size(for preset: GraphicsPreset, renderHeight: Int, screen: CGSize, matchScreenShape: Bool) -> (Int, Int) {
        let aspect = matchScreenShape && screen.height > 0 ? max(screen.width, screen.height) / min(screen.width, screen.height) : 16.0 / 9.0
        var height = Double(renderHeight > 0 ? renderHeight : preset.height)
        // 4 GB iPhones render at Ultra Performance's height on every preset too (GTA-241). Kevin's iPhone at a 2,098 MB
        // cap, the benchmark, 2 runs each: Performance at 540 lines asked to evict 38-41 times and drew flat untextured
        // buildings at the same moments where 432 lines asked 13-14 times and drew the street (phone-perf/shots-1028-0342).
        if preset != .lite && GameSettings.shared.tier.lowMemory { height = min(height, Double(GraphicsPreset.lite.height)) }
        height = min(max(height, 360), Double(max(nativeHeight, 720)))
        let width = min(height * aspect, 3840)
        func even(_ value: Double) -> Int { Int(value.rounded()) & ~1 }
        return (even(width), even(height))
    }

    /// Pass the chosen settings to the engine. Call before PGStartEngine.
    static func apply(_ settings: GameSettings, screen: CGSize, tv: Bool = false) -> String {
        let preset = settings.graphicsPreset
        let (width, height) = size(for: preset, renderHeight: settings.renderHeight, screen: screen, matchScreenShape: tv || settings.matchScreenShape)
        // The player's own details replace the preset's (GTA-84).
        let overrides = settings.graphicsOverrides
        // 4 GB iPhones keep Ultra Performance's memory settings whatever the preset (GTA-241): Lite's half-size
        // textures and shorter range, the settings below, and the lowest texture set, even as the player's own detail.
        let lowMemory = settings.tier.lowMemory
        let options = preset.engineOptions.map { option -> String in
            let name = String(option.dropFirst().prefix { $0 != "=" })
            if lowMemory && name == "textureQuality" { return "-textureQuality=0" }
            return overrides[name].map { "-\(name)=\($0)" } ?? option
        }
        let own = GraphicsDetail.all.compactMap { detail in overrides[detail.option].map { "\(detail.option) \($0)" } }
        // The engine and renderer read PG_LITE when they start, after this. The Lite build always sets it.
        if preset == .lite || lowMemory { setenv("PG_LITE", "1", 1) } else if !Theme.isLite { unsetenv("PG_LITE") }
        // The smallest memory limits (4 GB iPhones: about 2.1 GB for the app) can't hold the city at Lite's usual
        // detail: the engine evicted what it needed a moment later, re-read the same files hundreds of times and
        // the ground stayed grey. There Lite draws detail closer and places fewer people and cars, and what was
        // just loaded isn't evicted for 4 s (GTA-148; This device › Experimental turns it off). Simulator, 2,098 MB,
        // a 4.8 km drive scored against the same drive without a limit: detail 0.4 was closest in all four runs;
        // 0.5 and 0.35 had runs worse than today, and without the 4 s the files were re-read 4-5 times as much.
        // On iPhones that decode BC textures (A13-A15), textures of 512×512 or more also lose their second level there
        // (GTA-148; the renderer skips it where the GPU reads BC). Lab simulator, 2,348 MB, BC decoded, the same 4.8 km
        // drive, 6 runs each: the guard held streaming in 4-23% of the 10 s intervals instead of 47-95%, files re-read
        // 241-274 MB per interval instead of 272-351, for 15-20 MB less texture memory. "Lighter big textures" in This
        // device › Experimental turns it off along with the other big-texture cut.
        // Switches already set (tests) win.
        if preset == .lite || Theme.isLite || lowMemory, settings.tier.memoryLimitMB < 2600, settings.steadyCityLowMemory {
            var values = [("PG_LITE_LOD", "0.4"), ("PG_LITE_DENSITY", "0.25"), ("PG_EVICT_PROTECT_MS", "4000")]
            if settings.lighterBigTextures { values.append(("PG_LITE_BIG_MIP_SKIP", "512")) }
            for (name, value) in values where getenv(name) == nil {
                setenv(name, value, 1)
            }
        }
        // 4 GB iPhones (under 2,600 MB, GTA-241): the memory guard keeps 192 MB free instead of 384, and the three
        // smaller GTA-217 memory cuts are on there: one engine function table for all threads (about 76 MB), freed
        // engine blocks handed back from 16 KB, BC block copies only for textures of 4,096 texels or fewer. At 2,098 MB
        // the 384 MB reserve meant "evict" above 1,714 MB, below what the city needs, so the engine evicted and
        // reloaded all the time and the ground vanished. Lab simulator, 2,098 MB, Ultra Performance with GTA-148's
        // settings, the benchmark: evict asks 172 per 10 s instead of 2,600, files loaded twice as often, and a lower
        // footprint and peak than before. Switches already set (tests) win.
        if settings.tier.lowMemory {
            for (name, value) in [("PG_GUARD_RESERVE_MB", "192"), ("PG_SHARED_TABLES", "1"), ("PG_HEAP_RETURN_MIN_KB", "16"), ("PG_BC_COPY_TEXELS", "4096")]
            where getenv(name) == nil {
                setenv(name, value, 1)
            }
        }
        PGSetMemoryCap(Int32(settings.memoryCapMB))
        PGSetSharperUpscaling(settings.sharperUpscaling ? 1 : 0)
        PGSetPresentInterval(GameSettings.presentInterval(settings.frameRateCap))
        var pointers = options.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        pointers.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                PGConfigureEngine($0, UInt32(buffer.count), Int32(width), Int32(height), GameSettings.engineFrameLimit(settings.frameRateCap))
            }
        }
        return "\(preset.title) \(width)×\(height) at \(GameSettings.frameRateTitle(settings.frameRateCap))" + (own.isEmpty ? "" : ", own settings: " + own.joined(separator: ", "))
            + (lowMemory && preset != .lite ? ", with Ultra Performance's memory settings (under 2,600 MB)" : "")
    }
}
