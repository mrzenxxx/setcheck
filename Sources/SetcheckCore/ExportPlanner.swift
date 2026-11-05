import Foundation

struct ProbedTrack {
    var track: MediaTrack
    var metadataKey: String?
}

enum ExportText {
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "<" || scalar == ">" ? UnicodeScalar(32)! : scalar
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600 ? String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
    static func line(_ seconds: Double, _ title: String) -> String { "\(timestamp(seconds)) \(clean(title))\n" }
    static func fits(_ text: String, limit: Int) -> Bool { text.count <= limit && text.utf8.count <= limit }
    static func shortened(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in clean(text) {
            if result.utf8.count + String(character).utf8.count > bytes { break }
            result.append(character)
        }
        return result
    }
}

public enum ExportPlanner {
    public static func prepare(playlists: [SourcePlaylist], options: ExportOptions, tools: FFmpegTools, cancellation: CancellationToken, progress: @Sendable (Double) -> Void = { _ in }) throws -> ExportPlan {
        try validate(options)
        try cancellation.check()
        let groups = options.separatePlaylists ? playlists : [SourcePlaylist(name: "Общий сет", files: playlists.flatMap(\.files), unavailable: playlists.flatMap(\.unavailable))]
        guard !playlists.isEmpty else { throw SetcheckError.message("Нет плейлистов для экспорта.") }
        var cache: [String: ProbedTrack] = [:]
        var failed: [String: String] = [:]
        var parts: [VideoPart] = [], warnings: [String] = []
        let total = max(1, groups.reduce(0) { $0 + $1.files.count }); var visited = 0
        for group in groups {
            if !group.unavailable.isEmpty && !options.skipUnavailable {
                throw SetcheckError.message("В плейлисте «\(ExportText.clean(group.name))» есть недоступные записи: \(group.unavailable.joined(separator: "; "))")
            }
            var paths = Set<String>(), seen: [String: [Double]] = [:]
            var clips: [TrackClip] = [], groupWarnings = group.unavailable.map { "Пропущена недоступная запись: \($0)" }
            for source in group.files {
                try cancellation.check()
                visited += 1; progress(Double(visited) / Double(total))
                let file = source.standardizedFileURL.resolvingSymlinksInPath()
                let key = file.path
                guard paths.insert(key).inserted else { groupWarnings.append("Повтор пути исключён: \(file.lastPathComponent)"); continue }
                let probe: ProbedTrack
                do {
                    if let value = cache[key] { probe = value }
                    else if let message = failed[key] { throw SetcheckError.message(message) }
                    else { probe = try inspect(file, tools: tools, cancellation: cancellation); cache[key] = probe }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let message = "\(file.lastPathComponent): \(error.localizedDescription)"
                    failed[key] = message
                    guard options.skipUnavailable else { throw SetcheckError.message(message) }
                    groupWarnings.append("Пропущен файл: \(message)"); continue
                }
                if options.deduplicateByMetadata, let metadata = probe.metadataKey {
                    if seen[metadata, default: []].contains(where: { abs($0 - probe.track.duration) <= 1.5 }) { groupWarnings.append("Повтор по исполнителю, названию и длительности исключён: \(probe.track.title)"); continue }
                    seen[metadata, default: []].append(probe.track.duration)
                }
                var track = probe.track
                // Reserve the longest possible timestamp and separator for a single description line.
                let trimmed = ExportText.shortened(track.title, bytes: options.descriptionLimit - 10)
                if trimmed != track.title { groupWarnings.append("Название сокращено для описания: \(track.title)"); track.title = trimmed }
                let length = min(options.clipSeconds ?? track.duration, track.duration)
                let start = options.clipSeconds == nil ? 0 : max(0, (track.duration - length) / 2)
                var offset = 0.0
                while offset < length - 0.000_001 {
                    let segment = min(length - offset, options.maxDuration)
                    clips.append(TrackClip(track: track, start: start + offset, duration: segment))
                    offset += segment
                }
            }
            var batches: [[TrackClip]] = [], batch: [TrackClip] = [], duration = 0.0, text = ""
            for clip in clips {
                let candidate = text + ExportText.line(duration, clip.track.title)
                if !batch.isEmpty && (duration + clip.duration > options.maxDuration + 0.000_001 || !ExportText.fits(candidate, limit: options.descriptionLimit)) {
                    batches.append(batch); batch = []; duration = 0; text = ""
                }
                text += ExportText.line(duration, clip.track.title)
                batch.append(clip); duration += clip.duration
            }
            if !batch.isEmpty { batches.append(batch) }
            for (index, tracks) in batches.enumerated() {
                let name = ExportText.clean(group.name).isEmpty ? "Сет" : ExportText.clean(group.name)
                parts.append(VideoPart(title: batches.count > 1 ? "\(name) — часть \(index + 1)" : name, tracks: tracks, warnings: groupWarnings))
            }
            if clips.isEmpty { groupWarnings.append("В плейлисте «\(ExportText.clean(group.name))» нет доступных аудиотреков для экспорта.") }
            warnings.append(contentsOf: groupWarnings)
        }
        progress(1)
        return ExportPlan(parts: parts, warnings: warnings)
    }
    static func validate(_ options: ExportOptions) throws {
        guard options.maxDuration.isFinite, options.maxDuration > 0, options.maxDuration <= 42_840,
              options.descriptionLimit >= 20, options.descriptionLimit <= 5000,
              options.clipSeconds == nil || (options.clipSeconds!.isFinite && options.clipSeconds! > 0) else {
            throw SetcheckError.message("Некорректные параметры длительности или описания.")
        }
    }
    private static func inspect(_ file: URL, tools: FFmpegTools, cancellation: CancellationToken) throws -> ProbedTrack {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else { throw SetcheckError.message("Файл недоступен.") }
        let result = try ProcessRunner.run(executable: tools.ffprobe, arguments: ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_format", "-show_streams", "-of", "json", file.path], cancellation: cancellation)
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else { throw SetcheckError.message("В файле нет аудиодорожки.") }
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = [format["duration"], audio["duration"]].compactMap { value -> Double? in
            if let string = value as? String { return Double(string) }; return value as? Double
        }.first(where: { $0.isFinite && $0 > 0 })
        guard let duration else { throw SetcheckError.message("Не удалось определить длительность аудио.") }
        var tags: [String: String] = [:]
        for source in [audio["tags"], format["tags"]] {
            for (name, value) in source as? [String: String] ?? [:] { tags[name.lowercased()] = ExportText.clean(value) }
        }
        let title = tags["title"].flatMap { $0.isEmpty ? nil : $0 }
        let artist = tags["artist"].flatMap { $0.isEmpty ? nil : $0 }
        let label = [artist, title].compactMap { $0 }.joined(separator: " — ")
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let metadata = title != nil && artist != nil ? normalized(artist!) + "\u{0}" + normalized(title!) : nil
        return ProbedTrack(track: MediaTrack(source: file, title: label.isEmpty ? ExportText.clean(file.deletingPathExtension().lastPathComponent) : label, duration: duration), metadataKey: metadata)
    }
}
