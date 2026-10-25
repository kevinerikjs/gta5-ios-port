import Foundation

/// Why the game stopped, from the lines the engine logged just before (GTA-178): the game's own "Fatal Error:" message,
/// or the engine functions of a trap ("Native trap functions: f79348 < f38724 < f79344"). The known causes come from
/// 938 player logs (v1.4.x): damaged files, memory, add-on cars and packs made for another game version, script mods.
/// The stop panel shows the cause and what to do instead of a bare "The game stopped".
struct StopCause: Equatable {
    enum Kind: String {
        case damagedFile, memory, carLayout, otherVersion, modFile, packIncomplete, poolFull, scriptMod
        case addonVehicle, addonSound, addonMap, addon
    }
    let kind: Kind
    /// The file the game named (a file name, or an add-on pack name for packIncomplete).
    var file: String = ""
    /// The add-on pack ("dlc_<pack>:/…") the file came from, when the message says.
    var pack: String = ""

    /// Causes that point at mods: the panel offers to switch the mod off, or to start without mods.
    var fromMods: Bool { ![.damagedFile, .memory].contains(kind) }

    /// The cause from this run's evidence lines, oldest first ("Fatal Error: …", "Native trap functions: …" and the
    /// last "Executing changeset … for <pack>"). addonsOn: add-on packs or script mods were on (trap causes that only
    /// appear with them need it).
    static func find(_ lines: [String], addonsOn: Bool) -> StopCause? {
        if let fatal = lines.first(where: { $0.hasPrefix("Fatal Error:") }), var cause = fromFatal(fatal) {
            // An unreadable file or one of another game version while a pack's startup changeset runs: that pack's (40 of
            // 64 disc errors and 55 of 74 version stops in player logs came right after an add-on pack's changeset).
            // Not for a core archive the game opens at start (GTA-194): that is the game's own file, never a pack's.
            if [.damagedFile, .otherVersion].contains(cause.kind), cause.pack.isEmpty, !fatal.contains("critical archive"),
               let changeset = lines.last(where: { $0.hasPrefix("Executing changeset ") }),
               let m = match(changeset, #"^Executing changeset \S+ in group \S+ for (\S+)"#) { cause.pack = m[1] }
            return cause
        }
        if let trap = lines.last(where: { $0.hasPrefix("Native trap functions:") }) { return fromTrap(trap, addonsOn: addonsOn) }
        return nil
    }

    private static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(text[Range(m.range(at: $0), in: text)!]) }
    }
    /// "platform:/levels/gta5/vehiclemods/zion_mods.rpf" -> "zion_mods.rpf"; "dlc_hellcat15:/x64/…" -> pack "hellcat15".
    private static func base(_ path: String) -> String { String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path)) }
    private static func pack(_ path: String) -> String {
        guard let m = match(path, #"^dlc_?([^:/]+):"#) else { return "" }
        return m[1].lowercased() == "patchday" || m[1].hasPrefix("mp") ? "" : m[1]
    }

    static func fromFatal(_ line: String) -> StopCause? {
        let text = String(line.dropFirst("Fatal Error:".count)).trimmingCharacters(in: .whitespaces)
        let source = match(text, #"\(from registered packfile ([^)]+)\)"#)?[1] ?? ""
        if text.contains("Allocation error") || text.contains("not enough memory") || match(text, #"Error allocating \d+ bytes"#) != nil
            || match(text, #"^Read request .* some of which are NULL"#) != nil {
            return StopCause(kind: .memory)
        }
        if text.hasPrefix("Fatal disc error") { return StopCause(kind: .damagedFile, file: source.isEmpty ? "" : base(source), pack: pack(source)) }
        if let m = match(text, #"Short read on (\S+)"#) { return StopCause(kind: .damagedFile, file: m[1]) }
        if let m = match(text, #"zlibInflater.* in file (\S+)"#) { return StopCause(kind: .damagedFile, file: base(m[1]), pack: pack(m[1])) }
        if let m = match(text, #"Resource '([^']+)' : Invalid fixup"#) { return StopCause(kind: .damagedFile, file: m[1]) }
        // GTA-194 (Scripts/prepare_trap_guards.py): a core audio archive missing or unreadable (15 stops in 15 logs), and a
        // resource whose memory chunks can't be recorded (24 stops in 19 logs). Both used to stop with no message.
        if let m = match(text, #"Unable to find critical archive '([^']+)'"#) { return StopCause(kind: .damagedFile, file: base(m[1]), pack: pack(m[1])) }
        if let m = match(text, #"Resource '([^']+)' : chunk \d+ of \d+ can't go in its page map"#) { return StopCause(kind: .damagedFile, file: base(m[1]), pack: pack(m[1])) }
        if let m = match(text, #"Code is expecting version (\d+) but file (\S+) has version (\d+)"#) {
            // Version 0: the file reads as zeros (damaged or cut short); another number: made for another game version.
            let file = base(m[2]), from = pack(source)
            return m[3] == "0" ? StopCause(kind: .damagedFile, file: file, pack: from) : StopCause(kind: .otherVersion, file: file, pack: from)
        }
        if text.hasPrefix("vehicle layouts contains bad entry points") { return StopCause(kind: .carLayout) }
        if let m = match(text, #"RPF file '([^']+)' is missing"#) { return StopCause(kind: .packIncomplete, file: pack(m[1]).isEmpty ? base(m[1]) : pack(m[1]), pack: pack(m[1])) }
        if let m = match(text, #"Map changesets should be versioned, Content: (\S+)"#) { return StopCause(kind: .otherVersion, file: m[1]) }
        if let m = match(text, #"^(\S+) Pool Full"#) { return StopCause(kind: m[1].contains("ScriptGuid") ? .scriptMod : .poolFull, file: m[1]) }
        if text.hasPrefix("Script fault") { return nil }
        if let m = match(text, #"^(\S+) - Unencrypted archives no longer supported"#) { return StopCause(kind: .modFile, file: base(m[1])) }
        if text.contains("gameconfig.xml") || text.contains("PauseMenu.XML") || match(text, #"from Loading (parTree from )?file '([^']+)'"#) != nil
            || match(text, #"^\w+\(\d+\): Expected (float|int)"#) != nil {
            // A data file a mod replaced (gameconfig.xml, a .meta, particle settings) that the game can't parse.
            let file = match(text, #"'([^']+\.(meta|xml|XML))'"#)?[1] ?? match(text, #"(\S+\.(meta|xml|XML))"#)?[1] ?? ""
            return StopCause(kind: .modFile, file: base(file))
        }
        return nil
    }

    /// Engine functions (Generated/funcnames.tsv) of the trap stops that player logs show only with add-ons on.
    static func fromTrap(_ line: String, addonsOn: Bool) -> StopCause? {
        let functions = Set(line.dropFirst("Native trap functions:".count).components(separatedBy: " < ").map { $0.trimmingCharacters(in: .whitespaces) })
        // fwPool<fwScriptGuid>::PoolFullCallback from a script mod's game command (23 stops, NativeTrainer and Menyoo).
        if functions.contains("f8694") { return functions.contains("pg_asi_native") || addonsOn ? StopCause(kind: .scriptMod) : nil }
        guard addonsOn else { return nil }
        // CHandlingDataMgr::Init > CModelInfo::UpdateVehicleClassInfos > CRotaryWingAircraft (41 stops in 30 logs, all with add-on packs).
        if !functions.isDisjoint(with: ["f79344", "f38724", "f79348"]) { return StopCause(kind: .addonVehicle) }
        // audMetadataDataFileMounter::LoadDataFile (27 stops in 22 logs, all with add-on packs). The trap is at the end of f6953
        // (GetObjectMetadataPtrFromSpecificChunk), named f6954 by its return address; since GTA-194 it no longer stops the game.
        if !functions.isDisjoint(with: ["f21159", "f6954", "f6955"]) { return StopCause(kind: .addonSound) }
        // CFileLoader::LoadObjectTypesXml (map types) and fwMapDataStore::PlaceResource (map data): 24 stops, add-on packs in 15 of 17 logs.
        if !functions.isDisjoint(with: ["f47003", "f47165", "f5591", "f2302"]) { return StopCause(kind: .addonMap) }
        // Collision with a model's bounds (14 logs; the trap is at the end of f15927 PrimitiveTriangle::Collide, named f15928 by
        // its return address, and since GTA-194 no longer stops the game) and registering a pack's files (f6050 from
        // CFileLoader::AddRpfFile, 4 logs): all with add-on packs.
        if !functions.isDisjoint(with: ["f15928", "f16240", "f6050", "f46995"]) { return StopCause(kind: .addon) }
        // CopyOffMatrixSet: the shared cache of animated models' bone matrices is full (GTA-194: 4 stops in 3 logs, 72-200
        // mod files each; the engine prints "Model Name …, bone count …" and "Total Memory use" first).
        if functions.contains("f44413") { return StopCause(kind: .poolFull) }
        return nil
    }

    // MARK: What the panel says

    var title: String {
        switch kind {
        case .damagedFile: return AppLanguage.choose("A game file couldn't be read")
        case .memory: return AppLanguage.choose("The game ran out of memory")
        case .carLayout, .addonVehicle: return AppLanguage.choose("A vehicle mod doesn't fit this game")
        case .otherVersion: return AppLanguage.choose("A mod is made for another version of the game")
        case .modFile: return AppLanguage.choose("A mod file can't be used")
        case .packIncomplete: return AppLanguage.choose("An add-on pack is incomplete")
        case .poolFull: return AppLanguage.choose("Too many add-ons")
        case .scriptMod: return AppLanguage.choose("A script mod filled the game's lists")
        case .addonSound: return AppLanguage.choose("A sound mod doesn't fit this game")
        case .addonMap: return AppLanguage.choose("A map mod doesn't fit this game")
        case .addon: return AppLanguage.choose("An add-on pack doesn't fit this game")
        }
    }

    /// What to do. mods: the installed mods that hold the file (or all suspects), by name.
    func message(mods: [String]) -> String {
        let named = mods.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        let oneByOne = AppLanguage.choose("Switch your add-on packs off in Settings › Mods, then back on one at a time to find it.")
        switch kind {
        case .damagedFile:
            if !mods.isEmpty {
                return file.isEmpty
                    ? AppLanguage.interpolate(AppLanguage.choose("The game couldn't read a file from the mod {arg0}. The mod may be damaged or made for another version of the game: install it again, or switch it off."), [named])
                    : AppLanguage.interpolate(AppLanguage.choose("The game couldn't read {arg0} from the mod {arg1}. The mod may be damaged or made for another version of the game: install it again, or switch it off."), [file, named])
            }
            return AppLanguage.interpolate(file.isEmpty
                ? AppLanguage.choose("The game couldn't read one of its files. It may be damaged or incomplete: check the game files in Settings › Game files, and keep a few GB of storage free.")
                : AppLanguage.choose("The game couldn't read {arg0}. It may be damaged or incomplete: check the game files in Settings › Game files, and keep a few GB of storage free."), [file])
        case .memory:
            return AppLanguage.choose("Close other apps and start the game again. If it keeps happening, choose a lower preset in Settings › Graphics and switch off big car or texture mods.")
        case .carLayout:
            return (mods.isEmpty ? "" : AppLanguage.interpolate(AppLanguage.choose("Mods with seat and door layouts: {arg0}."), [named]) + " ")
                + AppLanguage.choose("An add-on car's seat and door layout (vehiclelayouts.meta) doesn't match this version of the game.") + " " + oneByOne
        case .addonVehicle:
            return AppLanguage.choose("An add-on vehicle's handling or model data doesn't match this version of the game.") + " " + oneByOne
        case .otherVersion:
            if !mods.isEmpty {
                return AppLanguage.interpolate(AppLanguage.choose("{arg0} comes from the mod {arg1}, made for GTA V Enhanced or a newer update. This game can't load it: switch the mod off."), [file, named])
            }
            return file.isEmpty ? AppLanguage.choose("A file from one of your mods was made for GTA V Enhanced or a newer update, and this game can't load it. Switch off the mod that added it in Settings › Mods.")
                : AppLanguage.interpolate(AppLanguage.choose("{arg0} is from a mod made for GTA V Enhanced or a newer update, and this game can't load it. Switch off the mod that added it in Settings › Mods."), [file])
        case .modFile:
            return AppLanguage.interpolate(file.isEmpty
                ? AppLanguage.choose("A file from one of your mods can't be read by this game. Switch off the mod that added it in Settings › Mods.")
                : AppLanguage.choose("{arg0} from one of your mods can't be read by this game. Switch off the mod that added it in Settings › Mods."), [file])
        case .packIncomplete:
            return AppLanguage.interpolate(AppLanguage.choose("The add-on pack \"{arg0}\" needs a file it doesn't include. Install the mod again, or switch it off in Settings › Mods."), [file])
        case .poolFull:
            return AppLanguage.choose("The game ran out of room for what your add-on packs bring. Switch some off in Settings › Mods.")
        case .scriptMod:
            return AppLanguage.choose("A script mod (a trainer or menu) kept too many cars, people or objects in the world. Start the game again, and delete what you spawn once you're done with it.")
        case .addonSound:
            return AppLanguage.choose("An add-on pack's sounds (often car engine sounds) don't match this version of the game.") + " " + oneByOne
        case .addonMap:
            return AppLanguage.choose("An add-on map's data doesn't match this version of the game, or is damaged.") + " " + oneByOne
        case .addon:
            return AppLanguage.choose("One of your add-on packs has data this version of the game can't use.") + " " + oneByOne
        }
    }
}

/// Which installed mods hold a file the game named (GTA-178): loose files by name, add-on packs by name, and files
/// inside a mod's .rpf archives (their file tables, when not encrypted).
enum ModFiles {
    static func mods(for cause: StopCause) -> [ModInstaller.Installed] {
        let on = ModInstaller.installed().filter { $0.enabled }
        guard !on.isEmpty else { return [] }
        if !cause.pack.isEmpty, let mod = on.first(where: { holdsPack($0, cause.pack) }) { return [mod] }
        switch cause.kind {
        case .packIncomplete: return on.filter { holdsPack($0, cause.file) }
        case .carLayout: return on.filter { holds($0, prefix: "vehiclelayouts") }
        case .damagedFile, .otherVersion, .modFile:
            guard !cause.file.isEmpty else { return [] }
            return on.filter { holds($0, name: cause.file) }
        default: return []
        }
    }

    private static func holdsPack(_ mod: ModInstaller.Installed, _ pack: String) -> Bool {
        let wanted = pack.lowercased()
        guard let walk = FileManager.default.enumerator(at: mod.url, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walk where url.lastPathComponent.lowercased() == "dlc.rpf" {
            if url.deletingLastPathComponent().lastPathComponent.lowercased() == wanted { return true }
        }
        return false
    }
    /// A file of this name (or starting with this prefix, for vehiclelayouts*.meta) loose in the mod or in its archives.
    private static func holds(_ mod: ModInstaller.Installed, name: String = "", prefix: String = "") -> Bool {
        let name = name.lowercased(), prefix = prefix.lowercased()
        func fits(_ entry: String) -> Bool { let e = entry.lowercased(); return name.isEmpty ? e.hasPrefix(prefix) : e == name }
        guard let walk = FileManager.default.enumerator(at: mod.url, includingPropertiesForKeys: nil) else { return false }
        var archives: [URL] = []
        for case let url as URL in walk {
            if fits(url.lastPathComponent) { return true }
            if url.pathExtension.lowercased() == "rpf" { archives.append(url) }
        }
        for archive in archives.prefix(40) {
            guard let file = try? FileHandle(forReadingFrom: archive) else { continue }
            defer { try? file.close() }
            if rpfNames(file, at: 0, depth: 0).contains(where: fits) { return true }
        }
        return false
    }

    /// The entry names of an RPF7 archive at this offset, and of the archives inside it (two levels: dlc.rpf >
    /// x64/vehicles.rpf > car.yft). Encrypted tables (AES, NG) give none.
    static func rpfNames(_ file: FileHandle, at start: UInt64, depth: Int) -> [String] {
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? file.seek(toOffset: start + offset)) != nil, let data = try? file.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        func u32(_ d: Data, _ o: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        guard let header = read(0, 16), u32(header, 0) == 0x52504637 else { return [] }	// "RPF7"
        let count = Int(u32(header, 4)), namesLength = Int(u32(header, 8)), encryption = u32(header, 12)
        guard encryption == 0 || encryption == 0x4E45504F, count > 0, count < 200_000, namesLength < 16 << 20,	// "OPEN"
              let table = read(16, count * 16 + namesLength) else { return [] }
        var names: [String] = [], inner: [UInt64] = []
        for i in 0..<count {
            let o = i * 16
            let low = u32(table, o), high = u32(table, o + 4)
            let nameOffset = high == 0x7FFFFF00 ? Int(low) : Int(low & 0xFFFF)
            let at = count * 16 + nameOffset
            guard at < table.count else { continue }
            let name = String(decoding: table[at...].prefix { $0 != 0 }, as: UTF8.self)
            names.append(name)
            // A file (not a folder, not a resource) that is itself an archive: its table is at its offset (512-byte blocks).
            if high != 0x7FFFFF00, high & 0x80000000 == 0, name.lowercased().hasSuffix(".rpf") { inner.append(UInt64(high >> 8 & 0x7FFFFF) * 512) }
        }
        if depth < 2 { for offset in inner.prefix(32) { names += rpfNames(file, at: start + offset, depth: depth + 1) } }
        return names
    }
}
