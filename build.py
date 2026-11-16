#!/usr/bin/env python3
"""Build a separate repair from an original app owned by the person running this."""
import argparse
import binascii
import json
import platform
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

from patcher import UnsupportedBinary, patch_binary, verify_original

ROOT = Path(__file__).resolve().parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def validate_paths(original, output, background):
    if not original.is_dir() or original.suffix.lower() != '.app':
        raise ValueError('--original must be an existing original .app bundle.')
    if output.suffix.lower() != '.app':
        raise ValueError('--output must end in .app.')
    if output.exists() or output.is_symlink():
        raise ValueError('Output already exists; choose a new app path. Nothing was overwritten.')
    if original == output or original in output.parents:
        raise ValueError('The output must be separate from the original app.')
    if background is not None and not background.is_file():
        raise ValueError('--background must be an existing image file.')


def neutral_background(path):
    """Generate an original neutral backdrop; no system or user photo is copied."""
    width, height = 512, 512
    rows = bytearray()
    for y in range(height):
        amount = y / (height - 1)
        color = bytes((int(20 - 12 * amount), int(66 - 44 * amount), int(90 - 56 * amount)))
        rows.extend(b'\0' + color * width)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xFFFFFFFF)

    path.write_bytes(b'\x89PNG\r\n\x1a\n' +
                     chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def build(original, output, background=None):
    validate_paths(original, output, background)
    if platform.system() != 'Darwin':
        raise ValueError('Building requires macOS and Apple command-line development tools.')
    for tool in ('xcrun', 'codesign', 'sips'):
        if not shutil.which(tool):
            raise ValueError(f'Missing {tool}. Install the Apple command-line tools first.')
    info = plistlib.loads((original / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'DesktopAquarium3D' or info.get('CFBundleShortVersionString') != '1.9':
        raise ValueError('Expected the original DesktopAquarium3D v1.9 app.')
    # Validate and compile before copying or modifying any app bundle.
    with tempfile.TemporaryDirectory(prefix='aquarium-repair-') as scratch:
        scratch = Path(scratch)
        thin = scratch / 'original-x86_64'
        run('xcrun', 'lipo', original / 'Contents/MacOS/DesktopAquarium3D',
            '-thin', 'x86_64', '-output', thin)
        original_data = thin.read_bytes()
        digest = verify_original(original_data)
        patched = patch_binary(original_data)
        library = scratch / 'AquariumCompatibility.dylib'
        run('xcrun', 'clang', '-arch', 'x86_64', '-mmacosx-version-min=10.13',
            '-dynamiclib', '-fobjc-arc', '-Wno-deprecated-declarations',
            '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'OpenGL',
            '-framework', 'CoreVideo', ROOT / 'src/AquariumCompatibility.m', '-o', library)
        image = background
        if image is None:
            image = scratch / 'neutral.png'
            neutral_background(image)
        jpeg = scratch / 'AquariumBackground.jpg'
        run('sips', '-s', 'format', 'jpeg', image, '--out', jpeg)
        output.parent.mkdir(parents=True, exist_ok=True)
        # Stage on the destination filesystem; only publish after signing passes.
        with tempfile.TemporaryDirectory(prefix='.aquarium-repair-', dir=output.parent) as staging:
            app = Path(staging) / output.name
            shutil.copytree(original, app, symlinks=True)
            (app / 'Contents/MacOS/DesktopAquarium3D').write_bytes(patched)
            info.update(CFBundleIdentifier='local.aquarium.compatibility',
                        CFBundleName='Desktop Aquarium 3D Repaired',
                        CFBundleDisplayName='Desktop Aquarium 3D Repaired',
                        NSHighResolutionCapable=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            for profile in ('embedded.mobileprovision', 'Contents/embedded.provisionprofile'):
                (app / profile).unlink(missing_ok=True)
            shutil.copy2(library, app / 'Contents/MacOS/AquariumCompatibility.dylib')
            resources = app / 'Contents/Resources'
            shutil.copy2(jpeg, resources / 'AquariumBackground.jpg')
            backgrounds = resources / 'AquariumBackgrounds'
            backgrounds.mkdir(exist_ok=True)
            shutil.copy2(jpeg, backgrounds / 'background.jpg')
            manifest = {'repair': 'desktop-aquarium-3d-repair', 'input_x86_64_sha256': digest,
                        'background': 'user-supplied' if background else 'generated-neutral'}
            (resources / 'AquariumRepair.json').write_text(json.dumps(manifest, indent=2) + '\n')
            run('codesign', '--force', '--sign', '-', app / 'Contents/MacOS/AquariumCompatibility.dylib')
            run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'src/entitlements.plist', app)
            run('codesign', '--verify', '--deep', '--strict', app)
            # Recheck after the build so an existing destination is never replaced.
            if output.exists() or output.is_symlink():
                raise ValueError('Output appeared during the build; refusing to replace it.')
            app.rename(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', type=Path, default=Path('/Applications/DesktopAquarium3D.app'))
    parser.add_argument('--output', type=Path, default=ROOT / 'build/Desktop Aquarium 3D Repaired.app')
    parser.add_argument('--background', type=Path, help='Optional photo to bundle locally as the fallback wallpaper.')
    args = parser.parse_args()
    # Check the un-resolved path too, so dangling output symlinks cannot be followed.
    args.output = args.output.expanduser()
    if args.output.exists() or args.output.is_symlink():
        parser.error('Output already exists; choose a new app path.')
    try:
        output = build(args.original.expanduser().resolve(), args.output.expanduser().resolve(),
                       args.background.expanduser().resolve() if args.background else None)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Repair failed: {error}\n')
    print(f'Repaired copy: {output}\nThe original app was not modified.')


if __name__ == '__main__':
    main()
