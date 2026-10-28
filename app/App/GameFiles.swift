import Foundation

/// Finding the game's files anywhere the app can see, and checking them against the game's file list.
///
/// A game folder is recognised by its layout: a `data` folder (or a folder) that holds both `x64` and
/// `common`. Every file in the game's list (the app's bundled manifest) is then checked for presence
/// and exact size, so a problem can be reported by file name with the likely cause.
enum GameFiles {
    /// One game file the check found wrong.
    struct Problem {
        enum Kind { case missing, wrongSize(actual: UInt64), inICloud }
        let path: String
        let expected: UInt64
        let kind: Kind
    }

    /// The result of checking a game folder.
    struct Report {
        let data: URL
        let fileCount: Int
        let totalBytes: UInt64
        let problems: [Problem]
        var isComplete: Bool { problems.isEmpty }

        var missing: [Problem] { problems.filter { if case .missing = $0.kind { return true }; return false } }
        var wrongSize: [Problem] { problems.filter { if case .wrongSize = $0.kind { return true }; return false } }
        var inICloud: [Problem] { problems.filter { if case .inICloud = $0.kind { return true }; return false } }

        /// A short title and an explanation of what is wrong and what to do (shown to the player, so translated).
        var explanation: (title: String, message: String) {
            if isComplete { return (AppLanguage.choose("Game files OK"), AppLanguage.interpolate(AppLanguage.choose("All {arg0} game files are there and complete."), [String(fileCount)])) }
            var parts: [String] = []
            if !inICloud.isEmpty {
                parts.append(inICloud.count == 1
                    ? AppLanguage.interpolate(AppLanguage.choose("1 file is only in iCloud, not on this iPhone (for example {arg0}). The game can't read them from there: move the game folder to Files › On My iPhone › GTA V Port."), [inICloud[0].path])
                    : AppLanguage.interpolate(AppLanguage.choose("{arg0} files are only in iCloud, not on this iPhone (for example {arg1}). The game can't read them from there: move the game folder to Files › On My iPhone › GTA V Port."), [String(inICloud.count), inICloud[0].path]))
            }
            if !missing.isEmpty {
                let bytes = missing.reduce(0) { $0 + $1.expected }
                var text = missing.count == 1
                    ? AppLanguage.interpolate(AppLanguage.choose("1 file is missing ({arg0} in all), for example {arg1}."), [Self.size(bytes), Self.examples(missing)])
                    : AppLanguage.interpolate(AppLanguage.choose("{arg0} files are missing ({arg1} in all), for example {arg2}."), [String(missing.count), Self.size(bytes), Self.examples(missing)])
                if missing.count == fileCount {
                    text = AppLanguage.choose("This folder has none of the game's files.")
                } else {
                    text += AppLanguage.choose(" Unpacking or copying probably stopped before the end, most often because the iPhone ran out of storage. Free up space, delete this folder and unpack the game again.")
                }
                parts.append(text)
            }
            if !wrongSize.isEmpty {
                let first = wrongSize[0]
                var actual: UInt64 = 0
                if case let .wrongSize(size) = first.kind { actual = size }
                parts.append(wrongSize.count == 1
                    ? AppLanguage.interpolate(AppLanguage.choose("1 file has the wrong size, for example {arg0} ({arg1} instead of {arg2}). These files are damaged, usually by an interrupted download or unpack, or come from a different version of the game. Delete the folder and unpack the game again."), [first.path, Self.size(actual), Self.size(first.expected)])
                    : AppLanguage.interpolate(AppLanguage.choose("{arg0} files have the wrong size, for example {arg1} ({arg2} instead of {arg3}). These files are damaged, usually by an interrupted download or unpack, or come from a different version of the game. Delete the folder and unpack the game again."), [String(wrongSize.count), first.path, Self.size(actual), Self.size(first.expected)]))
            }
            let title = !inICloud.isEmpty ? AppLanguage.choose("Game files are in iCloud") : !wrongSize.isEmpty ? AppLanguage.choose("Some game files are damaged") : AppLanguage.choose("Some game files are missing")
            return (title, parts.joined(separator: "\n\n"))
        }

        /// Every problem, one per line, for the log or for sharing.
        var details: String {
            problems.map { problem in
                switch problem.kind {
                case .missing: return "missing: \(problem.path) (\(problem.expected) bytes)"
                case .inICloud: return "only in iCloud: \(problem.path)"
                case let .wrongSize(actual): return "wrong size: \(problem.path) is \(actual) bytes, expected \(problem.expected)"
                }
            }.joined(separator: "\n")
        }

        private static func examples(_ list: [Problem]) -> String {
            list.count < 2 ? list[0].path : AppLanguage.interpolate(AppLanguage.choose("{arg0} and {arg1}"), [list[0].path, list[1].path])
        }
        static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    }

    /// What a scan found: game folders (best first) and archives that may contain the game.
    struct ScanResult {
        var folders: [Report] = []
        var archives: [URL] = []
        var best: Report? { folders.first }
    }

    /// The game's file list: (path under data/, size). Read once from the app bundle.
    static let manifest: [(String, UInt64)] = {
        guard let path = EnginePaths.manifest,
              let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let files = json["files"] as? [[Any]] else { return [] }
        return files.compactMap { entry in
            guard entry.count >= 2, let name = entry[0] as? String, let size = (entry[1] as? NSNumber)?.uint64Value else { return nil }
            // The developers' debug web pages: the game never reads them, and web downloads often
            // change their size slightly, so they're left out of the check.
            if name.hasPrefix("common/non_final/www/") { return nil }
            return (name, size)
        }
    }()

    /// The GTA VI test map's files (Sandbox › GTA VI test map). Some copies of the game leave them out;
    /// the game itself doesn't need them, so they're checked on their own and only that map greys out.
    static func isTestMapFile(_ name: String) -> Bool {
        name.contains("levels/env_test/") || name.hasPrefix("common/data/env_test_")
    }
    static let testMapManifest = manifest.filter { isTestMapFile($0.0) }

    /// Whether every test map file is in `data` with its exact size.
    static func hasTestMap(_ data: URL) -> Bool {
        let base = data.path
        return testMapManifest.allSatisfy { name, expected in
            var info = stat()
            return stat(base + "/" + name, &info) == 0 && UInt64(info.st_size) == expected
        }
    }

    /// Checks every file of the game in `data` (presence and exact size). Takes well under a second.
    static func check(_ data: URL) -> Report {
        let list = manifest.filter { !isTestMapFile($0.0) }
        var problems: [Problem] = []
        var total: UInt64 = 0
        let base = data.path
        for (name, expected) in list {
            total += expected
            var info = stat()
            let path = base + "/" + name
            if stat(path, &info) != 0 {
                let file = URL(fileURLWithPath: path)
                let cloud = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud").path
                problems.append(Problem(path: name, expected: expected, kind: FileManager.default.fileExists(atPath: cloud) ? .inICloud : .missing))
            } else if UInt64(info.st_size) != expected {
                problems.append(Problem(path: name, expected: expected, kind: .wrongSize(actual: UInt64(info.st_size))))
            }
        }
        return Report(data: data, fileCount: list.count, totalBytes: total, problems: problems)
    }

    /// Looks for game folders and game archives inside `root`, up to `depth` folders down, and checks
    /// every game folder it finds. Complete folders come first, then the least broken ones.
    static func scan(_ root: URL, depth: Int = 6) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        var level = [root]
        var visited = 0
        let manager = FileManager.default
        for _ in 0...depth {
            var next: [URL] = []
            for folder in level {
                visited += 1
                if visited > 4000 { break }
                if let data = gameData(at: folder), seen.insert(data.resolvingSymlinksInPath().path).inserted {
                    result.folders.append(check(data))
                    continue // nothing more to find inside a game folder
                }
                let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                for child in children {
                    if isDirectory(child) {
                        if !skippedFolders.contains(child.lastPathComponent) && !child.lastPathComponent.hasPrefix("AssetCache-") { next.append(child) }
                    } else if isGameArchive(child) {
                        result.archives.append(child)
                    }
                }
            }
            if next.isEmpty || visited > 4000 { break }
            level = next
        }
        result.folders.sort { ($0.problems.count, $0.data.path.count) < ($1.problems.count, $1.data.path.count) }
        return result
    }

    /// The game's data folder at `folder`: the folder itself or its `data` child, holding x64 and common.
    static func gameData(at folder: URL) -> URL? {
        let data = folder.appendingPathComponent("data")
        if isData(data) { return data }
        return isData(folder) ? folder : nil
    }

    /// Never searched. Mods (the app's Mods folder, and a PC game's OpenIV mods folder): a mod with its own x64 and
    /// common folders looked like a game folder with 5,500 missing files (GTA-248, Kevin's phone 2026-10-28).
    private static let skippedFolders: Set<String> = ["x64", "common", "b", "EngineFiles", "__MACOSX", "Library", "tmp", ".Trash", "Mods", "mods"]

    private static func isData(_ url: URL) -> Bool {
        isDirectory(url.appendingPathComponent("x64")) && isDirectory(url.appendingPathComponent("common"))
    }
    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    /// A zip, rar or 7z file big enough to hold the game (the first part of a multi-part set).
    private static func isGameArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard ["zip", "rar", "7z"].contains(url.pathExtension.lowercased()) else { return false }
        if let part = name.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression), Int(name[part].filter(\.isNumber)) != 1 { return false }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 300_000_000
    }
}
