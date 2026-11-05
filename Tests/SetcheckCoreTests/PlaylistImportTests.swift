import Foundation
import Testing
@testable import SetcheckCore

struct PlaylistImportTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setcheck-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    @discardableResult private func write(_ root: URL, _ path: String, _ text: String = "") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func m3uPreservesOrderUnicodeEscapesAndUnavailableFiles() throws {
        try fixture { root in
            let track = try write(root, "трек #1.flac")
            let list = try write(root, "mix.m3u8", "\u{FEFF}#EXTM3U\nmissing.wav\n\(track.absoluteString)\nтрек #1.flac\n")
            let result = try PlaylistImporter.importURLs([list])
            #expect(result.playlists.count == 1)
            #expect(result.playlists[0].files.map(\.lastPathComponent) == ["missing.wav", "трек #1.flac", "трек #1.flac"])
            #expect(result.playlists[0].files[1].path == track.path)
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func foldersAreNaturalSortedRecursiveAndIgnoreHidden() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("Set")
            try write(folder, "10.wav"); try write(folder, "2.flac")
            try write(folder, "sub/3.mp3"); try write(folder, ".hidden/1.wav")
            try write(folder, "cover.jpg"); try write(folder, ".skip.wav")
            let result = try PlaylistImporter.importURLs([folder, folder])
            #expect(result.playlists.count == 1)
            #expect(result.playlists[0].files.map(\.lastPathComponent) == ["2.flac", "10.wav", "3.mp3"])
        }
    }

    @Test func directFilesRemainInInputOrderWithoutDuplicateInputs() throws {
        try fixture { root in
            let a = try write(root, "a.aiff"), b = try write(root, "b.opus")
            let result = try PlaylistImporter.importURLs([b, a, b])
            #expect(result.playlists.flatMap(\.files) == [b, a])
        }
    }

    @Test func nmlResolvesPrimaryKeysAndDisambiguatesFolders() throws {
        try fixture { root in
            let a = try write(root, "a.wav"), b = try write(root, "б.wav")
            let keyA = a.path.replacingOccurrences(of: "/", with: "/:")
            let keyB = b.path.replacingOccurrences(of: "/", with: "/:")
            let nml = try write(root, "collection.nml", """
            <?xml version="1.0"?><NML VERSION="19"><COLLECTION ENTRIES="2">
            <ENTRY><LOCATION DIR="\(root.path.replacingOccurrences(of: "/", with: "/:"))/:" FILE="a.wav" VOLUME="Macintosh HD"/></ENTRY>
            </COLLECTION><PLAYLISTS><NODE TYPE="1" NAME="$ROOT"><SUBNODES COUNT="2">
            <NODE TYPE="1" NAME="Warmup"><SUBNODES COUNT="1"><NODE TYPE="0" NAME="Mix"><PLAYLIST><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="\(keyB)"/></ENTRY><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="\(keyA)"/></ENTRY></PLAYLIST></NODE></SUBNODES></NODE>
            <NODE TYPE="1" NAME="Peak"><SUBNODES COUNT="1"><NODE TYPE="0" NAME="Mix"><PLAYLIST><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="\(keyA)"/></ENTRY></PLAYLIST></NODE></SUBNODES></NODE>
            </SUBNODES></NODE></PLAYLISTS></NML>
            """)
            let result = try PlaylistImporter.importURLs([nml])
            #expect(result.playlists.map(\.name) == ["Warmup / Mix", "Peak / Mix"])
            #expect(result.playlists[0].files.map(\.path) == [b.path, a.path])
        }
    }

    @Test func standaloneNMLCollectionUsesLocation() throws {
        try fixture { root in
            let path = root.path.replacingOccurrences(of: "/", with: "/:") + "/:"
            let nml = try write(root, "export.nml", "<NML><COLLECTION><ENTRY><LOCATION DIR=\"\(path)\" FILE=\"missing.flac\" VOLUME=\"Macintosh HD\"/></ENTRY></COLLECTION></NML>")
            let result = try PlaylistImporter.importURLs([nml])
            #expect(result.playlists[0].files[0].path == root.appendingPathComponent("missing.flac").path)
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func rekordboxResolvesTrackIDsAndReportsUnknownIDs() throws {
        try fixture { root in
            let a = try write(root, "one #1.wav"), b = try write(root, "два.mp3")
            let xml = try write(root, "rekordbox.xml", """
            <DJ_PLAYLISTS><COLLECTION><TRACK TrackID="1" Location="\(a.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/"))"/><TRACK TrackID="2" Location="\(b.absoluteString)"/></COLLECTION><PLAYLISTS><NODE Type="0" Name="ROOT"><NODE Type="0" Name="Folder"><NODE Type="1" Name="Mix"><TRACK Key="2"/><TRACK Key="1"/><TRACK Key="404"/></NODE></NODE></NODE></PLAYLISTS></DJ_PLAYLISTS>
            """)
            let result = try PlaylistImporter.importURLs([xml])
            #expect(result.playlists[0].name == "Folder / Mix")
            #expect(result.playlists[0].files.map(\.path) == [b.path, a.path])
            #expect(result.warnings.contains { $0.contains("404") })
            #expect(result.playlists[0].unavailable.count == 1)
            #expect(result.playlists[0].unavailable.first?.contains("404") == true)
        }
    }

    @Test func malformedOrUnknownXMLFailsClearly() throws {
        try fixture { root in
            for (name, xml) in [("bad.nml", "<NML><COLLECTION>"), ("unknown.xml", "<something/>"), ("doctype.xml", "<!DOCTYPE DJ_PLAYLISTS [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><DJ_PLAYLISTS>&x;</DJ_PLAYLISTS>")] {
                let file = try write(root, name, xml)
                #expect(throws: (any Error).self) { try PlaylistImporter.importURLs([file]) }
            }
            let utf16 = root.appendingPathComponent("utf16.xml")
            try #require("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE DJ_PLAYLISTS><DJ_PLAYLISTS/>".data(using: .utf16)).write(to: utf16)
            #expect(throws: (any Error).self) { try PlaylistImporter.importURLs([utf16]) }
        }
    }

    @Test func cancellationStopsBeforeImport() throws {
        #expect(throws: CancellationError.self) {
            try PlaylistImporter.importURLs([URL(fileURLWithPath: "/unavailable.flac")], isCancelled: { true })
        }
    }

    @Test func legacyM3UWarnsAboutEncodingAndWindowsPath() throws {
        try fixture { root in
            let list = root.appendingPathComponent("old.m3u")
            try Data([0x43, 0x3a, 0x5c, 0x4d, 0x75, 0x73, 0x69, 0x63, 0x5c, 0xe9, 0x2e, 0x6d, 0x70, 0x33, 0x0a]).write(to: list)
            let result = try PlaylistImporter.importURLs([list])
            #expect(result.playlists[0].files.count == 1)
            #expect(result.warnings.count >= 2)
        }
    }

    @Test func oversizedPlaylistIsRejectedBeforeLoading() throws {
        try fixture { root in
            let list = try write(root, "huge.xml")
            let handle = try FileHandle(forWritingTo: list)
            try handle.truncate(atOffset: 70 * 1024 * 1024)
            try handle.close()
            #expect(throws: (any Error).self) { try PlaylistImporter.importURLs([list]) }
        }
    }

    @Test func xmlDepthLimitAndCancellationDuringParsing() throws {
        try fixture { root in
            let deep = try write(root, "deep.nml", "<NML>" + String(repeating: "<NODE>", count: 150) + String(repeating: "</NODE>", count: 150) + "</NML>")
            #expect(throws: (any Error).self) { try PlaylistImporter.importURLs([deep]) }
            let token = ImportCheckBudget()
            let normal = try write(root, "normal.nml", "<NML><COLLECTION>" + String(repeating: "<ENTRY/>", count: 100) + "</COLLECTION></NML>")
            #expect(throws: CancellationError.self) { try PlaylistImporter.importURLs([normal], isCancelled: { token.check() }) }
        }
    }

    @Test func traktorDiscoveryPrefersNewestCollectionThenNaturalVersion() throws {
        try fixture { root in
            let old = try write(root, "Native Instruments/Traktor 4.2.0/collection.nml", "<NML/>")
            let new = try write(root, "Native Instruments/Traktor 4.10.0/collection.nml", "<NML/>")
            let recent = try write(root, "Native Instruments/Traktor 3.0.0/collection.nml", "<NML/>")
            let earlier = Date(timeIntervalSince1970: 1000)
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: new.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: recent.path)
            let collections = PlaylistImporter.discoverTraktorCollections(documents: root)
            #expect(collections.map { $0.deletingLastPathComponent().lastPathComponent } == ["Traktor 3.0.0", "Traktor 4.10.0", "Traktor 4.2.0"])
        }
    }

    @Test func nmlKeepsUnresolvedPrimaryKeysForExplicitUnavailablePolicy() throws {
        try fixture { root in
            let list = try write(root, "broken.nml", "<NML><PLAYLISTS><NODE TYPE=\"0\" NAME=\"Mix\"><PLAYLIST><ENTRY/><ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\"/></ENTRY></PLAYLIST></NODE></PLAYLISTS></NML>")
            let result = try PlaylistImporter.importURLs([list])
            #expect(result.playlists[0].files.isEmpty)
            #expect(result.playlists[0].unavailable.count == 2)
            #expect(result.playlists[0].unavailable.allSatisfy { $0.contains("PRIMARYKEY") && $0.contains("Mix") })
            #expect(result.warnings.contains { $0.contains("PRIMARYKEY") })
        }
    }

    @Test func collectionOnlyImportKeepsMalformedEntriesUnavailable() throws {
        try fixture { root in
            let nml = try write(root, "broken-collection.nml", "<NML><COLLECTION><ENTRY/></COLLECTION></NML>")
            let xml = try write(root, "broken-collection.xml", "<DJ_PLAYLISTS><COLLECTION><TRACK TrackID=\"777\"/></COLLECTION></DJ_PLAYLISTS>")
            let nmlResult = try PlaylistImporter.importURLs([nml])
            let xmlResult = try PlaylistImporter.importURLs([xml])
            #expect(nmlResult.playlists[0].unavailable.count == 1)
            #expect(nmlResult.playlists[0].unavailable.first?.contains("LOCATION") == true)
            #expect(xmlResult.playlists[0].unavailable.count == 1)
            #expect(xmlResult.playlists[0].unavailable.first?.contains("777") == true)
        }
    }
}

private final class ImportCheckBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func check() -> Bool { lock.withLock { count += 1; return count >= 12 } }
}
