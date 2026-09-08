#!/usr/bin/env python3
"""Run input checks against the built engine and original package layouts, without a game window."""
import pathlib
import shlex
import subprocess
import tempfile
import sys
import shutil
root = pathlib.Path(__file__).resolve().parent.parent
build = root / '.porting/SurrealEngine/build'
assets = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else root
commands = subprocess.check_output(['ninja', '-C', str(build), '-t', 'commands', 'SurrealEngine'], text=True).splitlines()
with tempfile.TemporaryDirectory(prefix='deusex-input-') as scratch:
    obj = str(pathlib.Path(scratch) / 'check.o')
    exe = str(pathlib.Path(scratch) / 'check')
    compile_args = shlex.split(next(c for c in commands if ' -c ' in c and '/MainGame.cpp' in c))
    compile_args[compile_args.index('-o') + 1] = obj
    compile_args[compile_args.index('-c') + 1] = str(root / 'NativePort' / (sys.argv[1] if len(sys.argv) > 1 else 'check_input.cpp'))
    if '-MF' in compile_args:
        compile_args[compile_args.index('-MF') + 1] = obj + '.d'
    compile_args.append('-UNDEBUG')
    if compile_args[compile_args.index('-c') + 1].endswith('.mm'): compile_args.append('-fobjc-arc')
    subprocess.run(compile_args, cwd=build, check=True)
    link = shlex.split(commands[-1].split(' && ')[1])
    link = [obj if arg.endswith('/MainGame.cpp.o') else arg for arg in link]
    link[link.index('-o') + 1] = exe
    subprocess.run(link, cwd=build, check=True)
    game = pathlib.Path(scratch) / 'game'
    (game / 'System').mkdir(parents=True)
    (game / 'Save').mkdir()
    for name in ('Maps', 'Sounds', 'Music', 'Textures'):
        (game / name).symlink_to(assets / name)
    for source in (assets / 'System').iterdir():
        if source.is_file():
            target = game / 'System' / source.name
            if source.suffix.lower() == '.ini': shutil.copy2(source, target)
            else: target.symlink_to(source)
    subprocess.run([exe, str(game)], cwd=build, check=True)
