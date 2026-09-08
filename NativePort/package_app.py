#!/usr/bin/env python3
"""Build an engine-only app and matching source archive; never bundle owned game data."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import tarfile
import zipfile
import hashlib

root = pathlib.Path(__file__).resolve().parent.parent
build = root / '.porting/SurrealEngine/build'
dist = root / 'dist'
dist.mkdir(exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix='deusex-package-', dir=dist)
release = pathlib.Path(staging.name) / 'Deus Ex Mac'
app = release / 'Deus Ex.app'
game_folder = release / 'Put game files here'
game_folder.mkdir(parents=True)
(game_folder / 'READ ME.txt').write_text(
    'Copy the contents of your installed Deus Ex GOTY game into this folder.\n'
    'System, Maps, Textures, Sounds and Music must be directly inside this folder.\n'
    'Then open Deus Ex.app beside this folder. Keep the app and this folder together.\n'
    'No original game files are included.\n')
shutil.copy2(root / 'NativePort/INSTALL.md', release / 'READ ME.txt')
contents = app / 'Contents'
macos = contents / 'MacOS'
resources = contents / 'Resources'
frameworks = contents / 'Frameworks'
for folder in (macos, resources, frameworks):
    folder.mkdir(parents=True, exist_ok=True)

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

engine = macos / 'SurrealEngine'
shutil.copy2(build / 'SurrealEngine.app/Contents/MacOS/SurrealEngine', engine)
shutil.copy2(build / 'SurrealEngine.pk3', resources)
for source in (build / 'libSurrealVideo.dylib', build / 'Thirdparty/openal-soft/libopenal.1.dylib', pathlib.Path('/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib')):
    target = frameworks / source.name
    if target.exists():
        target.chmod(target.stat().st_mode | 0o200)
    shutil.copy2(source, target)
run('install_name_tool', '-change', '/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib', '@rpath/libSDL3.0.dylib', engine)
run('install_name_tool', '-id', '@rpath/libSDL3.0.dylib', frameworks / 'libSDL3.0.dylib')
lines = subprocess.check_output(['otool', '-l', str(engine)], text=True).splitlines()
for i, line in enumerate(lines):
    if line.strip() == 'cmd LC_RPATH':
        path = lines[i + 2].strip().split(' (offset')[0].removeprefix('path ')
        if path != '@executable_path/../Frameworks':
            run('install_name_tool', '-delete_rpath', path, engine)

info = dict(CFBundleExecutable='SurrealEngine', CFBundleIdentifier='local.deusex.native',
            CFBundleName='Deus Ex', CFBundleDisplayName='Deus Ex', CFBundlePackageType='APPL',
            CFBundleShortVersionString='0.1', CFBundleVersion='6', LSMinimumSystemVersion='27.0',
            NSHighResolutionCapable=True, NSSupportsAutomaticGraphicsSwitching=True,
            LSApplicationCategoryType='public.app-category.role-playing-games',
            LSSupportsGameMode=True, GCSupportsGameMode=True, GCSupportsControllerUserInteraction=True)
with (contents / 'Info.plist').open('wb') as output:
    plistlib.dump(info, output)
source_root = root / '.porting/SurrealEngine'
licenses = resources / 'Licenses'
for source in source_root.rglob('*'):
    if source.is_file() and source.name.lower().startswith(('license', 'copying')) and not any(p in {'build', '.git'} for p in source.relative_to(source_root).parts):
        target = licenses / source.relative_to(source_root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
shutil.copy2('/opt/homebrew/opt/sdl3/LICENSE.txt', licenses / 'SDL3-LICENSE.txt')
shutil.copy2(root / 'NativePort/INSTALL.md', resources / 'Read Me.txt')
for binary in [*frameworks.iterdir(), engine]:
    run('codesign', '--force', '--sign', '-', binary)
run('codesign', '--force', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
run('plutil', '-lint', contents / 'Info.plist')
# Reject proprietary game data and links before creating a distributable archive.
for file in app.rglob('*'):
    assert not file.is_symlink(), file
    assert file.suffix.lower() not in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.ini'}, file
for binary in [*frameworks.iterdir(), engine]:
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(' (')[0]
        assert dependency.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/', '/usr/lib/')), dependency
archive = dist / 'Deus-Ex-Mac-ARM64.zip'
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', release, archive)
with zipfile.ZipFile(archive) as zipped:
    names = zipped.namelist()
    assert 'Deus Ex Mac/Put game files here/READ ME.txt' in names
    assert not any(pathlib.PurePosixPath(n).suffix.lower() in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.ini'} for n in names)
    assert not any('/Game/' in n for n in names)
# Include the exact modified engine sources, LGPL libraries and build files.
if (source_root / '.git').exists():
    files = subprocess.check_output(['git', '-C', str(source_root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
else:
    # Extracted source releases do not require a Git checkout.
    files = [str(p.relative_to(source_root)) for p in source_root.rglob('*') if p.is_file()
             and not {'build', '.git', '__pycache__'}.intersection(p.relative_to(source_root).parts)]
source_archive = dist / 'Deus-Ex-Mac-Source.tar.gz'
with tarfile.open(source_archive, 'w:gz') as tar:
    for name in sorted(set(files)):
        if not name: continue
        source = source_root / name
        if source.is_file():
            assert source.suffix.lower() not in {'.exe', '.dll', '.u', '.dx', '.utx', '.uax', '.umx', '.o', '.a', '.dylib'}, source
            tar.add(source, arcname=str(pathlib.Path('Deus-Ex-Mac/.porting/SurrealEngine') / name), recursive=False)
    for name in ('package_launcher.mm', 'game_install.h', 'package_app.py', 'check_install.cpp', 'check_install.py', 'INSTALL.md'):
        tar.add(root / 'NativePort' / name, arcname='Deus-Ex-Mac/NativePort/' + name)
shutil.copy2(root / 'NativePort/INSTALL.md', dist / 'INSTALL.md')
(dist / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in (archive, source_archive)))
installed_release = dist / 'Deus Ex Mac'
installed_release.mkdir(exist_ok=True)
# Preserve any game files the user has added when rebuilding locally.
shutil.copytree(game_folder, installed_release / game_folder.name, dirs_exist_ok=True)
shutil.copy2(release / 'READ ME.txt', installed_release / 'READ ME.txt')
installed_app = installed_release / 'Deus Ex.app'
if installed_app.exists(): shutil.rmtree(installed_app)
shutil.move(app, installed_app)
staging.cleanup()
print(archive)
print(source_archive)
