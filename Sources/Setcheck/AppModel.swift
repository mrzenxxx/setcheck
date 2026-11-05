import AppKit
import Observation
import SetcheckCore

@MainActor @Observable final class AppModel {
    var playlists: [SourcePlaylist] = []
    var selected = Set<UUID>()
    var options = ExportOptions()
    var output = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Setcheck")
    var plan: ExportPlan?
    var results: [ExportResult] = []
    var warnings: [String] = []
    var busy = false
    var stage = "Добавьте плейлист, файлы или папку"
    var progress = 0.0
    var error: String?
    var showHelp = false
    private var token = CancellationToken()
    var selectedCount: Int { playlists.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.files.count + $1.unavailable.count } }

    func invalidate() { guard !busy else { return }; plan = nil; results = []; progress = 0; stage = "Проверьте настройки и подготовьте план" }
    func toggle(_ id: UUID, _ enabled: Bool) {
        guard !busy else { return }
        if enabled { selected.insert(id) } else { selected.remove(id) }
        invalidate()
    }
    func selectAll(_ enabled: Bool) { guard !busy else { return }; selected = enabled ? Set(playlists.map(\.id)) : []; invalidate() }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        busy = true; progress = 0; stage = "Читаю плейлисты…"; token = CancellationToken()
        let cancellation = token
        Task {
            defer { busy = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try PlaylistImporter.importURLs(urls, isCancelled: { cancellation.isCancelled })
                }.value
                plan = nil; results = []
                for source in imported.playlists {
                    guard !playlists.contains(where: { $0.name == source.name && $0.files == source.files && $0.unavailable == source.unavailable }) else { continue }
                    playlists.append(source)
                    if imported.playlists.count == 1 { selected.insert(source.id) }
                }
                warnings += imported.warnings
                stage = selected.isEmpty ? "Выберите нужные плейлисты в списке слева" : "Выбрано треков: \(selectedCount). Нажмите «Подготовить»."
            } catch is CancellationError { stage = "Импорт остановлен" }
            catch { self.error = error.localizedDescription; stage = "Не удалось прочитать источник" }
        }
    }
    func chooseSources() {
        let panel = NSOpenPanel(); panel.title = "Плейлисты NML / M3U / XML или аудиофайлы"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in guard response == .OK else { return }; self?.add(panel.urls) }
    }
    func fromTraktor() {
        guard !busy else { return }
        busy = true; stage = "Ищу коллекцию Traktor…"
        token = CancellationToken(); let cancellation = token
        Task {
            let files = await Task.detached { PlaylistImporter.discoverTraktorCollections() }.value
            busy = false
            guard !cancellation.isCancelled else { stage = "Поиск Traktor остановлен"; return }
            if let latest = files.first { add([latest]) }
            else { error = "Коллекция Traktor не найдена. Выберите collection.nml через «Добавить»."; stage = "Выберите файл коллекции" }
        }
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.title = "Куда сохранять видео и треклисты"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { [weak self] response in guard response == .OK, let url = panel.url else { return }; self?.output = url }
    }
    func chooseCover() {
        let panel = NSOpenPanel(); panel.title = "Картинка для видео"
        panel.allowedContentTypes = [.png, .jpeg]; panel.canChooseDirectories = false
        panel.begin { [weak self] response in guard response == .OK else { return }; self?.options.cover = panel.url; self?.invalidate() }
    }
    func prepare() {
        guard !busy else { return }
        let sources = playlists.filter { selected.contains($0.id) }
        guard !sources.isEmpty else { return }
        token = CancellationToken(); let cancellation = token, settings = options
        busy = true; progress = 0; plan = nil; results = []; stage = "Проверяю треки и длительности…"
        let model = self
        Task {
            defer { busy = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let tools = try FFmpegTools.discover()
                    return try ExportPlanner.prepare(playlists: sources, options: settings, tools: tools, cancellation: cancellation, progress: { value in
                        Task { @MainActor in if model.busy { model.progress = value } }
                    })
                }.value
                plan = prepared; progress = 0
                stage = "Готово к экспорту: \(prepared.parts.count) видео"
            } catch is CancellationError { stage = "Подготовка остановлена" }
            catch { self.error = error.localizedDescription; stage = "Проверьте источники и настройки" }
        }
    }
    func export() {
        guard !busy, let plan, !plan.parts.isEmpty else { return }
        token = CancellationToken(); let cancellation = token, settings = options, destination = output
        busy = true; progress = 0; results = []
        let model = self
        Task {
            defer { busy = false }
            do {
                let tools = try FFmpegTools.discover()
                for (index, part) in plan.parts.enumerated() {
                    try cancellation.check()
                    stage = "Видео \(index + 1) из \(plan.parts.count): \(part.title)"
                    let result = try await Task.detached(priority: .userInitiated) {
                        try VideoExporter.export(part: part, options: settings, output: destination, tools: tools, cancellation: cancellation, progress: { value in
                            Task { @MainActor in if model.busy { model.progress = (Double(index) + value) / Double(plan.parts.count) } }
                        })
                    }.value
                    results.append(result)
                }
                progress = 1; stage = "Готово: \(results.count) видео. Теперь загрузите их в YouTube Studio."
            } catch is CancellationError { stage = "Остановлено. Готовых видео: \(results.count)"; progress = 0 }
            catch { self.error = error.localizedDescription; stage = "Экспорт прерван. Готовых видео: \(results.count)" }
        }
    }
    func cancel() { token.cancel(); stage = "Останавливаю…" }
    func clear() { guard !busy else { return }; playlists = []; selected = []; warnings = []; invalidate(); stage = "Добавьте плейлист, файлы или папку" }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func copyTracklist(_ result: ExportResult) {
        Task {
            do {
                let text = try await Task.detached { try String(contentsOf: result.tracklist, encoding: .utf8) }.value
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                if !busy { stage = "Треклист скопирован" }
            } catch { self.error = error.localizedDescription }
        }
    }
    static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60)
    }
}
