#!/usr/bin/env python3
"""Prepare local website downloads from a selected app and public-safe source files."""
import argparse
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import tempfile
import zipfile

from build_config import ROOT, build_directory

DOWNLOAD_NAMES = ('Persisted-preview.zip', 'Persisted-source.zip')


def source_files(root=ROOT):
    exact = ['Package.swift', 'README.md', '.gitignore', 'Config/Base.xcconfig',
             'Config/Persisted-Info.plist', 'Config/Persisted.icns',
             'Persisted.xcodeproj/project.pbxproj', 'docs/Architecture.md',
             'docs/Manual-Smoke-Tests.md', 'docs/Release-Readiness.md', 'site/README.md']
    files = {root / name for name in exact}
    for path in files:
        if not path.is_file():
            raise ValueError(f'Missing required source-download file: {path.relative_to(root)}')
    for directory in ['Sources', 'Tests', 'Scripts', 'Persisted.xcodeproj/xcshareddata/xcschemes']:
        files.update(path for path in (root / directory).rglob('*') if path.is_file()
                     and path.suffix in {'.swift', '.m', '.h', '.modulemap', '.sh', '.py', '.xcscheme'})
    files.update(path for path in (root / 'site').rglob('*') if path.is_file()
                 and 'downloads' not in path.relative_to(root / 'site').parts
                 and path.suffix in {'.html', '.css', '.js', '.png', '.svg', '.txt', '.md'})
    # No working tree, build cache, user data, local signing config, or operational logs.
    return sorted(files)


def app_metadata(app, run=subprocess.run):
    executable = app / 'Contents/MacOS/Persisted'
    if not executable.is_file():
        raise ValueError(f'No Persisted executable at {app}. Build the intended app first.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'):
        if not isinstance(info.get(key), str) or not info[key] or '$(' in info[key]:
            raise ValueError(f'The selected app has missing or unresolved {key}.')
    run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = run(['codesign', '--display', '--verbose=4', str(app)],
                    capture_output=True, text=True, check=True)
    fields = (signature.stdout or '') + (signature.stderr or '')
    if 'Signature=adhoc' in fields:
        signing = 'ad-hoc'
    elif 'Authority=Developer ID Application:' in fields:
        signing = 'developer-id'
    else:
        signing = 'signed'
    # Failure does not prove absence of notarization; only a validated staple is
    # reported as verified. This command never submits or staples the bundle.
    validation = run(['xcrun', 'stapler', 'validate', str(app)], capture_output=True, text=True)
    architectures = run(['lipo', '-archs', str(executable)], capture_output=True, text=True, check=True)
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'minimumMacOS': info['LSMinimumSystemVersion'], 'signing': signing,
            'notarization': 'stapled' if validation.returncode == 0 else 'not-verified',
            'architectures': architectures.stdout.strip().split()}


def package(app, root=ROOT, require_notarized=False, run=subprocess.run):
    site = root / 'site'
    downloads = site / 'downloads'
    metadata = app_metadata(app, run)
    if require_notarized and (metadata['signing'] != 'developer-id' or metadata['notarization'] != 'stapled'):
        raise ValueError('Website release requires a Developer ID signature and a validated notarization staple.')
    sources = source_files(root)
    for name in ['catalog.png', 'desktops.png', 'editor.png']:
        if not (site / 'assets/screenshots' / name).is_file():
            raise ValueError(f'Missing native screenshot: {name}')
    downloads.mkdir(exist_ok=True)
    # Stage on the destination volume so publication also works when the site
    # and build directory live on different volumes from the system temp folder.
    with tempfile.TemporaryDirectory(prefix='.package-', dir=downloads) as temporary:
        staged = Path(temporary)
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app),
             str(staged / DOWNLOAD_NAMES[0])], check=True)
        with zipfile.ZipFile(staged / DOWNLOAD_NAMES[1], 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in sources:
                archive.write(path, 'Persisted/' + path.relative_to(root).as_posix())
        manifest = dict(metadata, downloads={
            name: {'bytes': (staged / name).stat().st_size,
                   'sha256': hashlib.sha256((staged / name).read_bytes()).hexdigest()}
            for name in DOWNLOAD_NAMES
        })
        (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for name in (*DOWNLOAD_NAMES, 'manifest.json'):
            (staged / name).replace(downloads / name)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--app', type=Path, help='Exact Persisted.app to publish (relative paths use the current directory).')
    source.add_argument('--build-directory', help='Build directory containing Persisted.app (relative to the repository).')
    parser.add_argument('--require-notarized', action='store_true', help='Reject anything except a stapled Developer ID release.')
    args = parser.parse_args()
    app = args.app.expanduser().resolve() if args.app else build_directory(args.build_directory) / 'Persisted.app'
    try:
        manifest = package(app, require_notarized=args.require_notarized)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
