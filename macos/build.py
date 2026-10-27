"""Build the native macOS app around a verified existing AutoOrtho engine bundle.

Run using the Python environment that built the engine (matching marshal ABI).
Only its entry dispatcher changes; all engine modules remain byte-identical.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import io
import json
import marshal
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import zlib

from PyInstaller.archive.readers import CArchiveReader
from PyInstaller.archive.writers import CArchiveWriter
from PyInstaller.utils.osx import remove_signature_from_binary, fix_exe_for_code_signing

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_sections(path):
    """Compare code/data sections while allowing bundler rpath/signature edits."""
    data = path.read_bytes()
    assert data[:4] == b'\xcf\xfa\xed\xfe', 'Expected arm64 Mach-O'
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    result = {}
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            sections = struct.unpack_from('<I', data, offset + 64)[0]
            for index in range(sections):
                start = offset + 72 + 80 * index
                name = data[start:start + 16].split(b'\0')[0].decode()
                segment = data[start + 16:start + 32].split(b'\0')[0].decode()
                size, position = struct.unpack_from('<QI', data, start + 40)
                if position and size:
                    result[f'{segment}/{name}'] = hashlib.sha256(data[position:position + size]).hexdigest()
        offset += length
    assert '__TEXT/__text' in result
    return result


def build(engine_app, destination):
    engine_app = engine_app.resolve()
    destination = destination.resolve()
    embedded_engine = engine_app / 'Contents/Resources/Engine.app'
    if embedded_engine.is_dir():
        engine_app = embedded_engine
    assert engine_app != destination and engine_app not in destination.parents
    source_executable = engine_app / 'Contents/MacOS/autoortho'
    original = CArchiveReader(str(source_executable))
    pyz = original.open_embedded_archive('PYZ.pyz')
    # These are the local fixes published before native UI work began.
    modules = {'aoconfig': 'aoconfig.py', 'autoortho': 'autoortho.py',
               'autoortho_fuse': 'autoortho_fuse.py', 'getortho': 'getortho.py',
               'pydds': 'pydds.py', 'dds_manifest': 'dds_manifest.py',
               'macsetup': 'macsetup.py', 'ui.main_window': 'ui/main_window.py'}
    for module, relative in modules.items():
        code = pyz.extract(module)
        assert code == compile((REPO / 'autoortho' / relative).read_text(), code.co_filename, 'exec'), module
    native_library = Path('Contents/Frameworks/autoortho/aopipeline/lib/macos/libaopipeline.dylib')
    assert native_sections(engine_app / native_library) == native_sections(REPO / 'autoortho/aopipeline/lib/macos/libaopipeline.dylib')
    if destination.exists():
        raise FileExistsError('Choose a fresh --output path, or quit and remove the previous candidate first: ' + str(destination))
    resources = destination / 'Contents/Resources'
    binary_dir = destination / 'Contents/MacOS'
    resources.mkdir(parents=True); binary_dir.mkdir()
    helper = resources / 'Engine.app'
    shutil.copytree(engine_app, helper, symlinks=True)
    helper_info_path = helper / 'Contents/Info.plist'
    helper_info = plistlib.loads(helper_info_path.read_bytes())
    helper_info.update(CFBundleIdentifier='com.autoortho.engine',
                       CFBundleName='AutoOrtho Engine', CFBundleDisplayName='AutoOrtho Engine',
                       LSUIElement=True)
    helper_info_path.write_bytes(plistlib.dumps(helper_info))
    helper_executable = helper / 'Contents/MacOS/autoortho'

    # Append the bridge without recompressing unrelated engine modules.
    source_pyz = original.extract('PYZ.pyz')
    output_pyz = io.BytesIO()
    header_length = min(entry[1] for entry in pyz.toc.values() if entry[2])
    output_pyz.write(source_pyz[:header_length])
    toc = []
    for name, (kind, offset, length) in pyz.toc.items():
        if name == 'native_service':
            continue
        payload = source_pyz[offset:offset + length]
        toc.append((name, (kind, output_pyz.tell(), len(payload))))
        output_pyz.write(payload)
    service = compile((REPO / 'autoortho/native_service.py').read_text(), 'native_service.py', 'exec')
    payload = zlib.compress(marshal.dumps(service), 6)
    toc.append(('native_service', (0, output_pyz.tell(), len(payload))))
    output_pyz.write(payload)
    toc_start = output_pyz.tell(); output_pyz.write(marshal.dumps(toc))
    output_pyz.seek(8); output_pyz.write(struct.pack('!i', toc_start))
    new_pyz = output_pyz.getvalue()

    saved_entry = engine_app / 'Contents/Resources/engine-entry.marshal'
    if saved_entry.exists():
        entry = saved_entry.read_bytes()
    else:
        assert 'native_service' not in pyz.toc, 'This earlier test helper has no saved engine entry; use the original engine bundle.'
        entry = original.extract('__main__')
    # Retain one original bootstrap so rebuilds never accumulate dispatch wrappers.
    (helper / 'Contents/Resources/engine-entry.marshal').write_bytes(entry)
    dispatch = f'''import sys, multiprocessing, marshal, base64
if getattr(sys, 'frozen', False):
    multiprocessing.freeze_support()
if '--native-ui-service' in sys.argv:
    import native_service
    native_service.main()
else:
    if '--native-engine' in sys.argv:
        sys.argv.remove('--native-engine')
        sys.argv.append('--headless')
        import native_service
        native_service.install_flight_routes()
    exec(marshal.loads(base64.b64decode({base64.b64encode(entry).decode()!r})), globals())
'''
    new_entry = marshal.dumps(compile(dispatch, '__main__.py', 'exec'))
    remove_signature_from_binary(str(helper_executable))
    unsigned = CArchiveReader(str(helper_executable))
    executable_bytes = helper_executable.read_bytes()
    archive = io.BytesIO(); archive_toc = []
    for option in original.options:
        archive_toc.append((0, 0, 0, 0, 'o', option))
    for name, (offset, length, raw_length, compressed, kind) in unsigned.toc.items():
        data = executable_bytes[unsigned._start_offset + offset:unsigned._start_offset + offset + length]
        replacement = new_pyz if name == 'PYZ.pyz' else new_entry if name == '__main__' else None
        if replacement is not None:
            data = zlib.compress(replacement, 9) if compressed else replacement
            raw_length = len(replacement)
        archive_toc.append((archive.tell(), len(data), raw_length, compressed, kind, name))
        archive.write(data)
    toc_start = archive.tell()
    serialized = CArchiveWriter._serialize_toc(archive_toc); archive.write(serialized)
    cookie = struct.unpack(CArchiveWriter._COOKIE_FORMAT, executable_bytes[unsigned._end_offset - CArchiveWriter._COOKIE_LENGTH:unsigned._end_offset])
    archive.write(struct.pack(CArchiveWriter._COOKIE_FORMAT, cookie[0], archive.tell() + CArchiveWriter._COOKIE_LENGTH,
                              toc_start, len(serialized), cookie[4], cookie[5]))
    helper_executable.write_bytes(executable_bytes[:unsigned._start_offset] + archive.getvalue())
    fix_exe_for_code_signing(str(helper_executable))
    subprocess.run(['codesign', '--force', '--sign', '-', str(helper)], check=True, capture_output=True)
    verified = CArchiveReader(str(helper_executable))
    verified_pyz = verified.open_embedded_archive('PYZ.pyz')
    for name in pyz.toc:
        if name == 'native_service':
            continue
        assert verified_pyz.extract(name, raw=True) == pyz.extract(name, raw=True), name
    for name in original.toc:
        if name not in {'__main__', 'PYZ.pyz'}:
            assert verified.extract(name) == original.extract(name), name
    assert verified_pyz.extract('native_service') == service

    sources = sorted(str(path) for path in (ROOT / 'Sources').glob('*.swift'))
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
               '-target', 'arm64-apple-macos14.0', '-module-cache-path', '/tmp/autoortho-native-module-cache',
               *sources, '-o', str(binary_dir / 'AutoOrtho')]
    subprocess.run(command, check=True)
    shutil.copy2(engine_app / 'Contents/Resources/ao-icon.icns', resources / 'ao-icon.icns')
    info = dict(CFBundleName='AutoOrtho', CFBundleDisplayName='AutoOrtho', CFBundleExecutable='AutoOrtho',
                CFBundleIdentifier='com.autoortho.app', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.1.0', CFBundleVersion='1', CFBundleIconFile='ao-icon.icns',
                LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
                NSHumanReadableCopyright='AutoOrtho contributors. Apache License 2.0.',
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    (destination / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(REPO / 'LICENSE.md', resources / 'LICENSE.md')
    subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    report = dict(app=str(destination), engine_source=str(engine_app),
                  source_engine_sha256=sha(source_executable), helper_sha256=sha(helper_executable),
                  preserved_engine_modules=len(pyz.toc) - int('native_service' in pyz.toc), changed_engine_modules=[],
                  added_module='native_service', signature='deep strict verification passed',
                  foundation_commit='385f1f86a968bd682e6fd484cdce150e83472b38')
    (ROOT / 'build/verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine-app', type=Path, default=Path('/Applications/AutoOrtho.app'))
    parser.add_argument('--output', type=Path, default=ROOT / 'build/AutoOrtho.app')
    args = parser.parse_args()
    (ROOT / 'build').mkdir(exist_ok=True)
    build(args.engine_app, args.output)
