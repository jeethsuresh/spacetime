#!/usr/bin/env python3
"""Developer ID-sign, notarize and staple the Private Store macOS packages."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import plistlib
import re
from tempfile import TemporaryDirectory

from apple_signing import run, signing_input, signing_keychain, write_signing_input


def developer_id(keychain):
    identities = run("security", "find-identity", "-v", "-p", "codesigning",
                     keychain, capture=True).decode()
    fingerprints = re.findall(r'\b([0-9A-F]{40}) "Developer ID Application:', identities)
    if len(fingerprints) != 1:
        raise ValueError("The PKCS#12 must contain one valid Developer ID Application identity.")
    return fingerprints[0]


def app_from_archive(archive, folder, entry, bundle_id):
    run("ditto", "-x", "-k", archive, folder)
    app = folder / entry
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != bundle_id:
        raise ValueError(f"{archive.name} does not contain {bundle_id}.")
    return app, info


def sign_package(archive, entry, bundle_id, entitlements, identity, notary):
    with TemporaryDirectory(prefix="macos-sign-", dir=archive.parent) as tmp:
        directory = Path(tmp)
        app, info = app_from_archive(archive, directory / "unsigned", entry, bundle_id)
        arch = {"arm64": "arm64", "x64": "x86_64"}.get(archive.stem.rsplit("-", 1)[-1])
        if arch is None:
            raise ValueError(f"Cannot determine the architecture of {archive.name}.")
        run("lipo", app / "Contents/MacOS" / info["CFBundleExecutable"], "-verify_arch", arch)
        signing = ("codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime")
        frameworks = app / "Contents/Frameworks"
        nested = sorted(frameworks.rglob("*"), key=lambda path: len(path.parts), reverse=True)
        for item in nested:
            if not item.is_symlink() and item.suffix in {".framework", ".dylib", ".xpc", ".appex", ".app"}:
                run(*signing, item)
        run(*signing, "--entitlements", entitlements, app)
        run("codesign", "--verify", "--deep", "--strict", app)

        submission = directory / "notarization.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission)
        result = json.loads(run("xcrun", "notarytool", "submit", submission, *notary,
                                "--wait", "--timeout", "20m", "--output-format", "json", capture=True))
        if result.get("status") != "Accepted":
            if result.get("id"):
                run("xcrun", "notarytool", "log", result["id"], *notary)
            raise ValueError(f"Apple notarization did not accept {archive.name}.")
        print(f"Apple notarization accepted {archive.name} ({result['id']}).", flush=True)
        run("xcrun", "stapler", "staple", app)
        packaged = directory / "distribution.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, packaged)
        verified, _ = app_from_archive(packaged, directory / "verified", entry, bundle_id)
        run("codesign", "--verify", "--deep", "--strict", verified)
        run("xcrun", "stapler", "validate", verified)
        packaged.replace(archive)


def sign(args):
    for archive in args.archives:
        if not archive.is_file():
            raise ValueError(f"Missing macOS package: {archive.name}")
    with TemporaryDirectory(prefix="macos-credentials-", dir=os.environ.get("RUNNER_TEMP")) as temp, ExitStack() as cleanup:
        directory = Path(temp)
        certificate = directory / "signing.p12"
        key = directory / "notary.p8"
        write_signing_input(certificate, "MAC_CERTIFICATE_P12_BASE64")
        write_signing_input(key, "MAC_NOTARY_KEY_BASE64")
        password = signing_input("MAC_CERTIFICATE_PASSWORD")
        notary = ("--key", key, "--key-id", signing_input("MAC_NOTARY_KEY_ID"),
                  "--issuer", signing_input("MAC_NOTARY_ISSUER_ID"))
        identity = developer_id(signing_keychain(directory, certificate, password, cleanup))
        for archive in args.archives:
            sign_package(archive, args.entry, args.bundle_id, args.entitlements, identity, notary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--entitlements", required=True, type=Path)
    parser.add_argument("archives", type=Path, nargs="+")
    try:
        sign(parser.parse_args())
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"macOS signing: {error}") from None
