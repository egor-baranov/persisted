#!/usr/bin/env python3
"""Shared paths and bundle metadata for local builds and release tools."""
import argparse
import os
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def configuration(root=ROOT, environment=None):
    environment = os.environ if environment is None else environment
    values = {}
    for line in (root / 'Config/Base.xcconfig').read_text().splitlines():
        match = re.fullmatch(r'\s*([A-Z_]+)\s*=\s*([^/]*?)(?:\s*//.*)?', line)
        if match:
            values[match[1]] = match[2].strip()
    required = ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION', 'MACOSX_DEPLOYMENT_TARGET',
                'PERSISTED_BUNDLE_IDENTIFIER')
    for key in required:
        if not values.get(key):
            raise ValueError(f'Missing {key} in Config/Base.xcconfig')
    for key in required[:3]:
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', values[key]):
            raise ValueError(f'{key} must be a numeric version in Config/Base.xcconfig')
    return {
        'build_directory': str(build_directory(root=root, environment=environment)),
        'version': values['MARKETING_VERSION'],
        'build': values['CURRENT_PROJECT_VERSION'],
        'minimum_macos': values['MACOSX_DEPLOYMENT_TARGET'],
        'bundle_identifier': environment.get('PERSISTED_BUNDLE_IDENTIFIER') or values['PERSISTED_BUNDLE_IDENTIFIER'],
    }


def build_directory(value=None, root=ROOT, environment=None):
    environment = os.environ if environment is None else environment
    path = Path(value or environment.get('PERSISTED_BUILD_DIRECTORY') or 'build').expanduser()
    return (root / path).resolve() if not path.is_absolute() else path.resolve()


def write_bundle_plists(staging, root=ROOT, environment=None):
    config = configuration(root, environment)
    info = plistlib.loads((root / 'Config/Persisted-Info.plist').read_bytes())
    info.update(CFBundleIdentifier=config['bundle_identifier'],
                CFBundleShortVersionString=config['version'], CFBundleVersion=config['build'],
                LSMinimumSystemVersion=config['minimum_macos'])
    fixture = dict(CFBundleIdentifier=config['bundle_identifier'] + '.Harness',
                   CFBundleName='Persisted Harness', CFBundleExecutable='PersistedHarness',
                   CFBundlePackageType='APPL', CFBundleShortVersionString=config['version'],
                   CFBundleVersion=config['build'], LSMinimumSystemVersion=config['minimum_macos'],
                   NSHighResolutionCapable=True, NSPrincipalClass='NSApplication')
    for name, metadata in [('Persisted', info), ('PersistedHarness', fixture)]:
        (staging / f'{name}.app/Contents/Info.plist').write_bytes(plistlib.dumps(metadata))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--value', choices=['build_directory', 'version', 'build', 'minimum_macos', 'bundle_identifier'])
    actions.add_argument('--write-plists', type=Path, metavar='STAGING_DIRECTORY')
    args = parser.parse_args()
    if args.write_plists:
        write_bundle_plists(args.write_plists)
    else:
        print(configuration()[args.value])


if __name__ == '__main__':
    main()
