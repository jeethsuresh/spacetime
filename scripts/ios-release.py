#!/usr/bin/env python3
"""Archive and verify an App Store Connect IPA using environment signing assets."""

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
from tempfile import TemporaryDirectory
import uuid

from apple_signing import run, signing_input, signing_keychain, write_signing_input


def read_profile(path):
    return plistlib.loads(run("security", "cms", "-D", "-i", path, capture=True))


def validate_profile(profile, bundle_id, app_group, production_push=False):
    entitlements = profile["Entitlements"]
    team = entitlements["com.apple.developer.team-identifier"]
    expected_ids = {
        f"{prefix}.{bundle_id}" for prefix in profile["ApplicationIdentifierPrefix"]
    }
    if team not in profile["TeamIdentifier"] or entitlements["application-identifier"] not in expected_ids:
        raise ValueError(f"The profile must explicitly match {bundle_id} and its Apple team.")
    if ("ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")
            or entitlements.get("get-task-allow", False)):
        raise ValueError(f"{bundle_id} requires an App Store Connect distribution profile.")
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError(f"The profile for {bundle_id} has expired.")
    if app_group not in entitlements.get("com.apple.security.application-groups", []):
        raise ValueError(f"The profile for {bundle_id} does not include {app_group}.")
    if production_push and entitlements.get("aps-environment") != "production":
        raise ValueError(f"The profile for {bundle_id} must allow production APNs.")
    uuid.UUID(profile["UUID"])
    return team


def choose_identity(keychain, profiles):
    available = run("security", "find-identity", "-v", "-p", "codesigning",
                    keychain, capture=True).decode()
    identities = set(re.findall(r'\b([0-9A-F]{40}) "(?:Apple|iPhone) Distribution:', available))
    for profile in profiles:
        identities &= {
            hashlib.sha1(certificate).hexdigest().upper()
            for certificate in profile["DeveloperCertificates"]
        }
    if len(identities) != 1:
        raise ValueError("The PKCS#12 must contain one valid distribution identity shared by both profiles.")
    return identities.pop()


def install_profile(source, profile, cleanup):
    directory = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / f"{profile['UUID']}.mobileprovision"
    data = source.read_bytes()
    if destination.exists():
        if destination.read_bytes() != data:
            raise ValueError("A different provisioning profile already uses that UUID.")
    else:
        cleanup.callback(destination.unlink, missing_ok=True)
        destination.write_bytes(data)


def verify_ipa(ipa, directory, app_id, app_group, build_number, profiles, production_push):
    unpacked = directory / "unpacked"
    run("ditto", "-x", "-k", ipa, unpacked)
    apps = list((unpacked / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected one app in the exported IPA.")
    app = apps[0]
    widgets = list((app / "PlugIns").glob("*.appex"))
    if len(widgets) != 1:
        raise ValueError("Expected one embedded widget extension in the exported IPA.")
    run("codesign", "--verify", "--deep", "--strict", app)

    app_version = None
    for path, bundle_id in zip([app, widgets[0]], [app_id, f"{app_id}.widgets"]):
        info = plistlib.loads((path / "Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != bundle_id or info["CFBundleVersion"] != build_number:
            raise ValueError(f"Unexpected bundle identifier or build number for {bundle_id}.")
        version = info["CFBundleShortVersionString"]
        if path == app:
            app_version = version
        elif version != app_version or info["NSExtension"]["NSExtensionPointIdentifier"] != "com.apple.widgetkit-extension":
            raise ValueError("The embedded widget must match the app version and declare WidgetKit.")
        profile = profiles[bundle_id]
        embedded_profile = read_profile(path / "embedded.mobileprovision")
        if embedded_profile["UUID"] != profile["UUID"]:
            raise ValueError(f"The exported {bundle_id} uses an unexpected provisioning profile.")
        signed = plistlib.loads(run("codesign", "-d", "--entitlements", "-", "--xml",
                                    path, capture=True, quiet=True))
        if (signed.get("application-identifier") != profile["Entitlements"]["application-identifier"]
                or app_group not in signed.get("com.apple.security.application-groups", [])
                or signed.get("get-task-allow", False)):
            raise ValueError(f"The exported {bundle_id} has incorrect signing entitlements.")
        if production_push and path == app:
            if signed.get("aps-environment") != "production" or info.get("APNSEnvironment") != "production":
                raise ValueError("The exported app is missing production APNs configuration.")


def release(args):
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        raise ValueError("The iOS build number must be a positive integer.")
    app_id = args.bundle_id
    widget_id = f"{app_id}.widgets"
    app_group = f"group.{app_id}"

    with TemporaryDirectory(prefix="ios-release-", dir=os.environ.get("RUNNER_TEMP")) as temp, ExitStack() as cleanup:
        directory = Path(temp)
        certificate = directory / "signing.p12"
        app_profile = directory / "app.mobileprovision"
        widget_profile = directory / "widget.mobileprovision"
        write_signing_input(certificate, "IOS_CERTIFICATE_P12_BASE64")
        write_signing_input(app_profile, "IOS_APP_PROFILE_BASE64")
        write_signing_input(widget_profile, "IOS_WIDGET_PROFILE_BASE64")
        password = signing_input("IOS_CERTIFICATE_PASSWORD")

        profiles = {app_id: read_profile(app_profile), widget_id: read_profile(widget_profile)}
        team = validate_profile(profiles[app_id], app_id, app_group, args.production_push)
        if validate_profile(profiles[widget_id], widget_id, app_group) != team:
            raise ValueError("The app and widget profiles must belong to the same Apple team.")

        keychain = signing_keychain(directory, certificate, password, cleanup)
        identity = choose_identity(keychain, profiles.values())
        install_profile(app_profile, profiles[app_id], cleanup)
        install_profile(widget_profile, profiles[widget_id], cleanup)

        archive = directory / "Runner.xcarchive"
        build_settings = [
            "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}",
            f"DEVELOPMENT_TEAM={team}", f"FLUTTER_BUILD_NUMBER={args.build_number}",
            f"IOS_APP_PROFILE={profiles[app_id]['UUID']}",
            f"IOS_WIDGET_PROFILE={profiles[widget_id]['UUID']}",
        ]
        if args.production_push:
            build_settings.extend(["APS_ENVIRONMENT=production", "GRAVITAS_APNS_ENVIRONMENT=production"])
        run("xcodebuild", "archive", "-workspace", "ios/Runner.xcworkspace",
            "-scheme", "Runner", "-configuration", "Release",
            "-destination", "generic/platform=iOS", "-archivePath", archive,
            *build_settings)

        options = directory / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({
            "method": "app-store-connect",
            "destination": "export",
            "teamID": team,
            "signingStyle": "manual",
            "signingCertificate": identity,
            "manageAppVersionAndBuildNumber": False,
            "provisioningProfiles": {bundle_id: profile["UUID"] for bundle_id, profile in profiles.items()},
        }))
        export = directory / "export"
        run("xcodebuild", "-exportArchive", "-archivePath", archive,
            "-exportPath", export, "-exportOptionsPlist", options)
        ipas = list(export.glob("*.ipa"))
        if len(ipas) != 1:
            raise ValueError("Xcode did not export exactly one IPA.")
        verify_ipa(ipas[0], directory, app_id, app_group, args.build_number, profiles, args.production_push)

        args.output.mkdir(parents=True, exist_ok=True)
        output = args.output / f"{args.artifact_name}-{args.build_number}.ipa"
        output.write_bytes(ipas[0].read_bytes())
        with output.open("rb") as ipa:
            digest = hashlib.file_digest(ipa, "sha256").hexdigest()
        (args.output / "SHA256SUMS").write_text(f"{digest}  {output.name}\n")
        print(f"Verified and exported {output.name} with its signed widget extension.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--artifact-name", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--production-push", action="store_true")
    try:
        release(parser.parse_args())
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"iOS release: {error}") from None
