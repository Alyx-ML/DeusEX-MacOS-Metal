#!/usr/bin/env python3
"""Exercise the same install preparation code used by the Cocoa folder picker."""
import pathlib
import subprocess
import shlex
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
engine = root / '.porting/SurrealEngine'
assets = pathlib.Path(sys.argv[1]).resolve()
# Snapshot metadata recursively without writing to the owned installation.
def snapshot():
    return {str(p): (p.stat().st_size, p.stat().st_mtime_ns) for folder in ('System', 'Maps', 'Sounds', 'Textures', 'Music', 'Save') for p in (assets / folder).rglob('*') if p.is_file()}
before = snapshot()
with tempfile.TemporaryDirectory(prefix='deusex-install-check-') as temp:
    binary = pathlib.Path(temp) / 'check_install'
    commands = subprocess.check_output(['ninja', '-t', 'commands', 'SurrealEngine'], cwd=engine / 'build', text=True)
    obj = pathlib.Path(temp) / 'check.o'
    compile_args = shlex.split(next(c for c in commands.splitlines() if ' -c ' in c and '/MainGame.cpp' in c))
    compile_args[compile_args.index('-o')+1] = str(obj)
    compile_args[compile_args.index('-c')+1] = str(root / 'NativePort/check_install.cpp')
    if '-MF' in compile_args: compile_args[compile_args.index('-MF')+1] = str(obj) + '.d'
    compile_args.append('-UNDEBUG')
    subprocess.run(compile_args, cwd=engine / 'build', check=True)
    link = shlex.split(commands.splitlines()[-1].split('&&')[1])
    link[link.index('CMakeFiles/SurrealEngine.dir/SurrealEngine/MainGame.cpp.o')] = str(obj)
    link[link.index('-o')+1] = str(binary)
    subprocess.run(link, cwd=engine / 'build', check=True)
    subprocess.run([str(binary), str(assets), temp], check=True)
assert snapshot() == before, 'Source installation was modified'
print('PASS: original installation unchanged')
