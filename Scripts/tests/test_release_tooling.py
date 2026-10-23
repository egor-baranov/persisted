#!/usr/bin/env python3
"""Hermetic release regressions: temporary bundles and fake platform commands only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_config

spec = importlib.util.spec_from_file_location('package_site', SCRIPTS / 'package-site.py')
package_site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_site)


def make_app(root, version='2.3.4', build='42'):
    app = root / 'Persisted.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/MacOS/Persisted').write_bytes(b'fixture executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': version, 'CFBundleVersion': build,
        'LSMinimumSystemVersion': '15.0',
    }))
    return app


def make_repository(root):
    paths = ['Package.swift', 'README.md', '.gitignore', 'Config/Base.xcconfig',
             'Config/Persisted-Info.plist', 'Config/Persisted.icns',
             'Persisted.xcodeproj/project.pbxproj', 'docs/Architecture.md',
             'docs/Manual-Smoke-Tests.md', 'docs/Release-Readiness.md', 'site/README.md',
             'site/assets/screenshots/catalog.png', 'site/assets/screenshots/desktops.png',
             'site/assets/screenshots/editor.png']
    for relative in paths:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('fixture')
    (root / 'Config/Base.xcconfig').write_text('''MARKETING_VERSION = 2.3.4
CURRENT_PROJECT_VERSION = 42
MACOSX_DEPLOYMENT_TARGET = 15.0
PERSISTED_BUNDLE_IDENTIFIER = app.persisted.Persisted
''')
    (root / 'Config/Persisted-Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': '$(MARKETING_VERSION)',
        'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'LSMinimumSystemVersion': '$(MACOSX_DEPLOYMENT_TARGET)',
    }))


class FakePlatform:
    def __init__(self, signing='ad-hoc', stapled=False):
        self.signing = signing
        self.stapled = stapled
        self.commands = []
        self.fail_archive = False
        self.fail_verify = False

    def __call__(self, args, **kwargs):
        self.commands.append(args)
        stdout, stderr, status = '', '', 0
        if args[0] == 'codesign':
            if '--verify' in args and self.fail_verify:
                raise subprocess.CalledProcessError(1, args)
            if '--display' in args:
                stderr = ('Signature=adhoc\n' if self.signing == 'ad-hoc'
                          else 'Authority=Developer ID Application: Example (TEAM123)\n')
        elif args[:3] == ['xcrun', 'stapler', 'validate']:
            status = 0 if self.stapled else 65
        elif args[0] == 'lipo':
            stdout = 'x86_64 arm64\n'
        elif args[0] == 'ditto':
            if self.fail_archive:
                raise subprocess.CalledProcessError(1, args)
            Path(args[-1]).write_bytes(b'fake app archive')
        else:
            raise AssertionError(f'Unexpected platform command: {args}')
        return subprocess.CompletedProcess(args, status, stdout, stderr)


class BuildConfigurationTests(unittest.TestCase):
    def test_bundle_metadata_comes_from_base_config_for_both_apps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            staging = root / 'stage'
            for name in ('Persisted', 'PersistedHarness'):
                (staging / f'{name}.app/Contents').mkdir(parents=True)
            environment = {'PERSISTED_BUNDLE_IDENTIFIER': 'test.custom'}
            build_config.write_bundle_plists(staging, root, environment)
            for name in ('Persisted', 'PersistedHarness'):
                info = plistlib.loads((staging / f'{name}.app/Contents/Info.plist').read_bytes())
                self.assertEqual(info['CFBundleShortVersionString'], '2.3.4')
                self.assertEqual(info['CFBundleVersion'], '42')
                self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
                self.assertTrue(info['CFBundleIdentifier'].startswith('test.custom'))

    def test_build_directory_has_same_repository_relative_and_absolute_rules(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            environment = {'PERSISTED_BUILD_DIRECTORY': 'custom output'}
            self.assertEqual(build_config.build_directory(root=root, environment=environment), root / 'custom output')
            self.assertEqual(build_config.build_directory(str(root / 'absolute'), root, environment), root / 'absolute')
            self.assertEqual(build_config.build_directory('explicit', root, environment), root / 'explicit')
            self.assertEqual(build_config.build_directory(root=root, environment={}), root / 'build')

    def test_invalid_or_missing_version_fails_before_build_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            path = root / 'Config/Base.xcconfig'
            path.write_text(path.read_text().replace('2.3.4', '../../invalid'))
            with self.assertRaises(ValueError):
                build_config.configuration(root, {})


class PackageTests(unittest.TestCase):
    def test_manifest_describes_selected_bundle_and_only_published_downloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            app = make_app(root / 'custom output')
            downloads = root / 'site/downloads'
            downloads.mkdir()
            (downloads / 'old.zip').write_bytes(b'unrelated archive')
            platform = FakePlatform()
            manifest = package_site.package(app, root, run=platform)
            self.assertEqual(manifest['version'], '2.3.4')
            self.assertEqual(manifest['build'], '42')
            self.assertEqual(manifest['minimumMacOS'], '15.0')
            self.assertEqual(manifest['signing'], 'ad-hoc')
            self.assertEqual(manifest['notarization'], 'not-verified')
            self.assertEqual(manifest['architectures'], ['x86_64', 'arm64'])
            self.assertEqual(set(manifest['downloads']), set(package_site.DOWNLOAD_NAMES))
            for name, entry in manifest['downloads'].items():
                data = (downloads / name).read_bytes()
                self.assertEqual(entry, {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            self.assertEqual(json.loads((downloads / 'manifest.json').read_text()), manifest)
            ditto = next(command for command in platform.commands if command[0] == 'ditto')
            self.assertEqual(ditto[-2], str(app))
            self.assertIn(str(downloads), ditto[-1])

    def test_notarized_release_metadata_is_not_a_fixed_preview_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            manifest = package_site.package(make_app(root / 'release'), root, require_notarized=True,
                                            run=FakePlatform('developer-id', stapled=True))
            self.assertEqual(manifest['signing'], 'developer-id')
            self.assertEqual(manifest['notarization'], 'stapled')

    def test_release_requirement_rejects_preview_without_replacing_downloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            downloads = root / 'site/downloads'
            downloads.mkdir()
            sentinel = downloads / 'Persisted-preview.zip'
            sentinel.write_bytes(b'previous release')
            with self.assertRaisesRegex(ValueError, 'Developer ID'):
                package_site.package(make_app(root / 'preview'), root, require_notarized=True, run=FakePlatform())
            self.assertEqual(sentinel.read_bytes(), b'previous release')

    def test_failed_signature_or_archive_leaves_previous_downloads_intact(self):
        for failure in ('fail_verify', 'fail_archive'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                make_repository(root)
                downloads = root / 'site/downloads'
                downloads.mkdir()
                for name in (*package_site.DOWNLOAD_NAMES, 'manifest.json'):
                    (downloads / name).write_bytes(b'old')
                platform = FakePlatform()
                setattr(platform, failure, True)
                with self.assertRaises(subprocess.CalledProcessError):
                    package_site.package(make_app(root / 'app'), root, run=platform)
                self.assertEqual({p.name: p.read_bytes() for p in downloads.iterdir()},
                                 {name: b'old' for name in (*package_site.DOWNLOAD_NAMES, 'manifest.json')})

    def test_source_download_contains_public_readiness_not_private_logs_or_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            (root / 'docs/Verification.md').write_text('private operational paths')
            (root / 'Config/Signing.local.xcconfig').write_text('private configuration')
            package_site.package(make_app(root / 'app'), root, run=FakePlatform())
            with zipfile.ZipFile(root / 'site/downloads/Persisted-source.zip') as archive:
                names = archive.namelist()
            self.assertIn('Persisted/docs/Release-Readiness.md', names)
            self.assertNotIn('Persisted/docs/Verification.md', names)
            self.assertNotIn('Persisted/Config/Signing.local.xcconfig', names)
            self.assertFalse(any('/downloads/' in name for name in names))

    def test_missing_public_document_fails_instead_of_shipping_broken_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_repository(root)
            (root / 'docs/Release-Readiness.md').unlink()
            with self.assertRaisesRegex(ValueError, 'Release-Readiness'):
                package_site.source_files(root)


class ReleaseScriptTests(unittest.TestCase):
    def test_custom_directory_version_and_site_publishing_use_exact_built_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            make_repository(root)
            scripts = root / 'Scripts'
            scripts.mkdir()
            for name in ('release.sh', 'build_config.py'):
                shutil.copy2(SCRIPTS / name, scripts / name)
            log = root / 'commands.jsonl'
            fake_bin = root / 'fake-bin'
            fake_bin.mkdir()
            logger = '''import json, os, sys
from pathlib import Path
with open(os.environ['TEST_COMMAND_LOG'], 'a') as stream:
    stream.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
'''
            for name in ('codesign', 'ditto', 'xcrun', 'spctl'):
                path = fake_bin / name
                path.write_text(f'#!{sys.executable}\n' + logger)
                path.chmod(0o755)
            builder = scripts / 'build-app.sh'
            builder.write_text(f'#!{sys.executable}\n' + logger + '''import plistlib
app = Path(os.environ['PERSISTED_BUILD_DIRECTORY']) / 'Persisted.app'
(app / 'Contents').mkdir(parents=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '9.4.1'}))
''')
            builder.chmod(0o755)
            (scripts / 'package-site.py').write_text(logger)
            old_app = make_app(root / 'build', version='0.0.1')
            old_info = (old_app / 'Contents/Info.plist').read_bytes()
            environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'],
                               PERSISTED_BUILD_DIRECTORY='custom release output',
                               SIGNING_IDENTITY='FAKE SIGNING IDENTITY', NOTARY_PROFILE='FAKE PROFILE',
                               TEST_COMMAND_LOG=str(log))
            result = subprocess.run(['/bin/bash', str(scripts / 'release.sh'), '--package-site'],
                                    cwd=root.parent, env=environment, capture_output=True, text=True, check=True)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            output = root / 'custom release output'
            app = str(output / 'Persisted.app')
            self.assertEqual(commands[0], ['build-app.sh', 'release'])
            for command in commands:
                if command[0] in ('codesign', 'spctl') or command[:3] in (
                        ['xcrun', 'stapler', 'staple'], ['xcrun', 'stapler', 'validate']):
                    self.assertEqual(command[-1], app)
                if command[0] == 'ditto':
                    self.assertEqual(command[-2], app)
            self.assertIn(['ditto', '-c', '-k', '--keepParent', app, str(output / 'Persisted-9.4.1.zip')], commands)
            self.assertEqual(commands[-1], ['package-site.py', '--app', app, '--require-notarized'])
            self.assertIn(str(output / 'Persisted-9.4.1.zip'), result.stdout)
            self.assertEqual((old_app / 'Contents/Info.plist').read_bytes(), old_info)
            self.assertFalse(any(str(old_app) in item for command in commands for item in command))


if __name__ == '__main__':
    unittest.main()
