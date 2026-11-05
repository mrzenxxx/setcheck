import Foundation
import Testing
@testable import SetcheckCore

@Suite(.serialized) struct ExportTests {
    func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setcheck-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func fixture(_ root: URL, _ name: String, duration: Double = 1.2, title: String = "Трек <один>", artist: String = "Автор") throws -> URL {
        let url = root.appendingPathComponent(name)
        let p = Process(); p.executableURL = try FFmpegTools.discover().ffmpeg
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=\(duration)", "-metadata", "title=\(title)", "-metadata", "artist=\(artist)", url.path]
        p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return url
    }
    @Test func planningSplitsDeduplicatesAndRejectsMissing() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, "a.flac", duration: 2.4)
        let duplicate = try fixture(root, "copy.mp3", duration: 2.4)
        let b = try fixture(root, "b.wav", duration: 2.4, title: "Другая")
        var options = ExportOptions(); options.clipSeconds = nil; options.maxDuration = 3
        let tools = try FFmpegTools.discover()
        let plan = try ExportPlanner.prepare(playlists: [SourcePlaylist(name: "Сет", files: [a, a, duplicate, b])], options: options, tools: tools, cancellation: CancellationToken())
        #expect(plan.parts.count == 2)
        #expect(!plan.warnings.isEmpty)
        #expect(plan.parts.allSatisfy { !$0.warnings.isEmpty })
        #expect(plan.parts.flatMap(\.tracks).count == 2)
        #expect(plan.parts.allSatisfy { $0.duration <= 3 })
        #expect(!plan.parts[0].tracks[0].track.title.contains("<"))
        #expect(throws: (any Error).self) { try ExportPlanner.prepare(playlists: [SourcePlaylist(name: "Bad", files: [root.appendingPathComponent("missing.mp3")])], options: options, tools: tools, cancellation: CancellationToken()) }
        options.skipUnavailable = true
        let skipped = try ExportPlanner.prepare(playlists: [SourcePlaylist(name: "Mixed", files: [a, root.appendingPathComponent("missing.mp3")])], options: options, tools: tools, cancellation: CancellationToken())
        #expect(!skipped.warnings.isEmpty)
    }
    @Test func planningSplitsLongTracksAndDescriptionUTF8() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, "a.flac", duration: 2.5, title: String(repeating: "Ж", count: 50))
        let b = try fixture(root, "b.flac", duration: 1.2, title: String(repeating: "Ю", count: 50))
        var options = ExportOptions(); options.clipSeconds = nil; options.maxDuration = 1; options.descriptionLimit = 130
        let plan = try ExportPlanner.prepare(playlists: [SourcePlaylist(name: "Сет", files: [a, b])], options: options, tools: FFmpegTools.discover(), cancellation: CancellationToken())
        #expect(plan.parts.count >= 4)
        #expect(abs(plan.parts.flatMap(\.tracks).reduce(0) { $0 + $1.duration } - 3.7) < 0.01)
        #expect(plan.parts.allSatisfy { $0.duration <= 1.00001 })
    }
    @Test func rendersRealVideoAndActualTracklistWithoutOverwrite() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, "a.flac", duration: 1.15)
        let b = try fixture(root, "b.aiff", duration: 0.4, title: "Второй")
        let tools = try FFmpegTools.discover(); var options = ExportOptions(); options.clipSeconds = nil
        var part = try #require(ExportPlanner.prepare(playlists: [SourcePlaylist(name: "../Сет", files: [a,b])], options: options, tools: tools, cancellation: CancellationToken()).parts.first)
        // Deliberately overestimate the first clip: the second timestamp must use decoded PCM, not the plan.
        part.tracks[0].duration = 1.99
        part.title = "../" + String(repeating: "界", count: 90)
        let first = try VideoExporter.export(part: part, options: options, output: root.appendingPathComponent("exports"), tools: tools, cancellation: CancellationToken())
        let saved = try Data(contentsOf: first.video)
        let second = try VideoExporter.export(part: part, options: options, output: root.appendingPathComponent("exports"), tools: tools, cancellation: CancellationToken())
        #expect(first.directory != second.directory)
        #expect(first.directory.lastPathComponent.utf8.count <= 240)
        #expect(try Data(contentsOf: first.video) == saved)
        let list = try String(contentsOf: first.tracklist, encoding: .utf8)
        #expect(list.contains("00:00")); #expect(list.contains("00:01"))
        #expect(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("description.txt").path))
        let probe = try ProcessRunner.run(executable: tools.ffprobe, arguments: ["-v","error","-show_streams","-show_format","-of","json",first.video.path], cancellation: CancellationToken())
        let json = try #require(JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any])
        let streams = try #require(json["streams"] as? [[String: Any]])
        #expect(streams.contains { $0["codec_name"] as? String == "h264" && $0["width"] as? Int == 640 && $0["height"] as? Int == 360 })
        #expect(streams.contains { $0["codec_name"] as? String == "aac" && $0["sample_rate"] as? String == "48000" })
        let format = try #require(json["format"] as? [String:Any]); let duration = try #require(Double(format["duration"] as? String ?? ""))
        #expect(duration >= 1.5 && duration < 3)
    }
    @Test func cancellationAndDecodeFailureLeaveNoPublishedArtifacts() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("gone.wav")
        let valid = try fixture(root, "valid.flac", duration: 0.2)
        let part = VideoPart(title: "Failure", tracks: [TrackClip(track: MediaTrack(source: valid, title: "Good", duration: 0.2), start: 0, duration: 0.2), TrackClip(track: MediaTrack(source: missing, title: "Gone", duration: 2), start: 0, duration: 2)])
        let out = root.appendingPathComponent("out"); let tools = try FFmpegTools.discover()
        #expect(throws: (any Error).self) { try VideoExporter.export(part: part, options: ExportOptions(), output: out, tools: tools, cancellation: CancellationToken()) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty) ?? true)
        let token = CancellationToken(); token.cancel()
        #expect(throws: CancellationError.self) { try VideoExporter.export(part: part, options: ExportOptions(), output: out, tools: tools, cancellation: token) }
    }
    @Test func cancellationDuringStreamingCleansTemporaryOutput() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fixture(root, "cancel.flac", duration: 10)
        let token = CancellationToken(), out = root.appendingPathComponent("out")
        let part = VideoPart(title: "Cancelled", tracks: [TrackClip(track: MediaTrack(source: audio, title: "Audio", duration: 10), start: 0, duration: 10)])
        let before = Date()
        #expect(throws: CancellationError.self) {
            try VideoExporter.export(part: part, options: ExportOptions(), output: out, tools: FFmpegTools.discover(), cancellation: token, progress: { value in if value > 0 { token.cancel() } })
        }
        #expect(Date().timeIntervalSince(before) < 5)
        #expect((try FileManager.default.contentsOfDirectory(atPath: out.path)).isEmpty)
    }
    @Test func descriptionByteBudgetSplitsBeforeOverflow() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, "a.flac", duration: 0.3, title: String(repeating: "Ж", count: 40))
        let b = try fixture(root, "b.flac", duration: 0.3, title: String(repeating: "Ю", count: 40))
        var options = ExportOptions(); options.descriptionLimit = 130
        let plan = try ExportPlanner.prepare(playlists: [SourcePlaylist(name: "A", files: [a,b])], options: options, tools: FFmpegTools.discover(), cancellation: CancellationToken())
        #expect(plan.parts.count == 2)
        #expect(plan.parts.allSatisfy { $0.tracks.count == 1 })
    }

    @Test func supportsCommonFormatsAndStandardAudioWithCover() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        var files: [URL] = []
        for ext in ["mp3", "m4a", "ogg", "opus", "aiff", "wav", "flac"] {
            files.append(try fixture(root, "audio.\(ext)", duration: 0.4))
        }
        let cover = root.appendingPathComponent("cover.ppm")
        try "P3\n2 1\n255\n255 0 0  0 0 255\n".write(to: cover, atomically: true, encoding: .utf8)
        var options = ExportOptions(); options.quality = .standard; options.cover = cover
        options.deduplicateByMetadata = false; options.clipSeconds = 0.2
        let tools = try FFmpegTools.discover()
        let part = try #require(ExportPlanner.prepare(playlists: [SourcePlaylist(name: "Formats", files: files)], options: options, tools: tools, cancellation: CancellationToken()).parts.first)
        #expect(part.tracks.count == 7)
        let result = try VideoExporter.export(part: part, options: options, output: root.appendingPathComponent("out"), tools: tools, cancellation: CancellationToken())
        let probe = try ProcessRunner.run(executable: tools.ffprobe, arguments: ["-v","error","-select_streams","a:0","-show_entries","stream=sample_rate","-of","default=nw=1:nk=1",result.video.path], cancellation: CancellationToken())
        #expect(String(decoding: probe.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "44100")
        #expect(try String(contentsOf: result.tracklist, encoding: .utf8).split(separator: "\n").count == 7)
    }
    @Test func combinesGroupsAndCentersClips() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fixture(root, "center.flac", duration: 4)
        let playlists = [SourcePlaylist(name: "One", files: [audio]), SourcePlaylist(name: "Two", files: [audio])]
        var options = ExportOptions(); options.clipSeconds = 1
        let tools = try FFmpegTools.discover()
        let separate = try ExportPlanner.prepare(playlists: playlists, options: options, tools: tools, cancellation: CancellationToken())
        #expect(separate.parts.count == 2)
        #expect(separate.parts[0].tracks[0].start == 1.5)
        #expect(separate.parts[0].tracks[0].duration == 1)
        options.separatePlaylists = false
        let combined = try ExportPlanner.prepare(playlists: playlists, options: options, tools: tools, cancellation: CancellationToken())
        #expect(combined.parts.count == 1)
        #expect(combined.parts[0].tracks.count == 1)
    }

    @Test func missingPlaylistReferencesRequireExplicitSkipping() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = try fixture(root, "available.flac", duration: 0.2)
        let lists = [SourcePlaylist(name: "Partial", files: [audio], unavailable: ["Запись #404 отсутствует в коллекции"])]
        let tools = try FFmpegTools.discover(); var options = ExportOptions()
        #expect(throws: (any Error).self) { try ExportPlanner.prepare(playlists: lists, options: options, tools: tools, cancellation: CancellationToken()) }
        options.skipUnavailable = true
        let plan = try ExportPlanner.prepare(playlists: lists, options: options, tools: tools, cancellation: CancellationToken())
        #expect(plan.parts.count == 1)
        #expect(plan.warnings.contains { $0.contains("404") })
        #expect(plan.parts[0].warnings.contains { $0.contains("404") })
        options.separatePlaylists = false
        let combined = try ExportPlanner.prepare(playlists: lists, options: options, tools: tools, cancellation: CancellationToken())
        #expect(combined.warnings.contains { $0.contains("404") })
    }

}
