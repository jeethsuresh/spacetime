#!/usr/bin/env python3
"""Build the real native client, smoke-test it, and archive its complete bundle."""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=ROOT, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def archive_tree(directory, destination):
    # Preserve framework symlinks and executable permissions for Store's safe extractor.
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(directory.rglob('*')):
            relative = file.relative_to(directory).as_posix()
            if file.is_symlink():
                info = zipfile.ZipInfo(relative)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, os.readlink(file))
            elif file.is_file():
                archive.write(file, relative)


def build(platform, arch, smoke=True):
    config = json.loads((ROOT / 'desktop-release.config.json').read_text())
    work = ROOT / config['directory']
    destination = ROOT / 'desktop-dist'
    destination.mkdir(exist_ok=True)
    label = {'macos': 'mac', 'windows': 'win', 'linux': 'linux'}[platform]
    archive = destination / f"{config['slug']}-{config['version']}-{label}-{arch}.zip"
    smoke_command = None
    if config['engine'] == 'flutter':
        flutter = shutil.which('flutter.bat' if os.name == 'nt' else 'flutter')
        if not flutter:
            raise ValueError('Install the repository-pinned Flutter SDK first')
        if platform == 'macos':
            settings = work / 'macos/Runner/Configs/AppInfo.xcconfig'
            settings.write_text(settings.read_text() + f"\nARCHS = {'arm64' if arch == 'arm64' else 'x86_64'}\nONLY_ACTIVE_ARCH = YES\n")
        run([flutter, 'pub', 'get', '--enforce-lockfile'], work)
        defines = ['--dart-define=' + item for item in config.get('defines', [])]
        run([flutter, 'build', platform, '--release', '--no-pub',
             '--build-name=' + config['version'], '--build-number=' + str(config['versionCode']), *defines], work)
        if platform == 'macos':
            output = work / 'build/macos/Build/Products/Release'
        elif platform == 'windows':
            output = work / 'build/windows/x64/runner/Release'
        else:
            output = work / 'build/linux/x64/release/bundle'
        if smoke:
            smoke_command = [flutter, 'drive', '--driver=test_driver/desktop.dart',
                 '--target=integration_test/desktop_smoke.dart', '-d', platform,
                 '--debug', '--no-pub', *defines]
    else:
        bun = shutil.which('bun')
        run([bun, 'install', '--frozen-lockfile'])
        if config['slug'] == 'office':
            # The Go sidecar must match the Electron target, including Intel Mac builds.
            env = {**os.environ, 'GOOS': {'macos': 'darwin', 'windows': 'windows', 'linux': 'linux'}[platform],
                   'GOARCH': 'arm64' if arch == 'arm64' else 'amd64', 'CGO_ENABLED': '0'}
            run([bun, 'run', 'build'], env=env)
        else:
            run(['bash', 'scripts/stage-backend.sh', {'macos': 'darwin', 'windows': 'windows', 'linux': 'linux'}[platform],
                 'arm64' if arch == 'arm64' else 'amd64'])
            run([bun, 'run', '--filter', '@rss-reader/desktop', 'build'])
        arguments = [bun, 'x', '--no-install', 'electron-builder', '--' + label, '--' + arch,
                     '--dir', '--publish', 'never']
        if platform == 'macos':
            arguments += ['-c.mac.identity=-']
        run(arguments, work)
        output = work / ('release/mac-arm64' if platform == 'macos' and arch == 'arm64' else
                         'release/mac' if platform == 'macos' else
                         'release/win-unpacked' if platform == 'windows' else 'release/linux-unpacked')
        if smoke:
            run(['node', 'scripts/desktop-smoke.mjs', str(output / config['entries'][platform])])
    entry = output / config['entries'][platform]
    if config['engine'] == 'flutter' and platform == 'linux':
        # Ship the credential plugin's distribution-specific SONAMEs too.
        for library in list((output / 'lib').glob('*.so')):
            dependencies = subprocess.check_output(['ldd', str(library)], text=True)
            for soname, location in re.findall(r'(lib(?:jsoncpp|secret-1)[^ ]*) => (/[^ ]+)', dependencies):
                shutil.copyfile(location, output / 'lib' / soname)
        entry.write_text('#!/bin/sh\nAPPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"\nexport LD_LIBRARY_PATH="$APPDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "$APPDIR/' + config['slug'] + '" "$@"\n')
        entry.chmod(0o755)
    if not entry.exists():
        raise ValueError('Native bundle is missing its launch entry: ' + str(entry))
    if platform == 'macos':
        # Bundle directories may contain unrelated test executables; publish only the app.
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(entry), str(archive)])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(entry)])
    else:
        archive_tree(output, archive)
    if config['engine'] == 'flutter' and smoke:
        executable = entry
        if platform == 'macos':
            import plistlib
            executable = entry / 'Contents/MacOS' / plistlib.loads((entry / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
        process = subprocess.Popen([str(executable)], cwd=output)
        try:
            time.sleep(3)
            if process.poll() is not None:
                time.sleep(2)
                if platform == 'macos':
                    reports = sorted((Path.home() / 'Library/Logs/DiagnosticReports').glob(config['name'] + '*.ips'), key=lambda p:p.stat().st_mtime)
                    for report in reports[-1:]: print(report.read_text()[:10000], flush=True)
                raise ValueError('The packaged native application exited during startup with code ' + str(process.returncode))
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
        # flutter drive rebuilds the output with a test entrypoint. The production
        # ZIP above is already sealed and is never replaced with that test app.
        run(smoke_command, work)
    print('Verified native package: ' + str(archive))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'windows', 'linux'])
    parser.add_argument('arch', choices=['x64', 'arm64'])
    parser.add_argument('--no-smoke', action='store_true', help='Local packaging only; CI always runs native smoke checks')
    args = parser.parse_args()
    build(args.platform, args.arch, not args.no_smoke)
