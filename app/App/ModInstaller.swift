import Foundation

/// Installs a downloaded PC mod (GTA-69): unpacks it (zip, rar), works out where each file belongs and
/// copies it into Mods/<mod name>/ at its game path, where the mod loader (Source/NativeAssets.m) finds
/// it. Most mods follow a few layouts:
///  - OpenIV packages (.oiv, or a folder with assembly.xml): kept as they are; the loader installs them.
///  - Script Hook V scripts (.asi): the script and its settings at the mod's top level.
///  - Files already in the game's layout (x64e.rpf/..., update/..., common.rpf/...): kept from there.
///  - Add-on packs (dlc.rpf): update/x64/dlcpacks/<pack>/dlc.rpf.
///  - Loose game files (oracle.yft, handling.meta...): the game itself knows where every file lives.
///    The engine writes that index while the game runs (game-file-index.txt), so a loose file goes
///    to the one place the game keeps it.
/// One folder per mod makes mods easy to list, switch off (".off") and remove.
enum ModInstaller {
    struct Item { let source: URL; let target: String; let note: String }
    struct Plan {
        var name: String
        var items: [Item] = []
        var skipped: [(file: String, reason: String)] = []
        var kinds = Set<String>()
        /// Something was left out because it can't work on iPhone (Windows .NET, another game version).
        var unsupported = false
        mutating func leaveOut(_ file: String, unsupported reason: String) { skipped.append((file, reason)); unsupported = true }
    }
    struct Installed { let name: String; let enabled: Bool; let files: Int; let url: URL; let waiting: Int }

    static var modsFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Mods") }
    static var indexFile: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("game-file-index.txt") }
    static var hasGameIndex: Bool { FileManager.default.fileExists(atPath: indexFile.path) }

    // MARK: Unpacking

    /// A temporary folder with the mod's files: an archive is unpacked, anything else copied as is.
    static func unpack(_ file: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mod-install-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let ext = file.pathExtension.lowercased()
        if ["zip", "rar", "tar", "gz"].contains(ext) {
            try extract(file, into: work)
        } else if ext == "7z" {
            throw InstallError(.unsupported, AppLanguage.choose("7z archives can't be opened here yet. Unpack it on a computer or with an app, then install the files."))
        } else {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: file.path, isDirectory: &isDir)
            try fm.copyItem(at: file, to: work.appendingPathComponent(file.lastPathComponent))
        }
        return work
    }

    private final class Reader { let handle: FileHandle; var block = Data(); init(_ h: FileHandle) { handle = h } }
    private static func extract(_ archive: URL, into folder: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { throw InstallError(.sourceUnreadable, AppLanguage.choose("The file can't be opened.")) }
        defer { try? handle.close() }
        let box = Reader(handle)
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let reader = gi_reader_open({ context, buffer in
            let box = Unmanaged<Reader>.fromOpaque(context!).takeUnretainedValue()
            box.block = (try? box.handle.read(upToCount: 1 << 20)) ?? Data()
            if box.block.isEmpty { return 0 }
            box.block.withUnsafeBytes { buffer!.pointee = $0.baseAddress }
            return box.block.count
        }, context) else { throw InstallError(.sourceUnreadable, AppLanguage.choose("The file can't be opened.")) }
        defer { gi_reader_close(reader) }
        var info = gi_entry_info()
        while true {
            let status = gi_reader_next(reader, &info)
            if status == GI_EOF { break }
            if status < 0 { throw InstallError(.corrupted, AppLanguage.choose("The archive is damaged or uses a format that isn't supported.")) }
            if info.encrypted != 0 { throw InstallError(.passwordProtected, AppLanguage.choose("The archive has a password; that isn't supported.")) }
            guard info.kind == GI_ENTRY_FILE, let raw = info.path else { _ = gi_reader_skip(reader); continue }
            // Archive paths use either slash; nothing may land outside the folder.
            let parts = String(cString: raw).replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { _ = gi_reader_skip(reader); continue }
            let target = parts.reduce(folder) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            guard let out = try? FileHandle(forWritingTo: target) else { _ = gi_reader_skip(reader); continue }
            var data: UnsafeRawPointer?; var size = 0; var offset: Int64 = 0
            while true {
                let r = gi_reader_data(reader, &data, &size, &offset)
                if r == GI_EOF { break }
                if r < 0 { try? out.close(); throw InstallError(.corrupted, AppLanguage.choose("The archive is damaged or uses a format that isn't supported.")) }
                if let data, size > 0 { try out.seek(toOffset: UInt64(offset)); out.write(Data(bytes: data, count: size)) }
            }
            try? out.close()
        }
    }

    // MARK: Where files go

    /// Every game file the engine has seen inside its archives, plus the loose files of the game's file
    /// list: lower-cased file name -> full game paths ("x64/levels/gta5/vehicles.rpf/oracle.yft").
    /// Paths inside DLC packs start with "@" (the loader can't change those yet).
    struct GameIndex {
        var byName: [String: [String]] = [:]
        static func load(manifest: String?) -> GameIndex {
            var index = GameIndex()
            if let text = try? String(contentsOf: ModInstaller.indexFile, encoding: .utf8) {
                for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                    let path = String(line)
                    let name = (path as NSString).lastPathComponent.lowercased()
                    // The engine opens some archives under two names; each path is kept once.
                    if !(index.byName[name]?.contains(path) ?? false) { index.byName[name, default: []].append(path) }
                }
            }
            if let manifest, let data = FileManager.default.contents(atPath: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let files = json["files"] as? [[Any]] {
                for file in files {
                    guard let path = file.first as? String, !path.lowercased().hasSuffix(".rpf") else { continue }
                    index.byName[(path as NSString).lastPathComponent.lowercased(), default: []].append(path)
                }
            }
            return index
        }
    }

    private static let waitingTypes: Set<String> = ["yft", "ytd", "ydd", "ydr", "ymt", "ybn", "ycd"]
    private static let junkNames: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]
    private static let documentExtensions: Set<String> = ["txt", "md", "pdf", "doc", "docx", "rtf", "url", "html", "htm", "jpg", "jpeg", "png", "gif", "webp", "bmp", "mp4", "mov", "lnk", "exe", "bat"]
    private static let gameExtensions: Set<String> = ["yft", "ytd", "ydd", "ydr", "ymt", "ybn", "ycd", "ypt", "ymap", "ytyp", "ynv", "ynd", "awc", "rel", "meta", "xml", "dat", "gxt2", "ymf", "ypdb", "rpf"]
    /// PC files that only raise the PC game's limits or list DLC packs; the port manages those itself, and an
    /// old copy (some mods ship one) would break the game.
    private static let pcOnlyFiles: Set<String> = ["gameconfig.xml", "dlclist.xml", "extratitleupdatedata.meta", "heapsizes.xml"]
    private static let loaderFiles: Set<String> = ["scripthookv.dll", "dinput8.dll", "dsound.dll", "version.dll", "openiv.asi"]
    /// What a mod needs that can't run on iPhone (docs/MODS.md, "Mods that can't work on iPhone").
    private static func unsupportedReason(_ rel: String) -> String? {
        let lower = rel.lowercased(), name = (lower as NSString).lastPathComponent, ext = (name as NSString).pathExtension
        if name.hasPrefix("scripthookvdotnet") || ["cs", "vb"].contains(ext) { return AppLanguage.choose("C# script (ScriptHookVDotNet): not supported") }
        if name.hasPrefix("rageplugin") || name == "lspdfr.dll" || (ext == "dll" && lower.split(separator: "/").contains("plugins")) {
            return AppLanguage.choose("RAGE Plugin Hook plugin (like LSPDFR): not supported")
        }
        if ext == "dll" { return AppLanguage.choose("C# script (ScriptHookVDotNet): not supported") }
        return nil
    }
    /// A model, texture or add-on pack made for GTA V Enhanced (the 2025 PC edition): the game here stops on it.
    private static func versionReason(_ url: URL) -> String? {
        guard ["yft", "ytd", "ydd", "ydr", "rpf"].contains(url.pathExtension.lowercased()) else { return nil }
        var why = [CChar](repeating: 0, count: 200)
        guard PGModFileProblem(url.path, &why, why.count) else { return nil }
        let text = String(cString: why)
        if text.contains("without encryption") { return AppLanguage.choose("an archive saved without encryption, which the game can't read; re-save it with OpenIV") }
        return text.contains("Enhanced")
            ? AppLanguage.choose("made for GTA V Enhanced; use the mod's Legacy (original PC) version")
            : AppLanguage.choose("made for another version of the game")
    }

    /// Decides where each file of an unpacked mod goes.
    static func plan(folder: URL, name: String, index: GameIndex) -> Plan {
        var plan = Plan(name: cleanName(name))
        let fm = FileManager.default
        var files: [(url: URL, rel: String)] = []
        let base = folder.standardizedFileURL.path
        if let walk = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walk {
                let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                if rel.lowercased().hasPrefix("__macosx") { walk.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append((url, rel)) }
            }
        }
        let readmes = files.filter { ["txt", "md"].contains($0.url.pathExtension.lowercased()) }
            .compactMap { try? String(contentsOf: $0.url, encoding: .utf8) ?? String(contentsOf: $0.url, encoding: .isoLatin1) }
            .joined(separator: "\n").lowercased().replacingOccurrences(of: "\\", with: "/")
        var done = Set<String>()

        // OpenIV packages: kept whole; the loader installs them as OpenIV would.
        for file in files where file.url.pathExtension.lowercased() == "oiv" {
            plan.items.append(Item(source: file.url, target: file.url.lastPathComponent, note: AppLanguage.choose("OpenIV package")))
            plan.kinds.insert("oiv"); done.insert(file.rel)
        }
        for file in files where file.url.lastPathComponent.lowercased() == "assembly.xml" {
            let package = (file.rel as NSString).deletingLastPathComponent
            let packageName = package.isEmpty ? plan.name : (package as NSString).lastPathComponent
            for other in files where !done.contains(other.rel) && (package.isEmpty || other.rel.hasPrefix(package + "/")) {
                let inner = package.isEmpty ? other.rel : String(other.rel.dropFirst(package.count + 1))
                plan.items.append(Item(source: other.url, target: packageName + "/" + inner, note: AppLanguage.choose("OpenIV package")))
                done.insert(other.rel)
            }
            plan.kinds.insert("oiv")
        }
        // Script Hook V scripts: the .asi with its settings next to it, at the mod's top level.
        for file in files where file.url.pathExtension.lowercased() == "asi" && !done.contains(file.rel) {
            let lower = file.url.lastPathComponent.lowercased()
            if let reason = unsupportedReason(file.rel) { plan.leaveOut(file.rel, unsupported: reason); done.insert(file.rel); continue }
            if loaderFiles.contains(lower) { plan.skipped.append((file.rel, AppLanguage.choose("not needed on iPhone"))); done.insert(file.rel); continue }
            let dir = (file.rel as NSString).deletingLastPathComponent
            let assetTypes: Set<String> = ["yft", "ytd", "ydd", "ydr", "ymt", "rpf", "oiv"]
            for other in files where !done.contains(other.rel) {
                let otherDir = (other.rel as NSString).deletingLastPathComponent
                let inner = dir.isEmpty ? other.rel : (other.rel.hasPrefix(dir + "/") ? String(other.rel.dropFirst(dir.count + 1)) : "")
                if inner.isEmpty { continue }
                let ext = other.url.pathExtension.lowercased()
                if otherDir == dir {
                    // Beside the script: the script and its settings.
                    guard other.rel == file.rel || ["ini", "xml", "json", "cfg", "toml", "log"].contains(ext) else { continue }
                } else {
                    // A folder of its own (Menyoo's menyooStuff), unless it holds game assets or a game path.
                    let top = String(inner.split(separator: "/").first ?? "")
                    let prefix = (dir.isEmpty ? "" : dir + "/") + top + "/"
                    if gameAnchor(inner) != nil || files.contains(where: { $0.rel.hasPrefix(prefix) && assetTypes.contains($0.url.pathExtension.lowercased()) }) { continue }
                    // Everything in it is the script's data (Menyoo reads PedAnimList.txt from there), except Windows programs.
                    if ["dll", "exe"].contains(ext) { continue }
                }
                plan.items.append(Item(source: other.url, target: inner, note: other.rel == file.rel ? AppLanguage.choose("script") : AppLanguage.choose("script settings")))
                done.insert(other.rel)
            }
            plan.kinds.insert("asi")
        }
        for file in files where !done.contains(file.rel) {
            let lower = file.url.lastPathComponent.lowercased(), ext = file.url.pathExtension.lowercased()
            if junkNames.contains(lower) || documentExtensions.contains(ext) { continue }
            if loaderFiles.contains(lower) || pcOnlyFiles.contains(lower) { plan.skipped.append((file.rel, AppLanguage.choose("not needed on iPhone"))); continue }
            // The mod also has an OpenIV package: that is the install; loose copies are the manual way.
            if plan.kinds.contains("oiv") && gameExtensions.contains(ext) { plan.skipped.append((file.rel, AppLanguage.choose("installed by the mod's OpenIV package"))); continue }
            if let reason = unsupportedReason(file.rel) { plan.leaveOut(file.rel, unsupported: reason); continue }
            if let reason = versionReason(file.url) { plan.leaveOut(file.rel, unsupported: reason); continue }
            // Already laid out like the game (x64e.rpf/..., update/x64/dlcpacks/..., common.rpf/...).
            if let path = gameAnchor(file.rel) {
                plan.items.append(Item(source: file.url, target: path, note: AppLanguage.choose("game path from the mod")))
                if lower == "dlc.rpf" { plan.kinds.insert("addon") } else { plan.kinds.insert("replace") }
                continue
            }
            // An add-on pack on its own: its folder names the pack.
            if lower == "dlc.rpf" {
                let parent = ((file.rel as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let generic: Set<String> = ["", "dlc", "dlcpacks", "files", "addon", "add-on", "install", "mod", "mods", "x64", "update"]
                let pack = cleanPackName(generic.contains(parent.lowercased()) ? plan.name : parent)
                plan.items.append(Item(source: file.url, target: "update/x64/dlcpacks/\(pack)/dlc.rpf", note: AppLanguage.interpolate(AppLanguage.choose("add-on pack \"{arg0}\""), [pack])))
                plan.kinds.insert("addon"); continue
            }
            guard gameExtensions.contains(ext) else { plan.skipped.append((file.rel, AppLanguage.choose("not a game file"))); continue }
            // A loose game file: the one place the game keeps a file of that name.
            let all = index.byName[lower] ?? []
            let usable = all.filter { !$0.hasPrefix("@") }
            // Before the game has run once there is no index yet: model and texture files wait in the mod's
            // .pending folder and are placed the next time the game starts (placeWaitingFiles).
            if usable.isEmpty && !hasGameIndex && waitingTypes.contains(ext) {
                plan.items.append(Item(source: file.url, target: ".pending/" + file.url.lastPathComponent, note: AppLanguage.choose("placed when the game starts")))
                plan.kinds.insert("replace"); continue
            }
            if usable.isEmpty {
                let reason = !all.isEmpty ? AppLanguage.choose("it's inside a DLC pack; changing those isn't supported yet")
                    : !hasGameIndex ? AppLanguage.choose("unknown until the game has run once; start the game, then install again")
                    : (lower.contains("+hi") || lower.contains("_hi.")) ? AppLanguage.choose("this game version has no high-detail file for it (the normal one is used)")
                    : AppLanguage.choose("no file with this name in the game")
                plan.skipped.append((file.rel, reason)); continue
            }
            let best = usable.max { score($0, readmes) < score($1, readmes) }!
            // A settings file the game has in several places replaces one of them whole: only when the
            // readme names the place, otherwise a guess could break cars or the game.
            if usable.count > 1 && ["meta", "xml", "dat"].contains(ext) && score(best, readmes) < 10 {
                plan.skipped.append((file.rel, AppLanguage.interpolate(AppLanguage.choose("the game has {arg0} files with this name; put it in by hand (see the guide)"), [String(usable.count)]))); continue
            }
            plan.items.append(Item(source: file.url, target: best, note: usable.count > 1
                ? AppLanguage.interpolate(AppLanguage.choose("replaces the game's file (one of {arg0} with this name)"), [String(usable.count)])
                : AppLanguage.choose("replaces the game's file")))
            plan.kinds.insert("replace")
        }
        // A car or character whose model files can't go in: its settings files stay out too, or the
        // game would use settings meant for a model it doesn't have.
        let modelTypes: Set<String> = ["yft", "ytd", "ydd", "ydr", "ymt"]
        let placedModels = plan.items.contains { modelTypes.contains(($0.target as NSString).pathExtension.lowercased()) }
        let skippedModels = plan.skipped.contains { modelTypes.contains(($0.file as NSString).pathExtension.lowercased()) }
        if skippedModels && !placedModels {
            let settings = plan.items.filter { ["meta", "xml", "dat"].contains(($0.target as NSString).pathExtension.lowercased()) && !$0.note.contains("OpenIV") }
            for item in settings { plan.skipped.append((item.source.lastPathComponent, AppLanguage.choose("its model files can't be installed, so its settings aren't either"))) }
            plan.items.removeAll { item in settings.contains { $0.source == item.source } }
        }
        return plan
    }

    /// The part of a path from the first folder that is a game location, in the PC layout the loader reads.
    static func gameAnchor(_ rel: String) -> String? {
        let parts = rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            let p = part.lowercased()
            let rest = parts[i...].joined(separator: "/")
            if p.range(of: #"^x64[a-z]?\.rpf$"#, options: .regularExpression) != nil || p == "common.rpf" { return rest }
            if p == "update", i + 1 < parts.count, ["update.rpf", "x64"].contains(parts[i + 1].lowercased()) { return rest }
            if p == "dlcpacks", i + 2 < parts.count { return "update/x64/" + parts[i...].joined(separator: "/") }
        }
        return nil
    }

    /// Prefers the place the readme names, then the base game over later updates.
    private static func score(_ path: String, _ readme: String) -> Int {
        let lower = path.lowercased()
        var s = 0
        for part in lower.split(separator: "/").dropLast() where part.count > 4 && readme.contains(part) { s += 10 }
        if lower.contains("patchday") || lower.contains("mpheist") { s -= 2 }
        if lower.hasPrefix("x64/levels/gta5/") || lower.hasPrefix("x64/models/cdimages/") || lower.hasPrefix("common/data/") { s += 3 }
        return s
    }

    /// "f7de06-policecoquette" (gta5-mods.com adds the hex prefix) -> "policecoquette".
    static func cleanName(_ raw: String) -> String {
        var name = (raw as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: #"^[0-9a-f]{6}-"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || ["x64", "common", "update", "mods"].contains(name.lowercased()) { name = "Mod " + name }
        return String(name.prefix(60))
    }
    private static func cleanPackName(_ raw: String) -> String {
        let name = raw.lowercased().replacingOccurrences(of: #"[^a-z0-9_\-]"#, with: "", options: .regularExpression)
        return name.isEmpty ? "addon" : String(name.prefix(32))
    }

    /// Files installed before the game had run once wait in Mods/<mod>/.pending; with the game's file
    /// index there now, each goes where the game keeps a file of that name (when that is one place).
    static func placeWaitingFiles() {
        guard hasGameIndex else { return }
        let fm = FileManager.default
        var index: GameIndex? = nil
        for mod in (try? fm.contentsOfDirectory(at: modsFolder, includingPropertiesForKeys: nil)) ?? [] {
            let pending = mod.appendingPathComponent(".pending")
            guard let files = try? fm.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil), !files.isEmpty else { continue }
            if index == nil { index = .load(manifest: nil) }
            for file in files {
                let places = (index!.byName[file.lastPathComponent.lowercased()] ?? []).filter { !$0.hasPrefix("@") }
                guard let target = places.max(by: { score($0, "") < score($1, "") }) else { continue }
                let to = target.split(separator: "/").reduce(mod) { $0.appendingPathComponent(String($1)) }
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                if (try? fm.moveItem(at: file, to: to)) != nil { NSLog("Mods: placed %@ at %@", file.lastPathComponent, target) }
            }
            if ((try? fm.contentsOfDirectory(atPath: pending.path)) ?? []).isEmpty { try? fm.removeItem(at: pending) }
        }
    }

    // MARK: Installing and managing

    /// Copies the plan's files into Mods/<name>/ (replacing an older install of the same mod).
    @discardableResult
    static func install(_ plan: Plan) throws -> URL {
        let fm = FileManager.default
        let target = modsFolder.appendingPathComponent(plan.name)
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: modsFolder.appendingPathComponent(plan.name + ".off"))
        for item in plan.items {
            let to = item.target.split(separator: "/").reduce(target) { $0.appendingPathComponent(String($1)) }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: item.source, to: to)
        }
        return target
    }

    /// Archives somewhere in the Mods folder that the game would skip because they're still packed (GTA-167). An archive
    /// right in the Mods folder becomes its installed folder of the same name when installed; one in a subfolder whose
    /// name an installed mod already has isn't listed again.
    static func packedInModsFolder(besides installed: [Installed]) -> [URL] {
        let names = Set(installed.map { $0.name.lowercased() }), inside = installed.map { $0.url.standardizedFileURL.path + "/" }
        guard let walk = FileManager.default.enumerator(at: modsFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk {
            if walk.level > 4 { walk.skipDescendants(); continue }
            guard ["zip", "rar", "7z", "oiv"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            if names.contains(url.lastPathComponent.lowercased()) || inside.contains(where: { path.hasPrefix($0) }) { continue }
            found.append(url)
            if found.count >= 50 { break }
        }
        return found.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Mods installed one per folder (a folder ending in ".off" is switched off).
    static func installed() -> [Installed] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: modsFolder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { url -> Installed? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let enabled = !url.lastPathComponent.hasSuffix(".off")
            let name = enabled ? url.lastPathComponent : String(url.lastPathComponent.dropLast(4))
            // Folders that are game paths themselves (files put in by hand) aren't single mods.
            if gameAnchor(name + "/x") != nil || ["x64", "common", "update", "mods"].contains(name.lowercased()) { return nil }
            let waiting = ((try? fm.contentsOfDirectory(atPath: url.appendingPathComponent(".pending").path)) ?? []).count
            let count = ((fm.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?.allObjects.count) ?? 0)
            return Installed(name: name, enabled: enabled, files: count, url: url, waiting: waiting)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// The game is running (NativePortViewController): it reads mod files from their folders while it plays, so
    /// switching a mod off or removing it then is queued for the next start instead (a removed add-on pack
    /// stopped the game: "Game file missing from your folder", log 1119, GTA-140).
    static var gameRunning = false
    private static let pendingKey = "modsPendingChanges"
    /// Queued changes by mod name: "on", "off" or "remove".
    static var pending: [String: String] { UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: String] ?? [:] }
    private static func queue(_ name: String, _ change: String?) {
        var all = pending; all[name] = change
        UserDefaults.standard.set(all, forKey: pendingKey)
    }
    /// At launch, before the game reads the Mods folder: the changes made while it was running.
    static func applyPending() {
        let changes = pending
        guard !changes.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        for mod in installed() {
            switch changes[mod.name] {
            case "remove"?: try? remove(mod)
            case "on"?: try? setEnabled(mod, true)
            case "off"?: try? setEnabled(mod, false)
            default: break
            }
        }
    }
    static func setEnabled(_ mod: Installed, _ on: Bool) throws {
        if gameRunning { queue(mod.name, on == mod.enabled ? nil : (on ? "on" : "off")); return }
        let to = modsFolder.appendingPathComponent(on ? mod.name : mod.name + ".off")
        if to != mod.url { try FileManager.default.moveItem(at: mod.url, to: to) }
    }
    /// Folders copied in by hand (Files app, a computer) can hold read-only files or folders, which
    /// removeItem refuses (GTA-136): make everything writable, then remove again.
    static func remove(_ mod: Installed) throws {
        if gameRunning { queue(mod.name, "remove"); return }
        let fm = FileManager.default
        do { try fm.removeItem(at: mod.url); return } catch {
            if let items = fm.enumerator(at: mod.url, includingPropertiesForKeys: nil) {
                for case let url as URL in items { try? fm.setAttributes([.posixPermissions: 0o755, .immutable: false], ofItemAtPath: url.path) }
            }
            try? fm.setAttributes([.posixPermissions: 0o755, .immutable: false], ofItemAtPath: mod.url.path)
            try fm.removeItem(at: mod.url)
        }
    }
}

/// Mods across updates and crashes (GTA-153). Each update loads some mods the previous one skipped (add-on
/// engine sounds in v1.4.3, "dlc 2.rpf" in v1.4.4), so a Mods folder that ran clean can crash after an update.
///  - After an update, a mod that the previous version had switched on but didn't use stays off until the
///    player turns it on again in Settings › Mods.
///  - After the game stopped while starting with mods on, the next launch offers to start once without them.
enum ModGuard {
    private static var defaults: UserDefaults { .standard }
    /// The version the record belongs to. Simulator tests set PG_TEST_APP_VERSION to play an update.
    static var version: String {
        #if targetEnvironment(simulator)
        if let test = ProcessInfo.processInfo.environment["PG_TEST_APP_VERSION"], !test.isEmpty { return test }
        #endif
        return Theme.appVersion
    }
    /// Per mod folder name: "<version>|1" when that version used the mod, "<version>|0" when it had it on but didn't.
    private static var history: [String: String] {
        get { defaults.dictionary(forKey: "modGuardHistory") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "modGuardHistory") }
    }

    /// Once the game has run a while (scripts load once the player exists): which switched-on mods it used.
    static func recordUse(_ used: Set<String>) {
        guard !startsWithoutMods else { return }
        var all = history
        for mod in ModInstaller.installed() where mod.enabled && mod.waiting == 0 {
            all[mod.name] = version + (used.contains(mod.name) ? "|1" : "|0")
        }
        history = all
    }

    /// At launch: the first start of a new version switches off the mods the previous version had on but
    /// didn't use. Returns their names (for a one-time notice).
    static func afterUpdate() -> [String] {
        let previous = defaults.string(forKey: "modGuardVersion")
        guard previous != version else { return [] }
        defaults.set(version, forKey: "modGuardVersion")
        guard previous != nil else { return [] }
        var switchedOff: [String] = []
        for mod in ModInstaller.installed() where mod.enabled {
            guard let entry = history[mod.name], entry.hasSuffix("|0"), !entry.hasPrefix(version + "|") else { continue }
            if (try? ModInstaller.setEnabled(mod, false)) != nil { switchedOff.append(mod.name) }
        }
        return switchedOff
    }

    // MARK: Start without mods

    /// The current start reads no mods (chosen after a crash).
    private(set) static var startsWithoutMods = false
    /// "Start without mods" was chosen: the next Play starts once without them.
    static var withoutModsNextStart: Bool {
        get { defaults.bool(forKey: "modGuardWithoutMods") }
        set { defaults.set(newValue, forKey: "modGuardWithoutMods") }
    }
    /// Switched-on mods with something in them (what a start would load).
    static var anyModsOn: Bool {
        guard let walk = FileManager.default.enumerator(at: ModInstaller.modsFolder, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if name.hasSuffix(".off") || name == ".pending" { walk.skipDescendants(); continue }
            if name != "README.txt", !name.hasPrefix("."), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }
    /// At Play: whether this start loads mods, remembered until the game has run stably.
    static func starting() -> Bool {
        startsWithoutMods = withoutModsNextStart
        withoutModsNextStart = false
        defaults.set(!startsWithoutMods && anyModsOn, forKey: "modGuardBootWithMods")
        defaults.set(false, forKey: "modGuardStoppedWithMods")
        return startsWithoutMods
    }
    /// The game ran stably: it didn't stop while starting.
    static func startedStably() { defaults.set(false, forKey: "modGuardBootWithMods") }
    /// The game stopped (a trap, not iOS closing the app) before it ran stably.
    static func stoppedWhileStarting() {
        if defaults.bool(forKey: "modGuardBootWithMods") { defaults.set(true, forKey: "modGuardStoppedWithMods") }
    }
    /// At launch: the previous start had mods on and didn't finish (closed by iOS, or the game stopped).
    static func previousStartFailedWithMods(bootPending: Bool) -> Bool {
        let failed = defaults.bool(forKey: "modGuardStoppedWithMods") || (bootPending && defaults.bool(forKey: "modGuardBootWithMods"))
        defaults.set(false, forKey: "modGuardStoppedWithMods")
        defaults.set(false, forKey: "modGuardBootWithMods")
        return failed && anyModsOn
    }
}
