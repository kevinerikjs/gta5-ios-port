"""Prepare a reproducible native CPU boot experiment from the local mirror."""
import argparse
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--mirror', type=Path, required=True, help='folder containing data/ and b/8b0b5899ed/game.wasm')
parser.add_argument('--prebuilt-dawn', action='store_true', help=argparse.SUPPRESS)  # accepted for old scripts; Dawn is no longer used
parser.add_argument('--sdk', action='append', choices=['iphoneos', 'iphonesimulator'], help='Metal library to build (default: iphoneos)')
options = parser.parse_args()
def apple_silicon():
    try: return subprocess.run(['sysctl', '-n', 'hw.optional.arm64'], capture_output=True, text=True).stdout.strip() == '1'
    except OSError: return False
if platform.system() != 'Darwin' or not apple_silicon():
    raise SystemExit('This preparation script targets an Apple Silicon Mac with Xcode.')
engine = options.mirror / 'b/8b0b5899ed/game.wasm'
if hashlib.sha256(engine.read_bytes()).hexdigest() != '11ca8d2c04c5e843d18ff4aea4899d72c86973c6b031df334e67c446b2ae83e0':
    raise SystemExit('The engine does not match the build this native experiment supports.')
for name in ['Tools', 'Generated', 'Build', 'Resources']:
    (root / name).mkdir(exist_ok=True)

def run(*args):
    subprocess.run(args, cwd=root, check=True)

def download(url, destination):
    with urllib.request.urlopen(url) as response:
        destination.write_bytes(response.read())

wabt = root / 'Tools/wabt-1.0.42'
if not wabt.exists():
    release = 'https://github.com/WebAssembly/wabt/releases/download/1.0.42/'
    filename = 'wabt-1.0.42-macos-arm64.tar.gz'
    archive = root / 'Tools/wabt.tar.gz'
    download(release + filename, archive)
    checksum = urllib.request.urlopen(release + filename + '.sha256').read().decode().split()[0]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise SystemExit('WABT archive checksum mismatch.')
    from safe_extract import extract
    with tarfile.open(archive) as package:
        extract(package, root / 'Tools')

simde = root / 'Tools/simde'
if not simde.exists():
    run('git', 'clone', '--depth', '1', '--branch', 'v0.8.2', 'https://github.com/simd-everywhere/simde.git', str(simde))
for upstream, local in [('src/c-writer.cc', 'c-writer-original.cc'), ('src/tools/wasm2c.cc', 'wasm2c-main.cc')]:
    destination = root / 'Tools' / local
    if not destination.exists():
        download('https://raw.githubusercontent.com/WebAssembly/wabt/1.0.42/' + upstream, destination)
run('python3', 'Scripts/patch_wasm2c.py')
run('xcrun', 'clang', '-Wno-deprecated-declarations', '-c', 'Scripts/sha256_shim.c', '-o', 'Tools/sha256_shim.o')
run('xcrun', 'clang++', '-std=c++20', '-O1', '-I', str(wabt / 'include'),
    'Tools/wasm2c-main.cc', 'Tools/c-writer-patched.cc', 'Tools/sha256_shim.o',
    str(wabt / 'lib/libwabt.a'), '-o', 'Tools/wasm2c-native')
run('Tools/wasm2c-native', '--enable-threads', '--no-debug-names', '--module-name=game',
    '--num-outputs=64', str(engine), '-o', 'Generated/game.c')
# Function names from the engine's name section: the patchers below find their functions by name.
run('python3', 'Scripts/engine_names.py', '--wasm', str(engine))
runtime = wabt / 'share/wabt/wasm2c/wasm-rt-impl.c'
text = runtime.read_text()
if 'pg_record_trap' not in text:
    text = text.replace('void wasm_rt_trap(wasm_rt_trap_t code) {',
        'extern void pg_record_trap(int) __attribute__((weak));\nvoid wasm_rt_trap(wasm_rt_trap_t code) {\n  if(pg_record_trap)pg_record_trap(code);')
    runtime.write_text(text)
run('python3', 'Scripts/generate_imports.py')
run('python3', 'Scripts/prepare_heap_diagnostics.py')
run('python3', 'Scripts/prepare_memory_pressure.py')
shutil.copyfile(options.mirror / 'data/manifest.json', root / 'Resources/manifest.json')
run('python3', 'Scripts/prepare_virtual_pad.py')
run('python3', 'Scripts/prepare_script_menu.py')
run('python3', 'Scripts/prepare_movie_wait.py')
run('python3', 'Scripts/prepare_tv_without_video.py')
run('python3', 'Scripts/prepare_missing_txd.py')
run('python3', 'Scripts/prepare_missing_scaleform.py')
run('python3', 'Scripts/prepare_unchecked_memory.py')
run('python3', 'Scripts/prepare_trap_context.py')
run('python3', 'Scripts/prepare_scenario_blockers.py')
run('python3', 'Scripts/prepare_level_index.py')
run('python3', 'Scripts/prepare_fixup_guard.py')
run('python3', 'Scripts/prepare_format_strings.py')
run('python3', 'Scripts/prepare_video_memory.py')
run('python3', 'Scripts/prepare_plain_dsp.py')
run('python3', 'Scripts/prepare_cash_stats.py')
run('python3', 'Scripts/prepare_native_opus.py')
run('python3', 'Scripts/prepare_render_list_guard.py')
run('python3', 'Scripts/prepare_stale_texture_slots.py')
run('python3', 'Scripts/prepare_control_trace.py')
run('python3', 'Scripts/prepare_pause_ready.py')
run('python3', 'Scripts/prepare_heap_return.py')
run('python3', 'Scripts/prepare_memory_file_create.py')
run('python3', 'Scripts/prepare_longjmp.py')
# The BC texture decoder header (MIT): phones without BC texture support get decoded textures.
bcdec = root / 'Tools/bcdec'
if not bcdec.exists():
    commit = '80859ed3b7afb1c527a2a99d70c61457bea72d0c'
    archive = root / 'Tools/bcdec.tar.gz'
    download(f'https://codeload.github.com/iOrange/bcdec/tar.gz/{commit}', archive)
    from safe_extract import extract
    with tarfile.open(archive) as package:
        extract(package, root / 'Tools')
    (root / 'Tools' / f'bcdec-{commit}').rename(bcdec)
# The game's shaders, precompiled into the app's Metal library.
run('python3', 'Scripts/fetch_shader_tool.py')
shaders = root / 'Build/Inputs/shaders'
run('python3', 'Scripts/unpack_shaders.py', '--shaders', str((options.mirror / 'b/8b0b5899ed/shaders').resolve()), '--out', str(shaders))
sdk_args = []
for sdk in options.sdk or ['iphoneos']:
    sdk_args += ['--sdk', sdk]
run('python3', 'Scripts/build_metal_shaders.py', str(shaders), *sdk_args)
run('python3', 'Scripts/build_opus.py', *sdk_args)
run('xcodegen', 'generate', '--spec', 'project.yml')
print('Prepared the native boot project. Open PlayGTA5Native.xcodeproj in Xcode.')
