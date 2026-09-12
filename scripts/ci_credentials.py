#!/usr/bin/env python3
"""Import CI credentials into a temporary keychain without printing secret values."""
import base64
import os
import pathlib
import secrets
import subprocess
import sys

folder = pathlib.Path(os.environ["RUNNER_TEMP"])
keychain = folder / "agentchirp-release.keychain-db"
p12 = folder / "developer-id.p12"
private_key = folder / "sparkle-private-key"
original = folder / "agentchirp-original-keychain"


def run(*args):
    result = subprocess.run(args, stdout=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit(f"{args[0]} {args[1]} failed (exit {result.returncode}); credentials were not printed.")


if "--cleanup" in sys.argv:
    if original.exists():
        run("security", "default-keychain", "-d", "user", "-s", original.read_text().strip())
        original.unlink()
    if keychain.exists():
        run("security", "delete-keychain", str(keychain))
    for path in [p12, private_key]:
        path.unlink(missing_ok=True)
else:
    required = ["DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "APPLE_ID", "APPLE_TEAM_ID",
                "APPLE_APP_SPECIFIC_PASSWORD", "SPARKLE_PRIVATE_KEY", "DEVELOPER_ID_APPLICATION"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit("Configure the release secrets/variables listed in RELEASING.md: " + ", ".join(missing))
    os.umask(0o077)
    p12.write_bytes(base64.b64decode(os.environ["DEVELOPER_ID_P12_BASE64"], validate=True))
    private_key.write_text(os.environ["SPARKLE_PRIVATE_KEY"])
    original.write_text(subprocess.check_output(["security", "default-keychain", "-d", "user"], text=True).strip().strip('"'))
    password = secrets.token_urlsafe(32)
    run("security", "create-keychain", "-p", password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "import", str(p12), "-k", str(keychain), "-P", os.environ["DEVELOPER_ID_P12_PASSWORD"], "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), original.read_text())
    run("security", "default-keychain", "-d", "user", "-s", str(keychain))
    p12.unlink()
    run("xcrun", "notarytool", "store-credentials", "agentchirp-release", "--apple-id", os.environ["APPLE_ID"],
        "--team-id", os.environ["APPLE_TEAM_ID"], "--password", os.environ["APPLE_APP_SPECIFIC_PASSWORD"])
    print("Temporary signing and notarization credentials are ready.")
