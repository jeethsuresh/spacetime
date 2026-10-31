#!/usr/bin/env python3
"""Validate, stage and atomically publish native desktop releases."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "desktop-release.config.json"
TARGETS = {("macos", "x64"), ("macos", "arm64"), ("windows", "x64"), ("linux", "x64")}


def validate():
    package = json.loads(CONFIG.read_text())
    if package.get("schemaVersion") != 1 or not re.fullmatch(r"[a-z0-9-]+", package["slug"]):
        raise ValueError("invalid desktop release configuration")
    if not re.fullmatch(r"jeethsuresh/[a-z0-9-]+", package["repository"]):
        raise ValueError("invalid desktop source repository")
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", package["version"]):
        raise ValueError("desktop version must be stable X.Y.Z")
    if type(package.get("versionCode")) is not int or not 0 < package["versionCode"] <= 2**53 - 1:
        raise ValueError("desktop versionCode must be a positive safe integer")
    changes = package.get("changes")
    if not isinstance(changes, list) or not 1 <= len(changes) <= 50 or any(not isinstance(c, str) or not c.strip() or len(c.encode()) > 2000 or any(ord(x) < 32 for x in c) for c in changes):
        raise ValueError("desktop changes must be nonempty plain-text strings")
    if package["engine"] == "electron":
        native = json.loads((ROOT / package["directory"] / "package.json").read_text())
        if native["version"] != package["version"]:
            raise ValueError("Electron package version must match desktop release")
    elif package["engine"] != "flutter":
        raise ValueError("unsupported native engine")
    changelog = {key: package[key] for key in ("schemaVersion", "version", "versionCode", "changes")}
    return package, changelog


def sha256(file):
    with file.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def stage(directory):
    package, changelog = validate()
    artifacts = []
    found = set()
    for platform, arch in sorted(TARGETS):
        label = {"macos": "mac", "windows": "win", "linux": "linux"}[platform]
        file = directory / f"{package['slug']}-{package['version']}-{label}-{arch}.zip"
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f"missing native package: {file.name}")
        found.add((platform, arch))
        entry = package["entries"][platform]
        import zipfile
        with zipfile.ZipFile(file) as archive:
            names = archive.namelist()
            if (entry not in names if platform != "macos" else not any(n.startswith(entry + "/Contents/") for n in names)):
                raise ValueError("native archive has no declared executable: " + entry)
        artifacts.append(dict(platform=platform, arch=arch, file=file.name, entry=entry, sha256=sha256(file), size=file.stat().st_size))
    manifest = {**changelog, "artifacts": artifacts}
    if len((json.dumps(manifest, indent=2) + "\n").encode()) > 64 * 1024:
        raise ValueError("desktop release manifest exceeds the ingestion size limit")
    (directory / "desktop-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (directory / "desktop-changelog.json").write_text(json.dumps(changelog, indent=2) + "\n")
    files = [directory / a["file"] for a in artifacts] + [directory / "desktop-release.json", directory / "desktop-changelog.json"]
    (directory / "SHA256SUMS").write_text("".join(f"{sha256(file)}  {file.name}\n" for file in files))
    return package, manifest


def api(path, method="GET", value=None, binary=None):
    url = path if path.startswith("https://") else "https://api.github.com" + path
    if not (url.startswith("https://api.github.com/") or url.startswith("https://uploads.github.com/")):
        raise ValueError("untrusted release API URL")
    headers = {"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "private-store-release"}
    data = None
    if value is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(value).encode()
    if binary is not None:
        headers["Content-Type"] = "application/octet-stream"
        data = binary
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers, data=data, method=method), timeout=600) as response:
        return json.load(response)


def publish(directory):
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch"):
        raise ValueError("desktop publication is restricted to main")
    package, manifest = stage(directory)
    tag = "desktop-v" + package["version"]
    try:
        existing = api(f"/repos/{package['repository']}/releases/tags/{tag}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        if existing.get("draft"):
            raise ValueError("an interrupted draft already exists; inspect it before retrying")
        print(f"{tag} already published; increase desktop version and versionCode for a new release")
        return
    # Reject decreasing versions even when tags have a different creation order.
    for release in api(f"/repos/{package['repository']}/releases?per_page=100"):
        if release["tag_name"].startswith("desktop-v"):
            match = re.fullmatch(r"desktop-v(\d+)\.(\d+)\.(\d+)", release["tag_name"])
            if match and tuple(map(int, match.groups())) >= tuple(map(int, package["version"].split("."))):
                raise ValueError("desktop stable version must increase")
            for asset in release["assets"]:
                if asset["name"] == "desktop-release.json":
                    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as response:
                        previous = json.load(response)
                    if previous["versionCode"] >= package["versionCode"]:
                        raise ValueError("desktop versionCode must increase")
            break
    release = api(f"/repos/{package['repository']}/releases", "POST", {"tag_name": tag, "target_commitish": os.environ["GITHUB_SHA"], "name": package["name"] + " desktop " + package["version"], "body": "\n".join("- " + c for c in manifest["changes"]), "draft": True, "prerelease": False, "make_latest": "false"})
    files = [directory / a["file"] for a in manifest["artifacts"]] + [directory / "desktop-release.json", directory / "desktop-changelog.json", directory / "SHA256SUMS"]
    upload = release["upload_url"].split("{")[0]
    for file in files:
        asset = api(upload + "?" + urllib.parse.urlencode({"name": file.name}), "POST", binary=file.read_bytes())
        if asset["size"] != file.stat().st_size or asset.get("digest") != "sha256:" + sha256(file):
            raise ValueError("GitHub upload checksum/size verification failed: " + file.name)
    api(f"/repos/{package['repository']}/releases/{release['id']}", "PATCH", {"draft": False, "make_latest": "false"})
    print("Published " + tag + " with four verified native platform builds")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "stage", "publish"])
    parser.add_argument("--directory", type=Path, default=ROOT / "desktop-dist")
    args = parser.parse_args()
    if args.command == "validate":
        validate()
    elif args.command == "stage":
        stage(args.directory)
    else:
        publish(args.directory)
