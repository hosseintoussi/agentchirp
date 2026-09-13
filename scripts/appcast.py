#!/usr/bin/env python3
"""Generate and verify the signed update feed from the final stapled ZIP."""
import argparse
import base64
import html
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def changelog(version):
    text = (ROOT / "CHANGELOG.md").read_text()
    match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError(f"Missing changelog section for {version}")
    return match[1].strip()


def build(archive, tools, repository, key_file=None):
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("AgentChirp.app/Contents/Info.plist"))
    if info.get("AgentChirpDevelopment", True):
        raise ValueError("Never publish development bundles in an update feed")
    version = info["CFBundleShortVersionString"]
    if info.get("SUFeedURL") != f"https://github.com/{repository}/releases/latest/download/appcast.xml":
        raise ValueError("The app's update feed and release repository do not match")
    prefix = f"https://github.com/{repository}/releases/download/v{version}/"
    signing = ["--ed-key-file", key_file] if key_file else ["--account", "agentchirp"]
    with tempfile.TemporaryDirectory(prefix="agentchirp-appcast-") as directory:
        folder = pathlib.Path(directory)
        # No duplicate DMG/ZIP entries or stale archives in this generation.
        shutil.copy2(archive, folder / archive.name)
        notes = folder / (archive.stem + ".html")
        notes.write_text("<pre>" + html.escape(changelog(version)) + "</pre>")
        subprocess.run([str(tools / "generate_appcast"), *signing, "--maximum-deltas", "0",
                        "--download-url-prefix", prefix, "--embed-release-notes", str(folder)], check=True)
        feed = folder / "appcast.xml"
        item = ET.parse(feed).find("./channel/item")
        enclosure = item.find("enclosure") if item is not None else None
        if enclosure is None or enclosure.get("url") != prefix + archive.name:
            raise ValueError("Update feed does not point at the release archive")
        signature = enclosure.get("{" + SPARKLE + "}edSignature", "")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Update signature is missing or malformed")
        subprocess.run([str(tools / "sign_update"), *signing, "--verify", str(archive), signature], check=True)
        # Verify against the public key actually embedded in the app, not merely
        # the private key used by the generator. A mismatched pair must fail CI.
        verifier = ROOT / "scripts/verify_update.swift"
        subprocess.run(["swift", str(verifier), info["SUPublicEDKey"], signature, str(archive)], check=True)
        output = archive.parent / "appcast.xml"
        output.write_bytes(feed.read_bytes())
        return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--tools", type=pathlib.Path, default=ROOT / ".build/tools/sparkle-2.9.6/bin")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "hosseintoussi/agentchirp"))
    parser.add_argument("--key-file", help="Private key file; omit to use the agentchirp Keychain account")
    args = parser.parse_args()
    print(build(args.archive.resolve(), args.tools.resolve(), args.repository, args.key_file))
