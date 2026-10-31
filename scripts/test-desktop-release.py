#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('desktop-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class NativeReleaseTest(unittest.TestCase):
    def test_all_targets_and_declared_executables_are_required(self):
        config, _ = release.validate()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(ValueError):
                release.stage(directory)
            for platform, arch in release.TARGETS:
                label = {'macos': 'mac', 'windows': 'win', 'linux': 'linux'}[platform]
                entry = config['entries'][platform]
                archive = directory / f"{config['slug']}-{config['version']}-{label}-{arch}.zip"
                with zipfile.ZipFile(archive, 'w') as target:
                    target.writestr(entry + '/Contents/Info.plist' if platform == 'macos' else entry, b'native bundle')
            _, manifest = release.stage(directory)
            self.assertEqual(len(manifest['artifacts']), 4)
            self.assertTrue(all(a['size'] > 0 and len(a['sha256']) == 64 for a in manifest['artifacts']))
            with zipfile.ZipFile(archive, 'w') as target:
                target.writestr('wrong-entry', b'not the app')
            with self.assertRaisesRegex(ValueError, 'no declared executable'):
                release.stage(directory)


if __name__ == '__main__':
    unittest.main()
