# Third-party runtime

Setcheck's Swift source code is MIT licensed. It invokes FFmpeg and ffprobe as
separate programs. FFmpeg, its libraries and codecs retain their own licenses;
the MIT license does not replace them.

The local build script copies the installed FFmpeg executables and all non-system
dylibs into the app, rewrites loader paths on the copies, and ad-hoc signs them.
Original installations are never modified. The resulting app needs no Homebrew
or Python at runtime. Python and Swift are only build tools.

The build collects license files, the exact package versions, Homebrew source
recipes (including source URLs/checksums) and sanitized build receipts in
`Setcheck.app/Contents/Resources/ThirdParty/`. Its minimum macOS version is derived
from all bundled Mach-O files, rather than assumed from the Swift target alone.

The installed Homebrew FFmpeg may include GPL components such as libx264. A
locally generated app/installer is for the builder's own use. Before publicly
redistributing such binaries, also provide their corresponding sources and build
instructions and comply with every bundled component's license. This repository
contains source code and bundling scripts; prebuilt third-party binaries and
personal media are excluded from Git.

- FFmpeg licensing: https://ffmpeg.org/legal.html
- FFmpeg source releases: https://ffmpeg.org/releases/
- Homebrew formulas and source/build recipes: https://github.com/Homebrew/homebrew-core
