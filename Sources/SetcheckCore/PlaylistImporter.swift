import Foundation

public enum PlaylistImporter {
    public static func importURLs(_ urls: [URL], isCancelled: @Sendable () -> Bool = { false }) throws -> ImportResult {
        try withoutActuallyEscaping(isCancelled) { check in
            let importer = ImportSession(isCancelled: check)
            return try importer.run(urls)
        }
    }

    /// Only discovers collection paths; Traktor files and preferences are never changed.
    public static func discoverTraktorCollections(documents: URL? = nil) -> [URL] {
        let manager = FileManager.default
        let documents = documents ?? manager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let base = documents.appendingPathComponent("Native Instruments")
        guard let folders = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return folders.filter { $0.lastPathComponent.hasPrefix("Traktor") }
            .map { $0.appendingPathComponent("collection.nml") }
            .filter { manager.isReadableFile(atPath: $0.path) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.path.localizedStandardCompare(rhs.0.path) == .orderedDescending
            }
            .map(\.0)
    }
}

private final class ImportSession {
    static let audioExtensions: Set<String> = ["flac", "wav", "aiff", "aif", "mp3", "m4a", "ogg", "opus"]
    static let maximumPlaylistBytes = 64 * 1024 * 1024
    let isCancelled: @Sendable () -> Bool
    var playlists: [SourcePlaylist] = []
    var warnings: [String] = []
    let manager = FileManager.default

    init(isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
    func check() throws { if isCancelled() { throw CancellationError() } }

    func run(_ urls: [URL]) throws -> ImportResult {
        var seen = Set<String>()
        var direct: [URL] = []
        for input in urls {
            try check()
            guard input.isFileURL else { throw SetcheckError.message("Импорт поддерживает только локальные файлы: \(input.absoluteString)") }
            let url = input.standardizedFileURL
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                var visited = Set<String>()
                let files = try folderFiles(url, visited: &visited)
                try add(name: url.lastPathComponent, files: files)
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                direct.append(url)
            } else {
                switch url.pathExtension.lowercased() {
                case "m3u", "m3u8": try importM3U(url)
                case "nml", "xml": try importXML(url)
                default: throw SetcheckError.message("Неподдерживаемый формат: \(url.lastPathComponent). Выберите аудио, папку, M3U, NML или rekordbox XML.")
                }
            }
        }
        if !direct.isEmpty { try add(name: "Аудиофайлы", files: direct) }
        var used = Set<String>()
        for index in playlists.indices {
            let base = playlists[index].name
            var name = base, suffix = 2
            while !used.insert(name).inserted { name = "\(base) (\(suffix))"; suffix += 1 }
            playlists[index].name = name
        }
        try check()
        return ImportResult(playlists: playlists, warnings: warnings)
    }

    func add(name: String, files: [URL], unavailable: [String] = []) throws {
        try check()
        for file in files {
            try check()
            if !manager.isReadableFile(atPath: file.path) {
                warnings.append("Файл недоступен и сохранён в плейлисте: \(file.path)")
            }
        }
        if files.isEmpty { warnings.append("Плейлист «\(name)» не содержит доступных ссылок на аудио.") }
        playlists.append(SourcePlaylist(name: name, files: files, unavailable: unavailable))
    }

    func folderFiles(_ folder: URL, visited: inout Set<String>) throws -> [URL] {
        try check()
        guard visited.insert(folder.resolvingSymlinksInPath().path).inserted else { return [] }
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) }
        catch { throw SetcheckError.message("Не удалось прочитать папку \(folder.path): \(error.localizedDescription)") }
        var files: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try check()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                // Avoid cycles and accidental traversal into an entirely different library.
                if values.isSymbolicLink != true { files += try folderFiles(child, visited: &visited) }
            } else if Self.audioExtensions.contains(child.pathExtension.lowercased()) { files.append(child) }
        }
        return files
    }

    func read(_ url: URL) throws -> Data {
        try check()
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumPlaylistBytes else {
                throw SetcheckError.message("Плейлист \(url.lastPathComponent) превышает допустимый размер 64 МБ.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumPlaylistBytes + 1) ?? Data()
            guard data.count <= Self.maximumPlaylistBytes else { throw SetcheckError.message("Плейлист превышает допустимый размер 64 МБ.") }
            try check()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw SetcheckError.message("Не удалось импортировать \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    func importM3U(_ url: URL) throws {
        let data = try read(url)
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else if let legacy = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            text = legacy
            warnings.append("\(url.lastPathComponent): кодировка не UTF-8; применена Windows-1252/Latin-1. Проверьте имена файлов; для кириллицы сохраните плейлист в UTF-8.")
        } else { throw SetcheckError.message("Не удалось распознать кодировку \(url.lastPathComponent). Сохраните плейлист в UTF-8.") }
        var files: [URL] = []
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            try check()
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            files.append(try pathURL(line, relativeTo: url.deletingLastPathComponent()))
        }
        try add(name: url.deletingPathExtension().lastPathComponent, files: files)
    }

    func pathURL(_ path: String, relativeTo directory: URL) throws -> URL {
        if path.lowercased().hasPrefix("file:") {
            guard let parsed = URL(string: path), parsed.isFileURL,
                  parsed.host == nil || parsed.host == "" || parsed.host?.lowercased() == "localhost" else {
                throw SetcheckError.message("Некорректная локальная ссылка: \(path)")
            }
            return URL(fileURLWithPath: parsed.path).standardizedFileURL
        }
        if path.range(of: "^[a-zA-Z]:[\\\\/]", options: .regularExpression) != nil || path.hasPrefix("\\\\") {
            warnings.append("Путь Windows требует проверки на этом Mac: \(path)")
            return URL(fileURLWithPath: "/" + path.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
        }
        if path.contains("://") { throw SetcheckError.message("Сетевой адрес не является локальным аудиофайлом: \(path)") }
        // A literal percent is legal in a filename. Decode only when the literal file does not exist.
        let literal = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        if manager.fileExists(atPath: literal.path) { return literal.standardizedFileURL }
        let decoded = path.removingPercentEncoding ?? path
        return (decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : directory.appendingPathComponent(decoded)).standardizedFileURL
    }

    func importXML(_ url: URL) throws {
        let data = try read(url)
        // XMLParser can silently ignore declarations when entity resolution is disabled.
        // Reject DTDs before parsing, including UTF-16/32 encodings with interleaved zero bytes.
        let declaration = Array("<!DOCTYPE".utf8)
        var matched = 0
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 16_384) { try check() }
            if byte == 0 { continue }
            if byte == declaration[matched] { matched += 1 }
            else { matched = byte == declaration[0] ? 1 : 0 }
            if matched == declaration.count { throw SetcheckError.message("XML с DOCTYPE и объявлениями сущностей не поддерживается.") }
        }
        let delegate = PlaylistXMLReader(isCancelled: isCancelled)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil, let root = delegate.root else {
            try check()
            if let failure = delegate.failure { throw failure }
            throw SetcheckError.message("Некорректный XML \(url.lastPathComponent), строка \(parser.lineNumber): \(parser.parserError?.localizedDescription ?? "пустой документ")")
        }
        try check()
        switch root.name {
        case "NML": try importNML(root, source: url)
        case "DJ_PLAYLISTS": try importRekordbox(root, source: url)
        default: throw SetcheckError.message("XML \(url.lastPathComponent) не является коллекцией Traktor NML или rekordbox DJ_PLAYLISTS.")
        }
    }

    func traktorURL(_ encoded: String, volume: String = "", relativeTo directory: URL) throws -> URL {
        var path = encoded, drive = volume
        if let marker = path.range(of: "/:"), marker.lowerBound != path.startIndex {
            drive = String(path[..<marker.lowerBound]); path = String(path[marker.lowerBound...])
        }
        path = path.replacingOccurrences(of: "/:", with: "/")
        if drive.count == 2, drive.last == ":" { return try pathURL(drive + path, relativeTo: directory) }
        let local = URL(fileURLWithPath: path)
        let knownRoot = ["/Users/", "/Volumes/", "/private/", "/tmp/", "/System/"].contains { path.hasPrefix($0) }
        if !drive.isEmpty, !knownRoot, !drive.hasPrefix("Macintosh"), !manager.fileExists(atPath: local.path) {
            path = "/Volumes/" + drive + (path.hasPrefix("/") ? path : "/" + path)
        }
        return try pathURL(path, relativeTo: directory)
    }

    func importNML(_ root: PlaylistXMLNode, source: URL) throws {
        let directory = source.deletingLastPathComponent()
        let countBefore = playlists.count
        func visit(_ node: PlaylistXMLNode, parents: [String]) throws {
            try check()
            var path = parents
            if node.name == "NODE", let name = node.attributes["NAME"], name != "$ROOT" { path.append(name) }
            if node.name == "NODE", let list = node.children.first(where: { $0.name == "PLAYLIST" }) {
                var files: [URL] = []
                var unavailable: [String] = []
                for (index, entry) in list.children.enumerated() where entry.name == "ENTRY" {
                    try check()
                    if let key = entry.children.first(where: { $0.name == "PRIMARYKEY" })?.attributes["KEY"], !key.isEmpty {
                        files.append(try traktorURL(key, relativeTo: directory))
                    } else {
                        let label = "Traktor: в «\(path.joined(separator: " / "))» отсутствует PRIMARYKEY трека №\(index + 1)."
                        warnings.append(label); unavailable.append(label)
                    }
                }
                try add(name: path.isEmpty ? source.deletingPathExtension().lastPathComponent : path.joined(separator: " / "), files: files, unavailable: unavailable)
            }
            for child in node.children { try visit(child, parents: path) }
        }
        for list in root.children where list.name == "PLAYLISTS" { try visit(list, parents: []) }
        if playlists.count == countBefore {
            var files: [URL] = []
            var unavailable: [String] = []
            let entries = root.children.first(where: { $0.name == "COLLECTION" })?.children ?? []
            for (index, entry) in entries.enumerated() where entry.name == "ENTRY" {
                try check()
                if let location = entry.children.first(where: { $0.name == "LOCATION" }), let filename = location.attributes["FILE"], !filename.isEmpty {
                    files.append(try traktorURL((location.attributes["DIR"] ?? "") + filename, volume: location.attributes["VOLUME"] ?? "", relativeTo: directory))
                } else {
                    let label = "Traktor: запись COLLECTION №\(index + 1) без LOCATION/FILE."
                    warnings.append(label); unavailable.append(label)
                }
            }
            try add(name: source.deletingPathExtension().lastPathComponent, files: files, unavailable: unavailable)
        }
    }

    func importRekordbox(_ root: PlaylistXMLNode, source: URL) throws {
        var tracks: [String: URL] = [:], collection: [URL] = []
        var collectionUnavailable: [String] = []
        for track in root.children.first(where: { $0.name == "COLLECTION" })?.children ?? [] where track.name == "TRACK" {
            try check()
            guard let id = track.attributes["TrackID"], let location = track.attributes["Location"], !location.isEmpty else {
                let label = "rekordbox: запись COLLECTION TrackID \(track.attributes["TrackID"] ?? "?") без TrackID или Location."
                warnings.append(label); collectionUnavailable.append(label); continue
            }
            let file = try pathURL(location, relativeTo: source.deletingLastPathComponent())
            if tracks[id] != nil { warnings.append("rekordbox: повтор TrackID \(id), используется последняя запись.") }
            tracks[id] = file; collection.append(file)
        }
        let countBefore = playlists.count
        func visit(_ node: PlaylistXMLNode, parents: [String]) throws {
            try check()
            var path = parents
            if node.name == "NODE", let name = node.attributes["Name"], !(parents.isEmpty && name == "ROOT") { path.append(name) }
            if node.name == "NODE", node.attributes["Type"] == "1" {
                var files: [URL] = []
                var unavailable: [String] = []
                for item in node.children where item.name == "TRACK" {
                    try check()
                    let id = item.attributes["Key"] ?? "?"
                    if let file = tracks[id] { files.append(file) }
                    else {
                        let label = "rekordbox: TrackID \(id) из «\(path.joined(separator: " / "))» отсутствует в COLLECTION."
                        warnings.append(label); unavailable.append(label)
                    }
                }
                try add(name: path.isEmpty ? source.deletingPathExtension().lastPathComponent : path.joined(separator: " / "), files: files, unavailable: unavailable)
            }
            for child in node.children where child.name == "NODE" { try visit(child, parents: path) }
        }
        for container in root.children where container.name == "PLAYLISTS" { try visit(container, parents: []) }
        if playlists.count == countBefore { try add(name: source.deletingPathExtension().lastPathComponent, files: collection, unavailable: collectionUnavailable) }
    }
}

private final class PlaylistXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [PlaylistXMLNode] = []
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
}

private final class PlaylistXMLReader: NSObject, XMLParserDelegate {
    let isCancelled: @Sendable () -> Bool
    var root: PlaylistXMLNode?
    var stack: [PlaylistXMLNode] = []
    var count = 0
    var failure: (any Error)?
    init(isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
    func reject(_ parser: XMLParser, _ error: any Error) { failure = error; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if isCancelled() { reject(parser, CancellationError()); return }
        count += 1
        guard stack.count < 128, count <= 500_000 else { reject(parser, SetcheckError.message("XML слишком сложный: превышено число элементов или глубина вложенности.")); return }
        let node = PlaylistXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
        if isCancelled() { reject(parser, CancellationError()) }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        reject(parser, SetcheckError.message("XML с объявлениями сущностей не поддерживается."))
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        reject(parser, SetcheckError.message("XML с внешними сущностями не поддерживается."))
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser, SetcheckError.message("Загрузка внешних сущностей XML запрещена.")); return nil
    }
}
