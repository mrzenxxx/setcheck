import Foundation
import Darwin

public enum VideoExporter {
    public static func export(part: VideoPart, options: ExportOptions, output: URL, tools: FFmpegTools, cancellation: CancellationToken, progress: @Sendable (Double) -> Void = { _ in }) throws -> ExportResult {
        try cancellation.check(); try ExportPlanner.validate(options)
        guard output.isFileURL, !part.tracks.isEmpty, part.duration.isFinite, part.duration > 0, part.duration <= options.maxDuration + 0.01 else {
            throw SetcheckError.message("Пустое видео или превышен предел длительности. Подготовьте план экспорта заново.")
        }
        let sampleRate = options.quality == .high ? 48_000 : 44_100
        let format = options.quality == .high ? "f32le" : "s16le"
        let frameBytes: Int64 = options.quality == .high ? 8 : 4
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let staging = output.appendingPathComponent(".setcheck-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let encoded = staging.appendingPathComponent("encoded.mp4")
        let video = staging.appendingPathComponent("video.mp4")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe"]
        if let cover = options.cover {
            guard cover.isFileURL, fm.isReadableFile(atPath: cover.path) else { throw SetcheckError.message("Изображение обложки недоступно.") }
            arguments += ["-loop", "1", "-framerate", "1", "-i", cover.path]
        } else {
            arguments += ["-f", "lavfi", "-i", "color=c=0x171a22:s=640x360:r=1"]
        }
        arguments += ["-f", format, "-ar", "\(sampleRate)", "-ac", "2", "-i", "pipe:0", "-map", "0:v:0", "-map", "1:a:0",
                      "-vf", "scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,setsar=1",
                      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "stillimage", "-crf", "32", "-pix_fmt", "yuv420p", "-r", "1",
                      "-c:a", "aac", "-b:a", options.quality == .high ? "384k" : "192k", "-ar", "\(sampleRate)", "-shortest", "-t", String(format: "%.9f", part.duration + 1), encoded.path]
        // A closed encoder pipe must become a Swift error, never terminate the application.
        signal(SIGPIPE, SIG_IGN)
        let input = Pipe()
        let encoder = MediaProcess(executable: tools.ffmpeg, arguments: arguments, input: input, cancellation: cancellation)
        try encoder.start(captureOutput: true)
        try? input.fileHandleForReading.close()
        var encoderFinished = false
        defer {
            try? input.fileHandleForWriting.close()
            if !encoderFinished { encoder.stop(); _ = try? encoder.wait() }
        }
        var actualFrames: Int64 = 0
        var lines = ""
        let plannedFrames = max(1.0, part.duration * Double(sampleRate))
        for clip in part.tracks {
            try cancellation.check()
            guard clip.start.isFinite, clip.duration.isFinite, clip.start >= 0, clip.duration > 0, clip.track.source.isFileURL else { throw SetcheckError.message("Некорректный фрагмент аудио.") }
            let firstSample = Int64((clip.start * Double(sampleRate)).rounded())
            let sampleCount = Int64((clip.duration * Double(sampleRate)).rounded())
            guard sampleCount > 0 else { throw SetcheckError.message("Слишком короткий фрагмент аудио.") }
            let decoder = MediaProcess(executable: tools.ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-protocol_whitelist", "file,pipe", "-i", clip.track.source.path,
                "-map", "0:a:0", "-vn", "-sn", "-dn", "-af", "aresample=\(sampleRate),atrim=start_sample=\(firstSample):end_sample=\(firstSample + sampleCount),asetpts=PTS-STARTPTS",
                "-t", String(format: "%.9f", Double(sampleCount) / Double(sampleRate)), "-ar", "\(sampleRate)", "-ac", "2", "-f", format, "pipe:1"
            ], cancellation: cancellation)
            try decoder.start()
            var decodedBytes: Int64 = 0
            do {
                while let chunk = try decoder.output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    try cancellation.check()
                    try input.fileHandleForWriting.write(contentsOf: chunk)
                    decodedBytes += Int64(chunk.count)
                    progress(min(0.99, Double(actualFrames + decodedBytes / frameBytes) / plannedFrames))
                }
                _ = try decoder.wait()
            } catch {
                decoder.stop(); _ = try? decoder.wait()
                try cancellation.check()
                throw error
            }
            guard decodedBytes > 0, decodedBytes % frameBytes == 0 else { throw SetcheckError.message("Аудиофрагмент не удалось декодировать полностью: \(clip.track.source.lastPathComponent)") }
            lines += ExportText.line(Double(actualFrames) / Double(sampleRate), clip.track.title)
            actualFrames += decodedBytes / frameBytes
        }
        try input.fileHandleForWriting.close()
        _ = try encoder.wait(); encoderFinished = true
        try cancellation.check()
        guard ExportText.fits(lines, limit: options.descriptionLimit), Double(actualFrames) / Double(sampleRate) <= options.maxDuration + 0.001 else {
            throw SetcheckError.message("Итоговое видео или описание превышает предел. Подготовьте план с меньшим числом треков.")
        }
        // Infinite image inputs can run ahead of piped audio even with -shortest (FFmpeg 9).
        // Copy packets once using the measured PCM end; AAC is never encoded a second time.
        _ = try ProcessRunner.run(executable: tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", "-i", encoded.path,
            "-t", String(format: "%.9f", Double(actualFrames) / Double(sampleRate)),
            "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-movflags", "+faststart", video.path
        ], cancellation: cancellation)
        try fm.removeItem(at: encoded)
        try lines.write(to: staging.appendingPathComponent("tracklist.txt"), atomically: true, encoding: .utf8)
        try lines.write(to: staging.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)
        let report = """
        \(ExportText.clean(part.title))
        Длительность аудио: \(String(format: "%.3f", Double(actualFrames) / Double(sampleRate))) с
        Аудио: AAC, \(options.quality == .high ? "384 кбит/с, 48 кГц" : "192 кбит/с, 44,1 кГц")
        \(part.warnings.joined(separator: "\n"))

        Загрузите video.mp4 вручную в YouTube Studio с доступом «Ограниченный доступ» и вставьте description.txt в описание.
        Дождитесь завершения обработки и проверки YouTube. Сверьте найденные совпадения и ограничения в YouTube Studio.
        Setcheck подготавливает локальные файлы; проверку прав выполняет YouTube. Отсутствие совпадений не означает разрешение правообладателя.
        Время треков рассчитано по фактически декодированным аудиосэмплам; значения округлены вниз до секунды.
        """
        try report.write(to: staging.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try cancellation.check()
        let safeName = folderName(part.title)
        for attempt in 0..<100 {
            try cancellation.check()
            let suffix = attempt == 0 ? "" : "-\(UUID().uuidString.prefix(8))"
            let destination = output.appendingPathComponent(safeName + suffix, isDirectory: true)
            // Darwin's exclusive rename publishes the complete directory atomically without replacing existing exports.
            let result = staging.path.withCString { source in destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) } }
            if result == 0 {
                progress(1)
                return ExportResult(directory: destination, video: destination.appendingPathComponent("video.mp4"), tracklist: destination.appendingPathComponent("tracklist.txt"))
            }
            if errno != EEXIST { throw SetcheckError.message("Не удалось сохранить экспорт: \(String(cString: strerror(errno)))") }
        }
        throw SetcheckError.message("Не удалось выбрать свободное имя папки экспорта.")
    }
    private static func folderName(_ title: String) -> String {
        let cleaned = ExportText.clean(title).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = ExportText.shortened(cleaned, bytes: 220).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Сет" : name
    }
}
