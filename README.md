# Setcheck

**English** · [Русский](README.ru.md)

Native macOS utility that prepares a DJ playlist for a manual YouTube copyright
check: a small MP4 with a still image, a timestamped tracklist, and a description
ready to paste into YouTube Studio.

Setcheck prepares files locally. YouTube performs Content ID checks after you
upload them. A successful check is not copyright clearance or a guarantee against
future claims. Setcheck has no affiliation with YouTube or Google.

## What it does

- Imports Traktor NML, M3U/M3U8, rekordbox XML, audio files and folders.
- Reads the latest discovered Traktor collection and lets you select playlists.
  Multi-playlist imports start unselected, so a whole collection is not exported accidentally.
- Preserves playlist order and supports separate videos or a combined set.
- Defaults to **180 seconds from the middle of each track** and **AAC 384 kbps,
  48 kHz**, using float32 intermediate audio. Full tracks and 192 kbps are optional.
- Produces 640 × 360, 1 fps H.264 video with a dark image or your own JPEG/PNG.
- Counts decoded PCM samples to create timestamps, rather than adding nominal
  file durations. No crossfades or gaps are added between tracks.
- Splits long selections at track boundaries, below 11h54m and the description
  budget. Exceptionally long tracks are split across videos to include all audio.
- Removes repeated paths; optional artist/title/duration deduplication is enabled
  by default within each playlist or combined set. Reports every removed duplicate.
- Stops on unavailable tracks by default. Skipping requires an explicit option.
- Supports progress, cancellation, Finder actions and copying the tracklist.
- Never modifies music files, Traktor collections or rekordbox databases.

The interface is currently in Russian. Some file formats supported by the bundled
FFmpeg include FLAC, WAV, AIFF, MP3, M4A, OGG and Opus.

## Install and use

Open `dist/Setcheck-1.0.0-macos-arm64.pkg`, then launch **Setcheck** from Applications
or Spotlight. No terminal, Python or Homebrew is needed to run the packaged app.
The app has an ad-hoc signature; the PKG is unsigned and not Apple-notarized.

The **current local Apple Silicon installer requires macOS 26 or later**, because
its bundled FFmpeg libraries target macOS 26. The Swift source targets macOS 14+;
other builds derive their actual minimum OS from all bundled libraries.

1. Drop a playlist, files or folders into the window, or use **⌘O** / **Из Traktor**.
2. Select playlists and options. Click **Подготовить** and inspect the parts/warnings.
3. Click **Экспортировать**. Output defaults to `~/Movies/Setcheck`.
4. Each completed directory contains `video.mp4`, `tracklist.txt`,
   `description.txt` and `report.txt`. Existing exports are never overwritten.
5. Upload the MP4 manually in [YouTube Studio](https://studio.youtube.com/), paste
   `description.txt`, select **Private**, and wait for **Checks**. Match any claim's
   timestamp to the tracklist, then revisit the video's restrictions later.

A fragment only checks that part of a track. Select full tracks to submit the
whole audio. YouTube requires verification for uploads over 15 minutes and has a
12-hour/256 GB upload limit. Descriptions are limited to 5,000 characters; Setcheck
also caps UTF-8 bytes conservatively. Timestamps restart at zero in each video.

- [YouTube upload and Checks documentation](https://support.google.com/youtube/answer/57407?hl=en)
- [YouTube upload duration and verification](https://support.google.com/youtube/answer/71673?hl=en)

## Build and test

Requires macOS, Swift 6+, Python 3, Command Line Tools or Xcode, and FFmpeg/ffprobe
on the build machine:

```sh
brew install ffmpeg
scripts/test.sh
scripts/build-installer.sh
open dist/Setcheck.app
```

`build-app.sh` bundles FFmpeg, ffprobe and their non-system dylibs, rewrites loader
paths on copies, preserves third-party notices, and signs the resulting app
locally. The original runtime installation is not modified. To package an existing
app without rebuilding: `scripts/build-installer.sh --skip-build`.

Tests cover import order, malformed XML and external entities, missing references,
deduplication, splitting, real short H.264/AAC exports, PCM-based timestamps,
custom covers, cancellation, failure cleanup, and no-overwrite publication. Tests
use synthetic audio, not personal music. Runtime/build data and generated media
are excluded from Git.

## Publish source

Create a GitHub repository and push `main`, or run `scripts/publish.sh` with an
authenticated `gh` CLI. The script targets `mrzenxxx/setcheck`. Public redistribution
of installers containing third-party runtimes requires their corresponding source
and license compliance; see [THIRD_PARTY.md](THIRD_PARTY.md).

## License

Setcheck's Swift code and build scripts: [MIT](LICENSE), © 2026 Archi Gene.
Bundled FFmpeg and codecs have separate licenses; see [THIRD_PARTY.md](THIRD_PARTY.md).
