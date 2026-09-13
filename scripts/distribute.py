#!/usr/bin/env python3
"""Notarize a signed app, staple it, and create its DMG and Sparkle update archive."""
import argparse
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT)


def distribute(app, profile, identity, development):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not development and info.get("AgentChirpDevelopment", True):
        raise SystemExit("Build a release app first; development bundles cannot be distributed.")
    if not development and (not profile or not identity or identity == "-"):
        raise SystemExit("Supply --notary-profile and --identity for a notarized release.")
    if not (ROOT / ".build/packaging-venv/bin/python3").exists():
        raise SystemExit("Create the packaging venv and install Packaging/requirements.txt; see RELEASING.md.")
    output = app.parent
    archive = output / ("AgentChirp-" + info.get("AgentChirpVersion", info["CFBundleShortVersionString"]) + ".zip")
    dmg = output / "AgentChirp.dmg"
    run("codesign", "--verify", "--deep", "--strict", app)
    with tempfile.TemporaryDirectory(prefix="agentchirp-distribution-") as temporary:
        temp = pathlib.Path(temporary)
        if not development:
            submission = temp / "submission.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission)
            run("xcrun", "notarytool", "submit", submission, "--keychain-profile", profile, "--wait")
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
        # Build the update archive after stapling the app.
        if archive.exists():
            archive.unlink()
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        run(ROOT / ".build/packaging-venv/bin/python3", ROOT / "scripts/build_dmg.py", app, dmg)
        if not development:
            run("codesign", "--force", "--sign", identity, "--timestamp", dmg)
            run("xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile, "--wait")
            run("xcrun", "stapler", "staple", dmg)
            run("xcrun", "stapler", "validate", dmg)
    print(dmg)
    print(archive)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT / "dist/AgentChirp.app")
    parser.add_argument("--notary-profile")
    parser.add_argument("--identity")
    parser.add_argument("--development", action="store_true", help="Create a local DMG without notarization; do not publish")
    args = parser.parse_args()
    distribute(args.app.resolve(), args.notary_profile, args.identity, args.development)
