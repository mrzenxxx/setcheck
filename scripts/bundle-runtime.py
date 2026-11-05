#!/usr/bin/env python3
"""Bundle the installed FFmpeg executables and their dylib closure; never modify originals."""
import json, os, pathlib, re, shutil, subprocess, sys

app = pathlib.Path(sys.argv[1]).resolve()
helpers = app / 'Contents/Helpers'
frameworks = app / 'Contents/Frameworks'
notices = app / 'Contents/Resources/ThirdParty'
for directory in (helpers, frameworks, notices):
    directory.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def dependencies(source):
    return [line.strip().split(' (', 1)[0] for line in run('otool', '-L', str(source)).splitlines()[1:]]

sources = {}
queue = []
for tool in ('ffmpeg', 'ffprobe'):
    candidate = os.environ.get('SETCHECK_' + tool.upper()) or shutil.which(tool)
    if not candidate:
        raise SystemExit(f'{tool} is needed to build the app. Install FFmpeg for the build machine.')
    source = pathlib.Path(candidate).resolve()
    sources[source] = helpers / tool
    queue.append(source)

system = ('/usr/lib/', '/System/Library/')
index = 0
while index < len(queue):
    source = queue[index]
    index += 1
    for dependency in dependencies(source):
        if dependency.startswith(system):
            continue
        if dependency.startswith('@'):
            candidates = [source.parent / dependency.split('/')[-1], source.parent.parent / 'lib' / dependency.split('/')[-1]]
            found = next((p for p in candidates if p.exists()), None)
            if found is None:
                raise SystemExit(f'Cannot resolve {dependency} from {source}')
            resolved = found.resolve()
        else:
            resolved = pathlib.Path(dependency).resolve()
        if resolved == source:
            continue
        if not resolved.is_file():
            raise SystemExit(f'Missing runtime library: {dependency}')
        if resolved not in sources:
            target = frameworks / resolved.name
            if target in sources.values():
                raise SystemExit(f'Runtime library name collision: {resolved.name}')
            sources[resolved] = target
            queue.append(resolved)

minimum = (14, 0)
packages = {}
architecture = run('uname', '-m')
for source, target in sources.items():
    if architecture not in run('lipo', '-archs', str(source)).split():
        raise SystemExit(f'Incompatible architecture: {source}')
    shutil.copyfile(source, target)
    target.chmod(0o755)
    subprocess.run(['codesign', '--remove-signature', str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    loads = run('otool', '-l', str(source))
    versions = re.findall(r'\bminos\s+([0-9.]+)', loads)
    if not versions:
        versions = re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', loads)
    for version in versions:
        minimum = max(minimum, tuple(map(int, version.split('.'))))
    # Record the exact Homebrew formula, licenses and build receipt for local builds.
    parts = source.parts
    if 'Cellar' in parts:
        at = parts.index('Cellar')
        root = pathlib.Path(*parts[:at+3])
        packages[str(root)] = root

for source, target in sources.items():
    for dependency in dependencies(source):
        if dependency.startswith(system):
            continue
        if dependency.startswith('@'):
            candidates = [source.parent / dependency.split('/')[-1], source.parent.parent / 'lib' / dependency.split('/')[-1]]
            found = next((p for p in candidates if p.exists()), None)
            if found is None:
                raise SystemExit(f'Cannot resolve {dependency}')
            resolved = found.resolve()
        else:
            resolved = pathlib.Path(dependency).resolve()
        if resolved == source:
            continue
        destination = sources[resolved]
        relative = os.path.relpath(destination, target.parent)
        subprocess.run(['install_name_tool', '-change', dependency, '@loader_path/' + relative, str(target)], check=True)
    if target.parent == frameworks:
        subprocess.run(['install_name_tool', '-id', '@rpath/' + target.name, str(target)], check=True)
    for dep in dependencies(target):
        if not dep.startswith(system + ('@loader_path/', '@rpath/')):
            raise SystemExit(f'External runtime link remains in {target}: {dep}')
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)

manifest = {'minimum_macos': '.'.join(map(str, minimum)), 'architecture': architecture, 'libraries': len(sources)-2, 'packages': []}
for root in packages.values():
    package = root.parent.name
    destination = notices / (package + '-' + root.name)
    destination.mkdir(exist_ok=True)
    candidates = list(root.glob('*LICENSE*')) + list(root.glob('*LICENCE*')) + list(root.glob('*COPYING*')) + list((root / '.brew').glob('*.rb'))
    candidates += list((root / 'share/licenses').rglob('*')) if (root / 'share/licenses').exists() else []
    for path in candidates:
        if path.is_file() and path.stat().st_size < 2_000_000:
            shutil.copyfile(path, destination / path.name)
    receipt = root / 'INSTALL_RECEIPT.json'
    if receipt.exists():
        data = json.loads(receipt.read_text())
        # Retain build flags and versions without the build user's local paths.
        data.pop('source', None)
        (destination / 'build-receipt.json').write_text(json.dumps(data, indent=2))
    manifest['packages'].append({'name': package, 'version': root.name})
(notices / 'runtime.json').write_text(json.dumps(manifest, indent=2))
(notices / 'README.txt').write_text('Setcheck runs FFmpeg as a separate process. The bundled local runtime has its own licenses.\nExact versions, original Homebrew source recipes and license texts are in this directory.\nFFmpeg: https://ffmpeg.org/ — sources: https://ffmpeg.org/releases/\nWhen redistributing runtime binaries, provide their corresponding sources and build instructions as required by their licenses.\n')
# Verify bundled executables work without the build machine's dynamic-loader environment.
environment = {k:v for k,v in os.environ.items() if not k.startswith('DYLD_')}
for tool in ('ffmpeg', 'ffprobe'):
    subprocess.run([str(helpers / tool), '-version'], env=environment, check=True, stdout=subprocess.DEVNULL)
print(json.dumps(manifest))
