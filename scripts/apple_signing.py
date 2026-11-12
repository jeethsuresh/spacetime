"""Handle Apple signing inputs and temporary keychains on CI runners."""

import base64
import os
import secrets
import shlex
import subprocess


def run(*args, capture=False, quiet=False):
    result = subprocess.run(
        args,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.DEVNULL if quiet else None,
    )
    if result.returncode:
        # Some security commands take passwords as arguments. Never log argv.
        raise ValueError(f"{args[0]} failed (exit {result.returncode}).")
    return result.stdout


def signing_input(name):
    value = os.environ.pop(name, "")
    if not value:
        raise ValueError(f"Set the {name} environment secret.")
    return value


def write_signing_input(path, name):
    try:
        path.write_bytes(base64.b64decode(signing_input(name), validate=True))
    except (ValueError, TypeError) as error:
        raise ValueError(f"{name} is missing or is not valid base64.") from error
    path.chmod(0o600)


def signing_keychain(directory, certificate, certificate_password, cleanup):
    keychain = directory / "signing.keychain-db"
    keychain_password = secrets.token_urlsafe(24)
    search_list = shlex.split(run("security", "list-keychains", "-d", "user", capture=True).decode())
    run("security", "create-keychain", "-p", keychain_password, keychain)
    cleanup.callback(run, "security", "delete-keychain", keychain)
    cleanup.callback(run, "security", "list-keychains", "-d", "user", "-s", *search_list)
    run("security", "set-keychain-settings", "-lut", "3600", keychain)
    run("security", "unlock-keychain", "-p", keychain_password, keychain)
    run("security", "import", certificate, "-k", keychain, "-P", certificate_password,
        "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s",
        "-k", keychain_password, keychain, capture=True)
    run("security", "list-keychains", "-d", "user", "-s", keychain, *search_list)
    return keychain
