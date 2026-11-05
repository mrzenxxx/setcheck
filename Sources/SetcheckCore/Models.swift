import Foundation

public struct SourcePlaylist: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var files: [URL]
    public var unavailable: [String]
    public init(id: UUID = UUID(), name: String, files: [URL], unavailable: [String] = []) { self.id = id; self.name = name; self.files = files; self.unavailable = unavailable }
}
public struct ImportResult: Sendable {
    public var playlists: [SourcePlaylist]
    public var warnings: [String]
    public init(playlists: [SourcePlaylist], warnings: [String] = []) { self.playlists = playlists; self.warnings = warnings }
}
public struct MediaTrack: Sendable {
    public var source: URL
    public var title: String
    public var duration: Double
    public init(source: URL, title: String, duration: Double) { self.source = source; self.title = title; self.duration = duration }
}
public struct TrackClip: Sendable {
    public var track: MediaTrack
    public var start: Double
    public var duration: Double
    public init(track: MediaTrack, start: Double, duration: Double) { self.track = track; self.start = start; self.duration = duration }
}
public struct VideoPart: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var tracks: [TrackClip]
    public var warnings: [String]
    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    public init(id: UUID = UUID(), title: String, tracks: [TrackClip], warnings: [String] = []) { self.id = id; self.title = title; self.tracks = tracks; self.warnings = warnings }
}
public struct ExportPlan: Sendable {
    public var parts: [VideoPart]
    public var warnings: [String]
    public init(parts: [VideoPart], warnings: [String] = []) { self.parts = parts; self.warnings = warnings }
}
public enum AudioQuality: String, CaseIterable, Sendable { case standard, high }
public struct ExportOptions: Equatable, Sendable {
    public var clipSeconds: Double? = 180
    public var separatePlaylists = true
    public var deduplicateByMetadata = true
    public var skipUnavailable = false
    public var maxDuration: Double = 42_840
    public var descriptionLimit = 5000
    public var quality: AudioQuality = .high
    public var cover: URL?
    public init() {}
}
public struct ExportResult: Sendable {
    public var directory: URL
    public var video: URL
    public var tracklist: URL
    public init(directory: URL, video: URL, tracklist: URL) { self.directory = directory; self.video = video; self.tracklist = tracklist }
}
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func check() throws { if isCancelled { throw CancellationError() } }
}
public struct FFmpegTools: Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL
    public init(ffmpeg: URL, ffprobe: URL) { self.ffmpeg = ffmpeg; self.ffprobe = ffprobe }
    public static func discover() throws -> FFmpegTools {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        if FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("ffmpeg").path), FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("ffprobe").path) {
            return FFmpegTools(ffmpeg: bundle.appendingPathComponent("ffmpeg"), ffprobe: bundle.appendingPathComponent("ffprobe"))
        }
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["SETCHECK_FFMPEG_DIR"], "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
        for path in candidates {
            let base = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: base.appendingPathComponent("ffmpeg").path), FileManager.default.isExecutableFile(atPath: base.appendingPathComponent("ffprobe").path) {
                return FFmpegTools(ffmpeg: base.appendingPathComponent("ffmpeg"), ffprobe: base.appendingPathComponent("ffprobe"))
            }
        }
        throw SetcheckError.message("В приложении отсутствует модуль обработки медиа. Установите полную сборку Setcheck.")
    }
}
public enum SetcheckError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
