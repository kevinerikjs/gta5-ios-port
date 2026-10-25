import Foundation

/// A script mod's keys, found before it runs (GTA-179), the on-screen buttons the player made for them (GTA-180) and
/// keys that answer a mod's own key (GTA-181). Script Hook V mods (.asi) are driven by PC keys: their .ini files name
/// the important ones with a reason ("MenuKey=114 //Enter Menu"), and their code passes the others to GetAsyncKeyState
/// as constants. Both are read here without running the mod (Harness/mod_keys.py is the same scan for the harness).
enum ModKeys {
    /// One thing the mod does with keys: a single key, or keys held together ("J + Num 1" in Simple Trainer).
    struct Binding: Hashable {
        enum Source { case settings, code }
        let keys: [Int]
        let source: Source
        /// The setting's name ("MenuKey") and what its comment says it does ("Enter Menu"); empty for keys in the code.
        let setting: String
        let reason: String
        let file: String
    }
    struct Scan {
        var bindings: [Binding] = []
        /// The mod registers Script Hook V's keyboard handler: it gets every key press and may use keys not listed.
        var everyKey = false
        /// Its .asi file names, as the engine knows them.
        var scripts: [String] = []
    }

    /// The name of a Windows virtual-key code, as on a PC keyboard.
    static func name(_ vk: Int) -> String {
        switch vk {
        case 8: return "Backspace"
        case 9: return "Tab"
        case 13: return "Enter"
        case 16: return "Shift"
        case 17: return "Ctrl"
        case 18: return "Alt"
        case 27: return "Esc"
        case 32: return "Space"
        case 33: return "Page Up"
        case 34: return "Page Down"
        case 35: return "End"
        case 36: return "Home"
        case 37: return "←"
        case 38: return "↑"
        case 39: return "→"
        case 40: return "↓"
        case 45: return "Insert"
        case 46: return "Delete"
        case 48...57: return String(vk - 48)
        case 65...90: return String(UnicodeScalar(UInt8(vk)))
        case 91, 92: return "Win"
        case 93: return "Menu"
        case 96...105: return "Num \(vk - 96)"
        case 106: return "Num *"
        case 107: return "Num +"
        case 109: return "Num -"
        case 110: return "Num ."
        case 111: return "Num /"
        case 112...135: return "F\(vk - 111)"
        case 160: return "Left Shift"
        case 161: return "Right Shift"
        case 162: return "Left Ctrl"
        case 163: return "Right Ctrl"
        case 164: return "Left Alt"
        case 165: return "Right Alt"
        case 186: return ";"
        case 187: return "="
        case 188: return ","
        case 189: return "-"
        case 190: return "."
        case 191: return "/"
        case 192: return "`"
        case 219: return "["
        case 220: return "\\"
        case 221: return "]"
        case 222: return "'"
        default: return "Key \(vk)"
        }
    }
    static func name(_ keys: [Int]) -> String { keys.map { name($0) }.joined(separator: " + ") }
    /// What a binding does, for the keys list: its comment ("Enter Menu"), else its setting's name made readable
    /// ("open_key" -> "Open key", "CloneProtectionHotkey" -> "Clone Protection Hotkey").
    static func title(_ binding: Binding) -> String {
        if !binding.reason.isEmpty { return binding.reason }
        var words = "", previous: Character = " "
        for c in binding.setting {
            if c == "_" { words.append(" ") } else {
                if c.isUppercase, previous.isLowercase { words.append(" ") }
                words.append(c)
            }
            previous = c
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Keys a player can choose to answer a mod key with (GTA-181): letters, digits, F-keys, the number pad, arrows.
    static let choosable: [Int] = Array(65...90) + Array(48...57) + Array(112...123) + Array(96...105) + [37, 38, 39, 40, 13, 32, 8, 45, 46, 36, 35, 33, 34]

    /// The keys of the mod in this folder: its .ini settings first, then the constants in its .asi code.
    static func scan(folder: URL) -> Scan {
        var scan = Scan(), code = Set<Int>()
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return scan }
        var inis: [URL] = []
        for case let url as URL in walk {
            if walk.level > 4 { walk.skipDescendants(); continue }
            switch url.pathExtension.lowercased() {
            case "ini": inis.append(url)
            case "asi":
                if walk.level == 1 { scan.scripts.append(url.lastPathComponent) }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let found = codeKeys(data)
                code.formUnion(found.keys); scan.everyKey = scan.everyKey || found.everyKey
            default: break
            }
        }
        for ini in inis.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = (try? String(contentsOf: ini, encoding: .utf8)) ?? (try? String(contentsOf: ini, encoding: .isoLatin1)) else { continue }
            scan.bindings += iniBindings(text, file: ini.lastPathComponent)
        }
        // Mods copy their settings at first start (Simple Trainer: AppData/TrainerV/Legacy and Enhanced): one row each.
        var listed = Set<String>()
        scan.bindings = scan.bindings.filter { listed.insert($0.setting + "=" + $0.keys.map(String.init).joined(separator: "+")).inserted }
        let named = Set(scan.bindings.flatMap(\.keys))
        // Mouse buttons (1-6) aren't keys.
        for vk in code.sorted() where vk > 6 && !named.contains(vk) { scan.bindings.append(Binding(keys: [vk], source: .code, setting: "", reason: "", file: "")) }
        return scan
    }

    /// Settings like "MenuKey=114 //Enter Menu, Default F3" or "open_key = 119" with "; Default key is F8 (119)" on
    /// the line before. Numbered settings with the same reason are keys held together: "EPMKey1=74 //EPM Down Default J"
    /// and "EPMKey2=97 //EPM Down Default Num 1" are J + Num 1. Controller buttons (the game's control numbers, 180 and
    /// up in settings named button, controller or pad) are left out, as in Harness/mod_keys.py.
    static func iniBindings(_ text: String, file: String) -> [Binding] {
        var bindings: [Binding] = []
        var lastComment = "", lastStem = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)  // Windows line ends (\r\n) too
            if line.hasPrefix(";") || line.hasPrefix("//") || line.hasPrefix("#") {
                lastComment = line.trimmingCharacters(in: CharacterSet(charactersIn: ";/# ")); continue
            }
            let previousComment = lastComment; lastComment = ""
            guard let eq = line.firstIndex(of: "=") else { lastStem = ""; continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]), comment = ""
            for marker in ["//", ";"] {
                guard let at = value.range(of: marker) else { continue }
                comment = String(value[at.upperBound...]).trimmingCharacters(in: .whitespaces); value = String(value[..<at.lowerBound]); break
            }
            let lower = name.lowercased()
            guard name.first.map({ $0.isLetter || $0 == "_" }) == true, ["key", "button", "hotkey", "bind"].contains(where: lower.contains),
                  let vk = Int(value.trimmingCharacters(in: .whitespaces)) else { lastStem = ""; continue }
            if ["button", "controller", "pad"].contains(where: lower.contains), vk >= 180 { lastStem = ""; continue }
            guard vk > 6, vk < 256 else { lastStem = ""; continue }
            let reason = cleanReason(comment.isEmpty ? previousComment : comment)
            let stem = String(name.reversed().drop(while: \.isNumber).reversed())
            if stem != name, stem == lastStem, let last = bindings.last, last.reason == reason, last.file == file, last.keys.count < 3 {
                bindings[bindings.count - 1] = Binding(keys: last.keys + [vk], source: .settings, setting: last.setting, reason: reason, file: file)
            } else {
                bindings.append(Binding(keys: [vk], source: .settings, setting: stem != name ? stem : name, reason: reason, file: file))
            }
            // Only the second key of a pair joins the first: "EPMKey3" starts the next pair (EPM Up).
            lastStem = stem != name && (bindings.last?.keys.count ?? 0) < 2 ? stem : ""
        }
        return bindings
    }

    /// "Enter Menu, Default F3" -> "Enter Menu"; "Default key is F8 (119). Key codes can be found here: http…" -> "".
    static func cleanReason(_ comment: String) -> String {
        var text = comment
        if let link = text.range(of: "http") { text = String(text[..<link.lowerBound]) }
        for cut in ["Key codes", "Button codes", "Default", "default"] { if let at = text.range(of: cut) { text = String(text[..<at.lowerBound]) } }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .:-,;(").union(.whitespaces))
    }

    /// Key codes passed as constants to the keyboard functions a Windows x64 .asi imports (GetAsyncKeyState,
    /// GetKeyState): `mov ecx, VK` shortly before a call through the import, or before a call to a small helper that
    /// itself calls one (IsKeyPressed(vk) style). Every read is bounds-checked: a damaged file gives no keys.
    static func codeKeys(_ data: Data) -> (keys: Set<Int>, everyKey: Bool) {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 : nil }
        func i32(_ o: Int) -> Int? { u32(o).map { Int(Int32(truncatingIfNeeded: $0)) } }
        func u64(_ o: Int) -> UInt64? { guard let lo = u32(o), let hi = u32(o + 4) else { return nil }; return UInt64(lo) | UInt64(hi) << 32 }
        guard bytes.count > 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A, let pe = u32(0x3C), pe + 24 + 128 < bytes.count,
              bytes[pe] == 0x50, bytes[pe + 1] == 0x45, let count = u16(pe + 6), let optSize = u16(pe + 20), u16(pe + 24) == 0x20B,
              let importRVA = u32(pe + 24 + 112 + 8) else { return ([], false) }
        struct Section { let va, size, raw, rawSize: Int; let code: Bool }
        var sections: [Section] = []
        for i in 0..<min(count, 96) {
            let o = pe + 24 + optSize + i * 40
            guard o + 40 <= bytes.count, let vsize = u32(o + 8), let va = u32(o + 12), let rsize = u32(o + 16), let raw = u32(o + 20) else { break }
            let name = String(decoding: bytes[o..<o + 8].prefix { $0 != 0 }, as: UTF8.self)
            sections.append(Section(va: va, size: max(vsize, rsize), raw: raw, rawSize: max(0, min(rsize, bytes.count - raw)), code: [".text", "text", ".code"].contains(name)))
        }
        func offset(_ rva: Int) -> Int? { sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { $0.raw + rva - $0.va } }
        func cstring(_ rva: Int) -> String? {
            guard let o = offset(rva), o < bytes.count else { return nil }
            return String(decoding: bytes[o..<min(bytes.count, o + 128)].prefix { $0 != 0 }, as: UTF8.self)
        }
        // The import table: the IAT slots of the keyboard functions.
        let wanted: Set<String> = ["GetAsyncKeyState", "GetKeyState", "GetKeyboardState", "keyboardHandlerRegister", "IsKeyPressed", "IsKeyJustUp"]
        var slots = Set<Int>(), everyKey = false
        var descriptor = importRVA != 0 ? offset(importRVA) : nil
        for _ in 0..<256 {
            guard let d = descriptor, let ilt = u32(d), let nameRVA = u32(d + 12), let iat = u32(d + 16), nameRVA != 0 else { break }
            for k in 0..<8192 {
                guard let at = offset((ilt != 0 ? ilt : iat) + k * 8), let entry = u64(at), entry != 0 else { break }
                guard entry >> 63 == 0, let fn = cstring(Int(entry & 0x7fffffff) + 2), wanted.contains(fn) else { continue }
                slots.insert(iat + k * 8)
                if fn == "keyboardHandlerRegister" { everyKey = true }
            }
            descriptor = d + 20
        }
        guard !slots.isEmpty else { return ([], everyKey) }
        // Calls through those slots (FF 15 disp32), and the short helpers around them (start found by walking back to
        // the padding or return before the function).
        var helpers = Set<Int>()
        for s in sections where s.code && s.rawSize >= 6 {
            for i in 0...(s.rawSize - 6) {
                let o = s.raw + i
                guard bytes[o] == 0xFF, bytes[o + 1] == 0x15, let disp = i32(o + 2), slots.contains(s.va + i + 6 + disp) else { continue }
                var start = i
                while start > 0, i - start < 64, bytes[s.raw + start - 1] != 0xCC, bytes[s.raw + start - 1] != 0xC3 { start -= 1 }
                helpers.insert(s.va + start)
            }
        }
        var found = Set<Int>()
        for s in sections where s.code && s.rawSize >= 5 {
            for i in 0...(s.rawSize - 5) {
                let o = s.raw + i
                // mov ecx, imm32 with a value that fits a key code
                guard bytes[o] == 0xB9, bytes[o + 2] == 0, bytes[o + 3] == 0, bytes[o + 4] == 0, (1...254).contains(Int(bytes[o + 1])) else { continue }
                let after = i + 5
                for j in 0..<11 where after + j + 6 <= s.rawSize {
                    let p = s.raw + after + j
                    if bytes[p] == 0xFF, bytes[p + 1] == 0x15, let disp = i32(p + 2), slots.contains(s.va + after + j + 6 + disp) { found.insert(Int(bytes[o + 1])); break }
                    if bytes[p] == 0xE8, let rel = i32(p + 1), helpers.contains(s.va + after + j + 5 + rel) { found.insert(Int(bytes[o + 1])); break }
                }
            }
        }
        return (found, everyKey)
    }

    /// The .asi files of an installed mod (its top level), as the engine names them.
    static func scripts(of mod: ModInstaller.Installed) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: mod.url.path)) ?? []).filter { $0.lowercased().hasSuffix(".asi") }
    }
}

/// On-screen buttons for mod keys (GTA-180): each holds its keys down for the script mods while touched. They show
/// while script mods run: always, in any vehicle, or only in one vehicle model; the layout editor moves them like
/// the rest.
struct ModButton: Codable, Equatable {
    enum Show: String, Codable { case always, vehicle, model }
    var mod: String
    var keys: [Int]
    /// An SF Symbol name, or "" for the key's own name on the button.
    var symbol: String
    var label: String
    var show: Show
    var model: UInt32 = 0
    var modelName: String = ""

    var id: String { mod + "|" + keys.map(String.init).joined(separator: "+") }
    var icon: String { symbol.isEmpty ? "text:" + ModKeys.name(keys.last ?? 0) : "sf:" + symbol }

    static let changed = Notification.Name("modButtonsChanged")
    private static let storeKey = "modButtons"
    static var all: [ModButton] {
        get { UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([ModButton].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storeKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static func button(mod: String, keys: [Int]) -> ModButton? { all.first { $0.mod == mod && $0.keys == keys } }
    static func save(_ button: ModButton) {
        var list = all
        if let at = list.firstIndex(where: { $0.id == button.id }) { list[at] = button } else { list.append(button) }
        all = list
    }
    static func remove(_ button: ModButton) { all.removeAll { $0.id == button.id } }
    /// A small icon library for mod buttons: what PC mods' keys usually do.
    static let symbols: [String] = ["", "list.bullet", "car.side", "headlight.high.beam", "arrow.left.arrow.right", "rectangle.portrait.and.arrow.right",
                                    "arrow.up.and.down.square", "light.beacon.max", "bolt", "wrench", "camera", "person", "star"]
}

/// Keys that answer a mod's own key (GTA-181), by mod (its folder name): a mod checks F3, and Q presses it. The engine
/// applies them per .asi (PGAsiSetKeyRemap), so the Mod keys tray, on-screen buttons and keyboards all go through them.
enum ModKeyRemap {
    private static let storeKey = "modKeyRemaps"
    /// Mod name -> (the mod's key -> the key that answers it).
    static var all: [String: [Int: Int]] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [String: Int]] ?? [:]
            return raw.mapValues { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in Int(k).map { ($0, v) } }) }
        }
        set {
            UserDefaults.standard.set(newValue.filter { !$0.value.isEmpty }.mapValues { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) }, forKey: storeKey)
            apply()
        }
    }
    static func key(mod: String, modKey: Int) -> Int? { all[mod]?[modKey] }
    static func set(mod: String, modKey: Int, key: Int?) {
        var list = all
        list[mod, default: [:]][modKey] = key == modKey ? nil : key
        all = list
    }
    /// What the mod sees as its key `modKey` comes from this key: the one an on-screen button has to press.
    static func pressed(mod: String, modKey: Int) -> Int { key(mod: mod, modKey: modKey) ?? modKey }
    /// Hands the remaps to the engine, by .asi file name (at launch and after every change).
    static func apply() {
        PGAsiClearKeyRemaps()
        let remaps = all
        guard !remaps.isEmpty else { return }
        for mod in ModInstaller.installed() {
            guard let keys = remaps[mod.name] else { continue }
            for script in ModKeys.scripts(of: mod) { for (modKey, key) in keys { PGAsiSetKeyRemap(script, Int32(modKey), Int32(key)) } }
        }
    }
}
